#if canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    import KnitMesh
    import KnitWire

    /// Ringing a peer's doorbell (``Radio/ring(_:)``, ADR 2026-09.khjj): a write to the doorbell of the peripheral a
    /// dialed link runs to, over the connection that link already uses. The peer on an accepted link is a central, and
    /// CoreBluetooth gives a peripheral no way to write to one, so only dialed links ring. The doorbell is looked up
    /// once per connection, in every `0xFE30` service the peer serves, and a ring asked for before the lookup ends waits
    /// for it.
    extension BLECore {
        /// Each connected peripheral's doorbell, and the peripherals a ring waits on.
        struct Doorbells {
            enum Lookup {
                case looking
                case absent
                case found(CBCharacteristic)
            }

            var lookups: [UUID: Lookup] = [:]
            var waiting: Set<UUID> = []
            /// Each lookup's search of the peer's `0xFE30` services, once their list came (``GattSweep``).
            var sweeps: [UUID: GattSweep<ObjectIdentifier, CBCharacteristic>] = [:]
            /// Since when each peer's services may still be settling: its dialed link's open, or its last services change
            /// (``DoorbellLookup``).
            var settlingSince: [UUID: Int64] = [:]

            func isLooking(_ uuid: UUID) -> Bool {
                if case .looking = lookups[uuid] {
                    return true
                }
                return false
            }

            /// Forgets what a connection found: it ended.
            mutating func forget(_ uuid: UUID) {
                lookups[uuid] = nil
                waiting.remove(uuid)
                sweeps[uuid] = nil
                settlingSince[uuid] = nil
            }
        }

        /// The doorbell's value; it means nothing, and one byte is the least a write carries.
        static let doorbellValue = Data([1])

        func ring(_ channel: ChannelID) {
            guard let uuid = owners[channel], let peripheral = peripherals[uuid], peripheral.state == .connected else {
                return
            }
            switch doorbells.lookups[uuid] {
            case .found(let characteristic):
                writeDoorbell(characteristic, on: peripheral)
            case .absent:
                return
            case .looking:
                doorbells.waiting.insert(uuid)
            case nil:
                doorbells.lookups[uuid] = .looking
                doorbells.waiting.insert(uuid)
                peripheral.delegate = self
                // Even beside a payload read of the same peripheral: its list may have come already, and the lookup's search
                // starts from a list of its own (``peripheral(_:didDiscoverServices:)``).
                peripheral.discoverServices([Self.serviceUUID])
            }
        }

        /// Records what the lookup found, and rings if a ring waited on it. A lookup that failed, or found nothing while the
        /// peer's services may still be settling, is tried again at the next ring (``DoorbellLookup``); past that, a peer
        /// with no doorbell, an Android phone among them, is not asked again on this connection.
        func endDoorbellLookup(_ peripheral: CBPeripheral, found: CBCharacteristic?, failed: Bool) {
            let uuid = peripheral.identifier
            doorbells.sweeps[uuid] = nil
            let waited = doorbells.waiting.remove(uuid) != nil
            if let found {
                doorbells.lookups[uuid] = .found(found)
                log.log(.info, "ble found the doorbell of \(uuid)")
                if waited {
                    writeDoorbell(found, on: peripheral)
                }
                return
            }
            let now = clock.monotonicMilliseconds()
            switch DoorbellLookup.missing(failed: failed, settlingSince: doorbells.settlingSince[uuid], now: now) {
            case .retry where failed:
                doorbells.lookups[uuid] = nil
                log.log(.info, "ble could not look for the doorbell of \(uuid)")
            case .retry:
                doorbells.lookups[uuid] = nil
                log.log(.info, "ble found no doorbell on \(uuid) yet, and looks again at the next ring")
            case .absent:
                doorbells.lookups[uuid] = .absent
                log.log(.debug, "ble found no doorbell on \(uuid)")
            }
        }

        private func writeDoorbell(_ characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
            let quiet = characteristic.properties.contains(.writeWithoutResponse) && peripheral.canSendWriteWithoutResponse
            peripheral.writeValue(Self.doorbellValue, for: characteristic, type: quiet ? .withoutResponse : .withResponse)
            log.log(.debug, "ble ringing \(peripheral.identifier)")
        }

        /// The peer's services changed. A blinding iPhone replaces its payload's service at every rotation beside a
        /// doorbell's service that stays, so a doorbell found is forgotten only when its own service is among those
        /// invalidated; a doorbell found absent may have come. Either way a lookup in the next
        /// ``DoorbellLookup/doorbellSettleMilliseconds`` that finds none tries again (ADR 2026-11.prsp). A search in
        /// progress that waits on an invalidated service, or on the list, starts again from a fresh list, since
        /// CoreBluetooth may never answer what was asked of a service that went, and the rings waiting on it would wait
        /// for the connection's life.
        func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
            let uuid = peripheral.identifier
            doorbells.settlingSince[uuid] = clock.monotonicMilliseconds()
            searchAgain(peripheral, invalidated: invalidatedServices.map(ObjectIdentifier.init))
            switch doorbells.lookups[uuid] {
            case .found(let characteristic):
                guard let service = characteristic.service, !invalidatedServices.contains(where: { $0 === service }) else {
                    doorbells.lookups[uuid] = nil
                    log.log(.info, "ble forgot the doorbell of \(uuid): its service changed")
                    return
                }
            case .absent:
                doorbells.lookups[uuid] = nil
            case .looking, nil:
                return
            }
        }

        /// Restarts the doorbell lookup and the payload read of `peripheral` whose search waits on a service `invalidated`,
        /// or on the list of services, keeping the rings that wait on the lookup.
        private func searchAgain(_ peripheral: CBPeripheral, invalidated: [ObjectIdentifier]) {
            let uuid = peripheral.identifier
            var again = false
            if doorbells.isLooking(uuid), doorbells.sweeps[uuid].map({ $0.waitsOnAny(of: invalidated) }) ?? true {
                doorbells.sweeps[uuid] = nil
                again = true
            }
            if gattTarget == uuid {
                switch gattStage {
                case .characteristics(let sweep) where sweep.waitsOnAny(of: invalidated):
                    gattStage = .services
                    again = true
                case .services:
                    again = true
                case .characteristics, .value, nil:
                    break
                }
            }
            if again {
                log.log(.info, "ble looks again at the services of \(uuid): they changed mid-search")
                peripheral.discoverServices([Self.serviceUUID])
            }
        }
    }

    // MARK: The GATT identifiers

    extension BLECore {
        /// `CBUUID` is not `Sendable`, so these are built where they are used rather than stored.
        static var serviceUUID: CBUUID { CBUUID(string: AdvertPayload.serviceUUID) }
        static var characteristicUUID: CBUUID { CBUUID(string: AdvertPayload.characteristicUUID) }
        static var doorbellUUID: CBUUID { CBUUID(string: AdvertPayload.doorbellUUID) }
    }
#endif
