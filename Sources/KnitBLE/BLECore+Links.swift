#if canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    import KnitMesh
    import KnitWire

    // MARK: Links and the connections under them

    extension BLECore {
        func close(_ channel: ChannelID) {
            if let dial = dials.removeValue(forKey: channel) {
                releaseIfIdle(dial.peripheral)
            }
            guard let link = links.removeValue(forKey: channel) else {
                return
            }
            link.close()
            emit(.closed(channel))
            peers[channel] = nil
            if let owner = owners.removeValue(forKey: channel) {
                releaseIfIdle(owner)
            }
        }

        /// Starts a link over an open channel, dialed or accepted, once its opening is reported.
        func adopt(_ channel: CBL2CAPChannel, as id: ChannelID, owner: UUID?) {
            let link = L2CAPLink(
                id: id,
                channel: channel,
                thread: streams,
                log: log,
                received: { [emit] bytes in emit(.received(id, bytes)) },
                ended: { [weak self] in self?.onQueue { $0.ended(id) } }
            )
            links[id] = link
            owners[id] = owner
            peers[id] = owner ?? channel.peer.identifier
            link.open()
        }

        /// The far side closed a link, or it failed.
        func ended(_ id: ChannelID) {
            guard links.removeValue(forKey: id) != nil else {
                return
            }
            emit(.closed(id))
            peers[id] = nil
            if let owner = owners.removeValue(forKey: id) {
                releaseIfIdle(owner)
            }
        }

        /// Whether a dial, a link or the GATT read in progress uses the connection to `uuid`.
        func inUse(_ uuid: UUID) -> Bool {
            gattTarget == uuid || dials.values.contains { $0.peripheral == uuid } || owners.values.contains(uuid)
        }

        /// Drops the connection to `uuid` once nothing uses it, so the controller is free for the next.
        func releaseIfIdle(_ uuid: UUID) {
            guard !inUse(uuid), let peripheral = peripherals[uuid], peripheral.state != .disconnected else {
                return
            }
            central?.cancelPeripheralConnection(peripheral)
        }

        /// Every dial waiting on `uuid` failed; a payload read over GATT may name a PSM it no longer listens on, so
        /// it is read again (``GattPayloads``). A connection that ends with no dial waiting keeps the payload: the
        /// radio ends its own after every read, and forgetting it then meant reading the same peer every few
        /// seconds (the iPhone 12, 2026-09-26).
        func failDials(on uuid: UUID) {
            var failed = false
            for (channel, dial) in dials where dial.peripheral == uuid {
                dials[channel] = nil
                emit(.dialFailed(channel))
                failed = true
            }
            if failed {
                gatt.forget(RadioAddress(uuid.uuidString))
            }
        }
    }
#endif
