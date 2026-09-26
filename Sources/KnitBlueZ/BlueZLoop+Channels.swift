#if os(Linux)
    import Glibc
    import KnitMesh
    import KnitWire

    /// The loop's channels: dials, accepts, reads and writes on non-blocking sockets.
    extension BlueZLoop {
        /// How much of each read a debug log shows.
        static let loggedPrefix = 12

        func dial(_ id: ChannelID, address: RadioAddress, psm: UInt16) {
            guard isUp, let target = devices[address.rawValue]?.dialTarget else {
                emit(.dialFailed(id))
                return
            }
            do {
                let descriptor = try configuration.sockets.dial(target, psm: psm)
                channels[id] = Channel(descriptor: descriptor, connecting: true, devicePath: address.rawValue)
            } catch {
                log.log(.info, "bluez dial \(id) failed: \(error.call) errno \(error.code)")
                gattDialFailed(address.rawValue)
                emit(.dialFailed(id))
            }
        }

        func acceptAll(now: Int64) {
            guard let listener else {
                return
            }
            while let descriptor = Descriptor.accept(listener.descriptor) {
                let id = mailbox.nextChannel()
                let device = configuration.sockets.peer(of: descriptor).map { BlueZDevice.path(of: $0.address, on: configuration.adapter) }
                channels[id] = Channel(
                    descriptor: descriptor,
                    connecting: false,
                    devicePath: device,
                    limit: configuration.sockets.sendLimit(of: descriptor)
                )
                log.log(.debug, "bluez accepted \(id), writing SDUs of up to \(channels[id]?.limit ?? 0) bytes")
                emit(.accepted(id))
                let due = now + configuration.readvertiseDelayMilliseconds
                refreshAdvertAt = min(refreshAdvertAt ?? due, due)
            }
        }

        func service(_ id: ChannelID, events: Int16) {
            guard let channel = channels[id] else {
                return
            }
            let failed = events & (Int16(POLLERR) | Int16(POLLHUP)) != 0
            if channel.connecting {
                let opened = !failed && events & Int16(POLLOUT) != 0 && Descriptor.pendingError(channel.descriptor) == 0
                guard opened else {
                    Descriptor.close(channel.descriptor)
                    channels[id] = nil
                    if let path = channel.devicePath {
                        gattDialFailed(path)
                    }
                    emit(.dialFailed(id))
                    return
                }
                channels[id]?.connecting = false
                channels[id]?.limit = configuration.sockets.sendLimit(of: channel.descriptor)
                log.log(.debug, "bluez \(id) connected, writing SDUs of up to \(channels[id]?.limit ?? 0) bytes")
                emit(.connected(id))
                flush(id)
                return
            }
            if events & Int16(POLLIN) != 0 || failed {
                drain(id)
            }
            if events & Int16(POLLOUT) != 0 {
                flush(id)
            }
        }

        /// Reads what has arrived, a turn's worth at most, and closes the channel at end of stream or on an error.
        private func drain(_ id: ChannelID) {
            for _ in 0..<Self.readsPerTurn {
                guard let descriptor = channels[id]?.descriptor else {
                    return
                }
                switch Descriptor.read(descriptor, into: &readBuffer) {
                case .bytes(let count):
                    log.log(.debug, "bluez \(id) read \(count): \(Hex.encode(Array(readBuffer[0..<min(count, Self.loggedPrefix)])))")
                    emit(.received(id, Array(readBuffer[0..<count])))
                case .wouldBlock:
                    return
                case .ended:
                    log.log(.debug, "bluez \(id) ended")
                    closeChannel(id)
                    return
                case .failed(let code):
                    log.log(.info, "bluez \(id) read failed: errno \(code)")
                    closeChannel(id)
                    return
                }
            }
        }

        func enqueue(_ bytes: [UInt8], on id: ChannelID) {
            guard var channel = channels[id], !bytes.isEmpty else {
                return
            }
            channel.outbox.append(bytes)
            channel.queuedBytes += bytes.count
            channels[id] = channel
            guard channel.queuedBytes <= Self.maximumQueuedBytes else {
                log.log(.warning, "bluez \(id) stopped reading; closing it")
                closeChannel(id)
                return
            }
            flush(id)
        }

        /// Writes queued bytes, one SDU of at most the channel's limit at a time, until the socket would block.
        private func flush(_ id: ChannelID) {
            while var channel = channels[id], !channel.connecting, let head = channel.outbox.first {
                let end = min(head.count, channel.written + max(1, channel.limit))
                switch Descriptor.write(channel.descriptor, head[channel.written..<end]) {
                case .wrote(let count):
                    channel.written += count
                    channel.queuedBytes -= count
                    if channel.written == head.count {
                        channel.outbox.removeFirst()
                        channel.written = 0
                    }
                    channels[id] = channel
                case .wouldBlock:
                    return
                case .failed(let code):
                    log.log(.info, "bluez \(id) write failed: errno \(code)")
                    closeChannel(id)
                    return
                }
            }
        }

        /// Closes a channel and reports it closed, whoever asked, and drops the device's link once no channel uses it.
        func closeChannel(_ id: ChannelID) {
            guard let channel = channels.removeValue(forKey: id) else {
                return
            }
            Descriptor.close(channel.descriptor)
            emit(.closed(id))
            if let path = channel.devicePath, !linkInUse(path) {
                dropLink(to: path, now: Monotonic.milliseconds())
            }
        }
    }
#endif
