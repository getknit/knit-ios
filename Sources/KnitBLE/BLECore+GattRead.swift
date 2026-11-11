#if canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    import KnitMesh
    import KnitWire

    // MARK: Reading a GATT payload

    /// The payload read's own steps: whom to read and when is ``GattPayloads``' call, and the delegate methods that carry a
    /// read through CoreBluetooth are in `BLECore+Delegates.swift`.
    extension BLECore {
        /// The HELLO on `channel` named `node` and told `told`, `announced` being the tag that node announced: a payload read at
        /// its far end for another node goes, since a new node took that address, and a blinded one for another tag goes, since
        /// the node rotated (the paired change `gatt-peers`' payload lifetime, rule 2; ADR 2026-11.prsp).
        func heardHello(_ node: NodeId, told: NodeId?, announced: NodeId?, on channel: ChannelID) {
            guard let uuid = peers[channel], gatt.helloNamed(node, told: told, announced: announced, at: RadioAddress(uuid.uuidString))
            else {
                return
            }
            log.log(.info, "ble forgetting the GATT payload of \(uuid): its HELLO named \(node)")
        }

        /// Forgets the payloads of the addresses unheard for a minute of scanning, bar those a link, a dial or the
        /// read holds (rule 3).
        func forgetQuietPayloads() {
            let held = Set(peers.values).union(dials.values.map(\.peripheral)).union([gattTarget].compactMap(\.self))
            let linked = Set(held.map { RadioAddress($0.uuidString) })
            for address in gatt.forgetQuiet(now: clock.monotonicMilliseconds(), linked: linked) {
                log.log(.info, "ble forgetting the GATT payload of \(address.rawValue): quiet for a minute of scanning")
            }
            // Rule 4: a blinded payload lasts its slot, so each address costs one read a slot (ADR 2026-11.prsp).
            for address in gatt.forgetPastEdge(wall: clock.wallMilliseconds(), linked: linked) {
                log.log(.info, "ble forgetting the GATT payload of \(address.rawValue): its slot ended")
            }
        }

        /// Connects a UUID-only peer to read its payload, when ``GattPayloads`` says one is due. The read's deadline
        /// ends it whatever happens, and the connection goes once it is over unless a dial came to use it.
        func beginGattRead(_ peripheral: CBPeripheral) {
            let uuid = peripheral.identifier
            let address = RadioAddress(uuid.uuidString)
            guard let central, !inUse(uuid), gatt.begin(address, now: clock.monotonicMilliseconds()) else {
                return
            }
            gattTarget = uuid
            gattStage = .services
            gattReads += 1
            let number = gattReads
            peripheral.delegate = self
            log.log(.info, "ble reading the GATT payload of \(uuid)")
            if peripheral.state == .connected {
                peripheral.discoverServices([Self.serviceUUID])
            } else {
                central.connect(peripheral)
            }
            let timeout = gatt.configuration.readTimeoutMilliseconds
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout))) { [weak self] in
                guard let self, gattReads == number, gattTarget == uuid else {
                    return
                }
                log.log(.info, "ble gave up the GATT payload of \(uuid) after \(timeout) ms")
                finishGattRead(uuid, .failed)
            }
        }

        /// Records how the read of `uuid` ended, and drops its connection unless something else uses it.
        func finishGattRead(_ uuid: UUID, _ outcome: GattPayloads.Outcome) {
            guard gattTarget == uuid else {
                return
            }
            gatt.finish(RadioAddress(uuid.uuidString), outcome, now: clock.monotonicMilliseconds(), wall: clock.wallMilliseconds())
            gattTarget = nil
            gattStage = nil
            releaseIfIdle(uuid)
        }

        /// How far a payload read has come.
        enum GattReadStage {
            /// Connecting, or listing the peer's `0xFE30` services.
            case services
            /// Searching each of them for the payload.
            case characteristics(GattSweep<ObjectIdentifier, CBCharacteristic>)
            /// Reading the value found.
            case value
        }
    }
#endif
