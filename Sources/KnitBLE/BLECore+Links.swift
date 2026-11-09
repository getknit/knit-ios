#if canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    public import KnitCrypto
    public import KnitMesh
    import KnitWire

    // MARK: Links and the connections under them

    extension BLECore {
        func dial(_ channel: ChannelID, _ address: RadioAddress, psm: UInt16) {
            guard running, let central, let uuid = UUID(uuidString: address.rawValue),
                let peripheral = peripherals[uuid] ?? central.retrievePeripherals(withIdentifiers: [uuid]).first
            else {
                emit(.dialFailed(channel))
                return
            }
            peripherals[uuid] = peripheral
            peripheral.delegate = self
            dials[channel] = Dial(peripheral: uuid, psm: psm)
            if peripheral.state == .connected {
                openPending(on: peripheral)
            } else if peripheral.state != .connecting {
                central.connect(peripheral)
            }
        }

        /// Asks for an L2CAP channel for every dial waiting on `peripheral`.
        func openPending(on peripheral: CBPeripheral) {
            for (channel, dial) in dials where dial.peripheral == peripheral.identifier && !dial.opening {
                dials[channel]?.opening = true
                peripheral.openL2CAPChannel(CBL2CAPPSM(dial.psm))
            }
        }

        func close(_ channel: ChannelID) {
            // A dial cancelled before it opened reports nothing, so it stops counting here.
            levels.close(channel)
            credits.close(channel)
            if let dial = dials.removeValue(forKey: channel) {
                releaseIfIdle(dial.peripheral)
            }
            guard let link = links.removeValue(forKey: channel) else {
                return
            }
            link.close()
            emit(.closed(channel))
            forgetConnection(of: channel)
        }

        func write(_ bytes: [UInt8], to channel: ChannelID) {
            guard let link = links[channel] else {
                log.log(.debug, "ble dropped \(bytes.count) bytes for \(channel), which has no link")
                return
            }
            link.write(bytes)
        }

        func writeDigest(_ record: [UInt8], to channel: ChannelID) {
            guard let link = links[channel] else {
                log.log(.debug, "ble dropped a digest of \(record.count) bytes for \(channel), which has no link")
                return
            }
            link.writeDigest(record)
        }

        func writeFileRecord(_ record: [UInt8], to channel: ChannelID) {
            guard let link = links[channel] else {
                log.log(.debug, "ble dropped a file record of \(record.count) bytes for \(channel), which has no link")
                return
            }
            link.writeFileRecord(record)
        }

        func writeKeyShare(_ record: [UInt8], sealer: LinkSealer?, to channel: ChannelID) {
            guard let link = links[channel] else {
                log.log(.debug, "ble dropped a key share for \(channel), which has no link")
                return
            }
            link.writeKeyShare(record, sealer: sealer)
        }

        func seal(_ channel: ChannelID, with sealer: LinkSealer) {
            guard let link = links[channel] else {
                log.log(.debug, "ble dropped a sealer for \(channel), which has no link")
                return
            }
            link.seal(with: sealer)
        }

        /// Starts a link over an open channel, dialed or accepted, once its opening is reported.
        func adopt(_ channel: CBL2CAPChannel, as id: ChannelID, owner: UUID?) {
            let link = L2CAPLink(
                id: id,
                channel: channel,
                thread: streams,
                levels: levels,
                credits: credits,
                log: log,
                received: { [emit] bytes in emit(.received(id, bytes)) },
                ended: { [weak self] in self?.onQueue { $0.ended(id) } },
                wroteFileRecord: { [emit] in emit(.wroteFileRecord(id)) }
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
            forgetConnection(of: id)
        }

        /// Lets go of the connection under a link that is over, dialed or attached.
        private func forgetConnection(of id: ChannelID) {
            peers[id] = nil
            if let owner = owners.removeValue(forKey: id) {
                releaseIfIdle(owner)
            }
            if let device = attached.removeValue(forKey: id) {
                releaseIfIdle(device)
            }
        }

        /// Connects to the device at the far end of an accepted link as a peripheral too, which CoreBluetooth does over
        /// the link the device already holds. The end of that connection reaches `didDisconnectPeripheral`, a delegate
        /// event that resumes a suspended Knit. Without it, the end of a link the far side dialed reaches Knit only
        /// through the channel's streams, which wait until Knit next runs: on 2026-10-02 a link that ended while the
        /// iPhone was locked went unheard for four minutes, until Knit was opened, so Knit never knew to seek peers
        /// (`interop.py iphone-seek --mode drop`, ADR 2026-10.mueg). CoreBluetooth gives a device one identifier in
        /// both roles.
        func attach(_ id: ChannelID, to device: UUID) {
            guard let central, let peripheral = peripherals[device] ?? central.retrievePeripherals(withIdentifiers: [device]).first else {
                log.log(.info, "ble cannot watch \(id)'s connection: CoreBluetooth knows no peripheral \(device)")
                return
            }
            peripherals[device] = peripheral
            attached[id] = device
            peripheral.delegate = self
            log.log(.info, "ble watching \(id)'s connection to \(device), \(Self.describe(peripheral.state))")
            if peripheral.state == .disconnected {
                central.connect(peripheral)
            }
        }

        /// A peripheral's state, for the log.
        static func describe(_ state: CBPeripheralState) -> String {
            switch state {
            case .connected:
                "connected"
            case .connecting:
                "connecting"
            case .disconnecting:
                "disconnecting"
            case .disconnected:
                "disconnected"
            @unknown default:
                "state \(state.rawValue)"
            }
        }

        /// Whether a dial, a link or the GATT read in progress uses the connection to `uuid`.
        func inUse(_ uuid: UUID) -> Bool {
            gattTarget == uuid || dials.values.contains { $0.peripheral == uuid } || owners.values.contains(uuid)
                || attached.values.contains(uuid)
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

    // MARK: The seal, on the radio

    extension BLERadio {
        /// Queued in order with the writes, on the CoreBluetooth queue and then the stream thread, where the link's outbox
        /// holds what follows until a sealer is there (``L2CAPLink/writeKeyShare(_:sealer:)``).
        public func writeKeyShare(_ record: [UInt8], sealer: LinkSealer?, to channel: ChannelID) {
            levels.queued(record.count, on: channel)
            core.onQueue { $0.writeKeyShare(record, sealer: sealer, to: channel) }
        }

        /// Through the same two queues as the writes, so it lands in order with them (``L2CAPLink/seal(with:)``).
        public func seal(_ channel: ChannelID, with sealer: LinkSealer) {
            core.onQueue { $0.seal(channel, with: sealer) }
        }

        /// On the CoreBluetooth queue, where the GATT payloads are kept (``BLECore/dialGotNoReply(at:)``).
        public func dialGotNoReply(at address: RadioAddress) {
            core.onQueue { $0.dialGotNoReply(at: address) }
        }
    }
#endif
