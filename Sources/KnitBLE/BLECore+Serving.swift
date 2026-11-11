#if canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    public import KnitMesh
    import KnitWire

    // MARK: The advert and its GATT payload

    extension BLERadio {
        /// The GATT server as it stands, read on the CoreBluetooth queue: what the debug bridge's `advert` reports beside the
        /// link manager's status, and what its `advert blind` waits on (ADR 2026-11.prsp, "The bridge and the harness").
        public func servingReport() async -> GattServingReport {
            await withCheckedContinuation { continuation in
                core.onQueue { core in
                    continuation.resume(
                        returning: GattServingReport(
                            serving: core.serving,
                            wanted: core.wanted,
                            listenerPSM: core.listener.psm,
                            wantedPSM: core.wantedPSM,
                            expectsBlinding: core.expectsBlinding,
                            restoredServices: core.restoredServices,
                            matchedByOrder: core.matchedByOrder,
                            poweredOn: core.reported == .on
                        ))
                }
            }
        }
    }

    extension BLECore {
        /// Publishes the listener when none is live or asked for, and while blinding once the doorbell's service is served,
        /// so a peer that dials the PSM it read finds the doorbell (``GattServing/mayPublish``).
        func publishIfDue(on peripheralManager: CBPeripheralManager) {
            if serving.mayPublish, listener.shouldPublish() {
                peripheralManager.publishL2CAPChannel(withEncryption: false)
            }
        }

        func advertise(_ value: GattServing.Wanted, psm: UInt16) {
            wanted = value
            wantedPSM = psm
            serve()
        }

        /// Serves the wanted value from `0xFE30` and advertises the UUID alone, as ``GattServing`` steps it: one combined
        /// service with the doorbell beside the payload while clear, replaced whole when the value changes, which is only
        /// with the PSM; the doorbell's service and the payload's while blinding, the payload's replaced at each rotation
        /// beside a doorbell that keeps its handle (ADR 2026-11.prsp). The value is static either way, so bluetoothd
        /// answers a read while Knit is suspended.
        /// Only while the listener is published on the value's PSM: an advert made from a `.listening` that predates a
        /// stop, or a debounced one racing the radio going off, may arrive before the new publish lands. The publish's
        /// answer serves it then, as the link manager sends no new advert for an unchanged PSM.
        func serve() {
            guard running, reported == .on, let peripheralManager else {
                return
            }
            apply(serving.serve(servable, now: clock.monotonicMilliseconds()), on: peripheralManager)
        }

        /// The wanted value while the listener holds its PSM, and `nil` otherwise.
        var servable: GattServing.Wanted? {
            listener.psm.flatMap { $0 == wantedPSM ? wanted : nil }
        }

        /// Serves again after a failed add, at whatever radio event comes first once its wait is over (``GattServing``):
        /// a suspended Knit runs no timer, so the next ring, link or advert is what tries again.
        func retryServing() {
            if serving.wantsRetry {
                serve()
            }
        }

        /// Asks the peripheral manager for each step, keeping each service added under its serial.
        func apply(_ steps: [GattServing.Step], on manager: CBPeripheralManager) {
            for step in steps {
                switch step {
                case .stopAdvertising:
                    manager.stopAdvertising()
                case .removeAll:
                    manager.removeAllServices()
                    served.removeAll()
                case .add(let service):
                    let built = Self.build(service)
                    awaitingAdd[service.serial] = built
                    manager.add(built)
                case .remove(let service):
                    if let built = served.removeValue(forKey: service.serial) {
                        manager.remove(built)
                        log.log(.info, "ble removed \(Self.describe(service.role)) \(service.serial)")
                    }
                case .startAdvertising:
                    manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
                }
            }
        }

        /// Forgets what the server holds: the radio stopped, after removing it all, or the manager went off, which clears it.
        func forgetServices() {
            serving.forgetServices()
            served.removeAll()
        }

        /// The `0xFE30` primary a step adds: the payload, the doorbell, or both.
        static func build(_ service: GattServing.Service) -> CBMutableService {
            var characteristics: [CBMutableCharacteristic] = []
            if let value = service.value {
                characteristics.append(
                    CBMutableCharacteristic(type: characteristicUUID, properties: [.read], value: Data(value), permissions: [.readable]))
            }
            if service.role != .payload {
                characteristics.append(
                    CBMutableCharacteristic(
                        type: doorbellUUID, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable]))
            }
            let built = CBMutableService(type: serviceUUID, primary: true)
            built.characteristics = characteristics
            return built
        }

        /// A service's role, for the log; never its value, which may be a tag.
        static func describe(_ role: GattServing.Role) -> String {
            switch role {
            case .combined:
                "the combined service"
            case .doorbell:
                "the doorbell's service"
            case .payload:
                "the payload's service"
            }
        }
    }
#endif
