#if canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    import KnitMesh
    import KnitWire

    /// What an advert says: the `0xFE30` service data Android sends, or only the UUID, which is an iPhone's.
    internal enum BLEAdvert {
        /// The payload in the advert's `0xFE30` service data, if it carries one that parses.
        static func payload(_ advertisement: [String: Any]) -> AdvertPayload? {
            let data = advertisement[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
            return data?[BLECore.serviceUUID].flatMap { AdvertPayload(serviceData: Array($0)) }
        }

        /// Whether the advert lists the `0xFE30` UUID, in its service list or the overflow area.
        static func listsService(_ advertisement: [String: Any]) -> Bool {
            let keys = [CBAdvertisementDataServiceUUIDsKey, CBAdvertisementDataOverflowServiceUUIDsKey]
            return keys.contains { key in (advertisement[key] as? [CBUUID])?.contains(BLECore.serviceUUID) ?? false }
        }
    }

    // MARK: The managers' state

    extension BLECore: CBCentralManagerDelegate, CBPeripheralManagerDelegate {
        func centralManagerDidUpdateState(_: CBCentralManager) {
            dropRestored()
            updateState()
        }

        /// Drops the connections a relaunch handed back. Their channels died with the old process, and one left up
        /// kept every later dial to that phone waiting on it: four dials to the Pixel 3 hung for two minutes after an
        /// install, until Stop and Start (`.agents/context/linux-peer.md`). CoreBluetooth refuses the command before
        /// the central is powered on, which is when `willRestoreState` runs.
        func dropRestored() {
            guard let central, central.state == .poweredOn, !restored.isEmpty else {
                return
            }
            for uuid in restored where !inUse(uuid) {
                if let peripheral = peripherals[uuid], peripheral.state != .disconnected {
                    central.cancelPeripheralConnection(peripheral)
                }
            }
            log.log(.info, "ble dropped \(restored.count) restored connections")
            restored.removeAll()
        }

        func peripheralManagerDidUpdateState(_: CBPeripheralManager) {
            updateState()
        }

        #if os(iOS)
            /// iOS relaunched Knit for Bluetooth. The channels did not survive, so the connections it kept are dropped
            /// once the central is powered on (``BLECore/dropRestored()``).
            func centralManager(_: CBCentralManager, willRestoreState state: [String: Any]) {
                for peripheral in state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? [] {
                    peripherals[peripheral.identifier] = peripheral
                    peripheral.delegate = self
                    restored.insert(peripheral.identifier)
                }
                log.log(.info, "ble restored the central with \(restored.count) connections")
            }

            /// The services come back from the next advert.
            func peripheralManager(_: CBPeripheralManager, willRestoreState _: [String: Any]) {
                log.log(.info, "ble restored the peripheral")
            }
        #endif
    }

    // MARK: The peripheral role

    extension BLECore {
        func peripheralManager(_ manager: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
            if let error {
                log.log(.warning, "ble could not serve \(service.uuid): \(error)")
                servedValue = nil
                return
            }
            manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
        }

        func peripheralManagerDidStartAdvertising(_: CBPeripheralManager, error: (any Error)?) {
            if let error {
                log.log(.warning, "ble could not advertise: \(error)")
            }
        }

        func peripheralManager(_: CBPeripheralManager, didPublishL2CAPChannel psm: CBL2CAPPSM, error: (any Error)?) {
            publishing = false
            if let error {
                log.log(.warning, "ble could not listen: \(error)")
                return
            }
            self.psm = psm
            log.log(.info, "ble listening on PSM \(psm)")
            emit(.listening(psm: psm))
        }

        func peripheralManager(_: CBPeripheralManager, didUnpublishL2CAPChannel _: CBL2CAPPSM, error _: (any Error)?) {
            psm = nil
        }

        /// A peer rang the doorbell. Data on an open link does not wake a suspended Knit, and a write does, so a peer
        /// that has written to our link rings to have it read. The wake is the point, and the value is ignored.
        func peripheralManager(_ manager: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
            guard let first = requests.first else {
                return
            }
            manager.respond(to: first, withResult: .success)
            log.log(.info, "ble rung by \(first.central.identifier)")
            emit(.rung)
        }

        func peripheralManager(_: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
            guard let channel, error == nil, running else {
                log.log(.info, "ble refused an incoming channel: \(error.map { "\($0)" } ?? "stopped")")
                return
            }
            let id = newChannel()
            emit(.accepted(id))
            adopt(channel, as: id, owner: nil)
        }
    }

    // MARK: The central role

    extension BLECore: CBPeripheralDelegate {
        // swiftlint:disable:next legacy_objc_type - the delegate's signature is CoreBluetooth's, NSNumber and all
        func centralManager(_: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
            let uuid = peripheral.identifier
            peripherals[uuid] = peripheral
            // Keep the last real reading when this one has none.
            if rssi.intValue != Self.noReading {
                strengths[uuid] = rssi.intValue
            }
            let address = RadioAddress(uuid.uuidString)
            let strength = strengths[uuid] ?? Int(LinkManager.Configuration().unsightedLinkRssi)
            #if DEBUG
                if probe.isOn {
                    probeSaw(peripheral, advertisementData, rssi: strength)
                }
            #endif
            if let advert = BLEAdvert.payload(advertisementData) {
                emit(.sighted(RadioSighting(address: address, advert: advert, rssi: strength)))
            } else if BLEAdvert.listsService(advertisementData) {
                if let advert = gatt.payload(of: address) {
                    emit(.sighted(RadioSighting(address: address, advert: advert, rssi: strength)))
                } else {
                    beginGattRead(peripheral)
                }
            }
        }

        func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
            peripheral.delegate = self
            openPending(on: peripheral)
            if gattTarget == peripheral.identifier {
                peripheral.discoverServices([Self.serviceUUID])
            }
        }

        func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
            log.log(.info, "ble could not connect \(peripheral.identifier): \(error.map { "\($0)" } ?? "no reason")")
            failDials(on: peripheral.identifier)
            finishGattRead(peripheral.identifier, .failed)
        }

        func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error _: (any Error)?) {
            let uuid = peripheral.identifier
            doorbells.forget(uuid)
            failDials(on: uuid)
            finishGattRead(uuid, .failed)
            for (channel, owner) in owners where owner == uuid {
                ended(channel)
            }
        }

        func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
            let uuid = peripheral.identifier
            let waiting = dials.first { entry in
                entry.value.peripheral == uuid && entry.value.opening && (channel.map { $0.psm == entry.value.psm } ?? true)
            }
            guard let (id, dial) = waiting.map({ ($0.key, $0.value) }) else {
                return
            }
            dials[id] = nil
            guard let channel, error == nil, channel.psm == dial.psm else {
                log.log(.info, "ble could not open PSM \(dial.psm) on \(uuid): \(error.map { "\($0)" } ?? "no channel")")
                emit(.dialFailed(id))
                gatt.forget(RadioAddress(uuid.uuidString))
                releaseIfIdle(uuid)
                return
            }
            emit(.connected(id))
            adopt(channel, as: id, owner: uuid)
        }

        // MARK: Reading a GATT payload

        /// Connects a UUID-only peer to read its payload, when ``GattPayloads`` says one is due. The read's deadline
        /// ends it whatever happens, and the connection goes once it is over unless a dial came to use it.
        func beginGattRead(_ peripheral: CBPeripheral) {
            let uuid = peripheral.identifier
            let address = RadioAddress(uuid.uuidString)
            guard let central, !inUse(uuid), gatt.begin(address, now: clock.monotonicMilliseconds()) else {
                return
            }
            gattTarget = uuid
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

        func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
            guard gattTarget == peripheral.identifier else {
                if doorbells.isLooking(peripheral.identifier) {
                    doorbellServicesFound(peripheral, error: error)
                }
                return
            }
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                finishGattRead(peripheral.identifier, error == nil ? .stranger : .failed)
                return
            }
            peripheral.discoverCharacteristics([Self.characteristicUUID, Self.doorbellUUID], for: service)
        }

        func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
            if doorbells.isLooking(peripheral.identifier) {
                doorbellCharacteristicsFound(peripheral, in: service, error: error)
            }
            guard gattTarget == peripheral.identifier else {
                return
            }
            guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == Self.characteristicUUID }) else {
                finishGattRead(peripheral.identifier, error == nil ? .stranger : .failed)
                return
            }
            peripheral.readValue(for: characteristic)
        }

        func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
            let uuid = peripheral.identifier
            guard gattTarget == uuid, characteristic.uuid == Self.characteristicUUID else {
                return
            }
            guard error == nil else {
                finishGattRead(uuid, .failed)
                return
            }
            guard let advert = characteristic.value.flatMap({ AdvertPayload(serviceData: Array($0)) }) else {
                finishGattRead(uuid, .stranger)
                return
            }
            log.log(.info, "ble read \(advert.nodeId) on PSM \(advert.psm) from \(uuid) over GATT")
            finishGattRead(uuid, .read(advert))
            let strength = strengths[uuid] ?? Int(LinkManager.Configuration().unsightedLinkRssi)
            emit(.sighted(RadioSighting(address: RadioAddress(uuid.uuidString), advert: advert, rssi: strength)))
        }

        /// Records how the read of `uuid` ended, and drops its connection unless something else uses it.
        func finishGattRead(_ uuid: UUID, _ outcome: GattPayloads.Outcome) {
            guard gattTarget == uuid else {
                return
            }
            gatt.finish(RadioAddress(uuid.uuidString), outcome, now: clock.monotonicMilliseconds())
            gattTarget = nil
            releaseIfIdle(uuid)
        }
    }
#endif
