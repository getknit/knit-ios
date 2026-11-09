#if os(Linux)
    import Glibc
    import KnitCrypto
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

        /// Whether to poll the channels for what they read: always, unless a trial asked the loop to stop
        /// (``Configuration/stopReadingAfterMilliseconds``). A hang-up still reaches the loop, which `poll` reports unasked.
        func readsChannels(now: Int64) -> Bool {
            guard let stopReadingAt, now >= stopReadingAt else {
                return true
            }
            if !saidStoppedReading {
                saidStoppedReading = true
                log.log(.warning, "bluez channels are no longer read, for a trial (--stop-reading-after)")
            }
            return false
        }

        /// Whether `id` may be read under its inbound credit (``InboxCredits``): not while 256 KiB it delivered wait
        /// unprocessed, until the consumer brings that below half and the mailbox wakes the loop. Says so once when the
        /// channel pauses.
        func creditAllowsReading(_ id: ChannelID) -> Bool {
            switch mailbox.credits.gate(id) {
            case .read:
                return true
            case .pause(let unprocessed):
                log.log(.debug, "bluez \(id) reads paused: \(unprocessed) bytes unprocessed")
                return false
            case .paused:
                return false
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
                drain(id, hungUp: failed)
            }
            if events & Int16(POLLOUT) != 0 {
                flush(id)
            }
        }

        /// Reads what has arrived, a turn's worth at most, and closes the channel at end of stream or on an error. It
        /// stops at the channel's inbound credit, except after a hang-up or an error, which `poll` would otherwise report on
        /// every turn. After a hang-up the peer can send no more, so what is left is the socket's buffer at most, and it is
        /// read through to the end, past the credit, with nothing dropped. An error close (POLLERR, then `read failed`) does
        /// drop what the socket still held: the kernel returns the pending error before those bytes, and the channel
        /// closes on it.
        private func drain(_ id: ChannelID, hungUp: Bool) {
            for _ in 0..<Self.readsPerTurn {
                guard let descriptor = channels[id]?.descriptor, hungUp || creditAllowsReading(id) else {
                    return
                }
                switch Descriptor.read(descriptor, into: &readBuffer) {
                case .bytes(let count):
                    log.log(.debug, "bluez \(id) read \(count): \(Hex.encode(Array(readBuffer[0..<min(count, Self.loggedPrefix)])))")
                    mailbox.credits.delivered(count, on: id)
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
            channels[id] = channel
            flushWithinBound(id)
        }

        /// Queues a DIGEST record, or puts it in the place of the one still waiting (``LinkOutbox/offerDigest(_:)``).
        func enqueueDigest(_ record: [UInt8], on id: ChannelID) {
            guard var channel = channels[id] else {
                return
            }
            let before = channel.outbox.queuedBytes
            if channel.outbox.offerDigest(record) {
                log.log(.debug, "bluez \(id) digest of \(record.count) bytes replaced the one waiting")
                // The mailbox counted the whole record; the one it replaced will never be written.
                mailbox.levels.discarded(record.count - (channel.outbox.queuedBytes - before), on: id)
            }
            channels[id] = channel
            flushWithinBound(id)
        }

        /// Queues a FILE record, whose last byte out this loop reports (``LinkOutbox/appendFileRecord(_:)``).
        func enqueueFileRecord(_ record: [UInt8], on id: ChannelID) {
            guard var channel = channels[id] else {
                return
            }
            channel.outbox.appendFileRecord(record)
            channels[id] = channel
            flushWithinBound(id)
        }

        /// The seal's commands (``RadioCommand/writeKeyShare(_:_:_:)`` and the three after it), in order with the writes.
        func performSealing(_ command: RadioCommand) {
            switch command {
            case .writeKeyShare(let id, let record, let sealer):
                enqueueKeyShare(record, sealer: sealer, on: id)
            case .seal(let id, let sealer):
                seal(id, with: sealer)
            case .linkUp(let id):
                armBitFlip(on: id)
            case .dialGotNoReply(let address):
                gattNoReply(address)
            default:
                break
            }
        }

        /// Queues our `KEY_SHARE`, holding what follows it until a sealer is there, which a responder hands over with it
        /// (``LinkOutbox/appendKeyShare(_:)``). A frame may span several SDUs: the far end reads a byte stream.
        func enqueueKeyShare(_ record: [UInt8], sealer: LinkSealer?, on id: ChannelID) {
            guard var channel = channels[id] else {
                return
            }
            channel.outbox.appendKeyShare(record)
            if let sealer {
                channel.outbox.seal(with: sealer)
            }
            channels[id] = channel
            flushWithinBound(id)
        }

        /// Seals everything after our `KEY_SHARE` from here, and writes what was held for it.
        func seal(_ id: ChannelID, with sealer: LinkSealer) {
            guard var channel = channels[id] else {
                return
            }
            channel.outbox.seal(with: sealer)
            channels[id] = channel
            flushWithinBound(id)
        }

        /// The trial's bit flip (``Configuration/flipsSealedBit``): the next sealed frame on the link that just registered
        /// goes out with one bit flipped past its header. A plain link never seals one, so it is never touched.
        func armBitFlip(on id: ChannelID) {
            guard configuration.flipsSealedBit, var channel = channels[id] else {
                return
            }
            channel.outbox.corruptNextSealedFrame()
            channels[id] = channel
            log.log(.warning, "bluez \(id) will flip a bit in its next sealed frame, for a trial (--flip-sealed-bit)")
        }

        /// Closes a channel whose peer stopped reading (``LinkOutbox/isOverfull``), and otherwise writes what it can.
        private func flushWithinBound(_ id: ChannelID) {
            guard let channel = channels[id] else {
                return
            }
            guard !channel.outbox.isOverfull else {
                log.log(.warning, "bluez \(id) stopped reading; closing it")
                closeChannel(id)
                return
            }
            flush(id)
        }

        /// Writes queued bytes, one SDU of at most the channel's limit at a time, until the socket would block. On a sealed
        /// link the outbox seals a frame as it hands its first SDU over, so the channel is stored back after every turn, a
        /// would-block's included: a frame sealed and not written is offered again as it was, never sealed twice. A seal that
        /// fails closes the channel.
        private func flush(_ id: ChannelID) {
            while var channel = channels[id], !channel.connecting {
                let next = channel.outbox.next(atMost: channel.limit)
                channels[id] = channel
                guard let chunk = next else {
                    if channel.outbox.sealFailed {
                        log.log(.warning, "bluez \(id) could not seal; closing it")
                        closeChannel(id)
                    }
                    return
                }
                switch Descriptor.write(channel.descriptor, chunk) {
                case .wrote(let count):
                    // Plaintext, so the levels count what the link manager handed over (``LinkOutbox/Written``).
                    let written = channel.outbox.wrote(count)
                    channels[id] = channel
                    mailbox.levels.wrote(written.plaintextBytes, on: id)
                    if written.finishedFileRecord {
                        emit(.wroteFileRecord(id))
                    }
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
