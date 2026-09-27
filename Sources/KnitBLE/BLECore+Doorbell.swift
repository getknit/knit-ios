#if canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    import KnitMesh

    /// Ringing a peer's doorbell (``Radio/ring(_:)``, ADR 2026-09.khjj): a write to the doorbell of the peripheral a
    /// dialed link runs to, over the connection that link already uses. The peer on an accepted link is a central, and
    /// CoreBluetooth gives a peripheral no way to write to one, so only dialed links ring. The doorbell is looked up
    /// once per connection, and a ring asked for before the lookup ends waits for it.
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

            func isLooking(_ uuid: UUID) -> Bool {
                if case .looking = lookups[uuid] {
                    return true
                }
                return false
            }

            /// Forgets what a connection found: it ended, or the peer's services changed.
            mutating func forget(_ uuid: UUID) {
                lookups[uuid] = nil
                waiting.remove(uuid)
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
                if gattTarget != uuid {
                    peripheral.discoverServices([Self.serviceUUID])
                }
            }
        }

        /// The services of a peripheral whose doorbell is being looked up. A payload read of the same peripheral finds
        /// the doorbell with the payload instead (``peripheral(_:didDiscoverServices:)``).
        func doorbellServicesFound(_ peripheral: CBPeripheral, error: (any Error)?) {
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                endDoorbellLookup(peripheral, found: nil, failed: error != nil)
                return
            }
            peripheral.discoverCharacteristics([Self.doorbellUUID], for: service)
        }

        func doorbellCharacteristicsFound(_ peripheral: CBPeripheral, in service: CBService, error: (any Error)?) {
            let doorbell = service.characteristics?.first { $0.uuid == Self.doorbellUUID }
            endDoorbellLookup(peripheral, found: error == nil ? doorbell : nil, failed: error != nil)
        }

        /// Records what the lookup found, and rings if a ring waited on it. A lookup that failed is tried again at the
        /// next ring; a peer with no doorbell, an Android phone among them, is not asked again on this connection.
        private func endDoorbellLookup(_ peripheral: CBPeripheral, found: CBCharacteristic?, failed: Bool) {
            let uuid = peripheral.identifier
            let waited = doorbells.waiting.remove(uuid) != nil
            if let found {
                doorbells.lookups[uuid] = .found(found)
                log.log(.info, "ble found the doorbell of \(uuid)")
                if waited {
                    writeDoorbell(found, on: peripheral)
                }
            } else if failed {
                doorbells.lookups[uuid] = nil
                log.log(.info, "ble could not look for the doorbell of \(uuid)")
            } else {
                doorbells.lookups[uuid] = .absent
                log.log(.debug, "ble found no doorbell on \(uuid)")
            }
        }

        private func writeDoorbell(_ characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
            let quiet = characteristic.properties.contains(.writeWithoutResponse) && peripheral.canSendWriteWithoutResponse
            peripheral.writeValue(Self.doorbellValue, for: characteristic, type: quiet ? .withoutResponse : .withResponse)
            log.log(.debug, "ble ringing \(peripheral.identifier)")
        }

        /// The peer's services changed, so a doorbell found on them may be gone.
        func peripheral(_ peripheral: CBPeripheral, didModifyServices _: [CBService]) {
            doorbells.forget(peripheral.identifier)
        }
    }
#endif
