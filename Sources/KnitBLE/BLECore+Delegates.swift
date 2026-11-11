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

            /// iOS relaunched Knit with the last process's services, which it keeps serving until they are removed, and which
            /// may hold the clear id from before a switch flip. CoreBluetooth refuses the removal before the manager is
            /// powered on, so the first power-on of the process removes them (``GattServing``), as ``dropRestored()`` drops
            /// the connections. Two or more `0xFE30` services were a blinding process's, so the doorbell's service comes up
            /// first again, before the listener is published (ADR 2026-11.prsp).
            func peripheralManager(_: CBPeripheralManager, willRestoreState state: [String: Any]) {
                let services = state[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
                let knit = services.filter { $0.uuid == Self.serviceUUID }.count
                serving.restored(knitServices: knit)
                log.log(.info, "ble restored the peripheral")
                if knit > 1 {
                    // Only a blinding process's services: a clear restoration logs as it did.
                    log.log(.info, "ble restored \(knit) 0xFE30 services, to remove once powered on")
                }
            }
        #endif
    }

    // MARK: The peripheral role

    extension BLECore {
        /// A service was added, or refused. Matched to its step by the object CoreBluetooth hands back, or else to the oldest
        /// add still owed an answer, since the manager answers in the order it was asked (``GattServing``). Advertising
        /// starts once a payload is served, never at every add, and while blinding the doorbell's service publishes the
        /// listener (ADR 2026-11.prsp).
        func peripheralManager(_ manager: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
            if let error {
                log.log(.warning, "ble could not serve \(service.uuid): \(error)")
            }
            guard let serial = awaitingAdd.first(where: { $0.value === service })?.key ?? oldestAwaited(),
                let built = awaitingAdd.removeValue(forKey: serial)
            else {
                return
            }
            // `nil` for a service a stop, a power-off or a flip let go of, whose answer changes nothing.
            let role = [serving.pending, serving.combined].compactMap(\.self).first { $0.serial == serial }?.role
            if error == nil, let role {
                served[serial] = built
                if role != .combined {
                    log.log(.info, "ble serving \(Self.describe(role)) \(serial)")
                }
            }
            let steps = serving.added(serial, ok: error == nil, wanted: running ? servable : nil, now: clock.monotonicMilliseconds())
            apply(steps, on: manager)
            if running, reported == .on, role == .doorbell {
                publishIfDue(on: manager)
            }
        }

        /// The fallback when CoreBluetooth hands back another object than the one added: the oldest add still owed, after
        /// dropping every answer older than the oldest the server waits on, which belongs to an add a removal overtook and
        /// would shift every later match. Logged, since the probe expects identity to match every time.
        private func oldestAwaited() -> UInt64? {
            let owed = serving.oldestOwed
            awaitingAdd = awaitingAdd.filter { entry in owed.map { entry.key >= $0 } ?? false }
            let serial = awaitingAdd.keys.min()
            log.log(.info, "ble matched an added service by order, not identity: \(serial.map { "\($0)" } ?? "none owed")")
            return serial
        }

        func peripheralManagerDidStartAdvertising(_: CBPeripheralManager, error: (any Error)?) {
            if let error {
                log.log(.warning, "ble could not advertise: \(error)")
            }
        }

        func peripheralManager(_ manager: CBPeripheralManager, didPublishL2CAPChannel psm: CBL2CAPPSM, error: (any Error)?) {
            if let error {
                listener.publishFailed()
                log.log(.warning, "ble could not listen: \(error)")
                return
            }
            switch listener.published(psm, running: running) {
            case .listening:
                // The run notes (`.agents/context/linux-peer.md`) read this line as the listener coming up; keep its words.
                log.log(.info, "ble listening on PSM \(psm)")
                emit(.listening(psm: psm))
                // An advert for this PSM may already wait here, and the link manager sends none again for an unchanged one.
                serve()
            case .unpublish(let unpublish):
                // Stopped while the publish was in flight. The next start publishes anew, and reports that PSM.
                log.log(.info, "ble published PSM \(psm) after it stopped, so unpublishes it")
                awaitUnpublish(unpublish, on: manager)
            }
        }

        /// Unpublishes a PSM, and bounds the wait for the answer, which holds the next publish back
        /// (``ListenerPublication``). The deadline runs on uptime, and nothing resumes a suspended Knit to run it, so
        /// there the publish waits until the process runs again. A stop and a start come from Settings or the bridge,
        /// in the foreground, where it fires on time.
        func awaitUnpublish(_ unpublish: ListenerPublication.Unpublish, on manager: CBPeripheralManager) {
            manager.unpublishL2CAPChannel(unpublish.psm)
            let wait = ListenerPublication.answerWaitMilliseconds
            queue.asyncAfter(deadline: .now() + .milliseconds(wait)) { [weak self] in
                guard let self else {
                    return
                }
                let expired = listener.waitEnded(unpublish.wait)
                guard expired > 0 else {
                    return
                }
                log.log(.warning, "ble heard no answer to \(expired) unpublishes in \(wait) ms, so publishes")
                resume()
            }
        }

        /// The answer to an unpublish may land after the next start, one round trip behind the stop (about 0.2 s on the
        /// iPhone 12). Until it lands, or its wait runs out, nothing is published, and once it has, a radio that runs
        /// publishes, which reports the PSM to the link manager, which advertises it (``ListenerPublication``).
        func peripheralManager(_: CBPeripheralManager, didUnpublishL2CAPChannel psm: CBL2CAPPSM, error: (any Error)?) {
            let failure = error.map { ": \($0)" } ?? ""
            switch listener.unpublished(psm) {
            case .asked:
                log.log(.info, "ble stopped listening on PSM \(psm)\(failure)")
            case .late:
                log.log(.info, "ble ignored a late answer to an unpublish of PSM \(psm)\(failure)")
                return
            case .dropped:
                log.log(.warning, "ble lost its listener on PSM \(psm), unasked\(failure)")
            case .stray:
                log.log(.info, "ble ignored an unpublish of PSM \(psm), which it no longer listens on\(failure)")
                return
            }
            resume()
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
            retryServing()
        }

        func peripheralManager(_: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
            guard let channel, error == nil, running else {
                log.log(.info, "ble refused an incoming channel: \(error.map { "\($0)" } ?? "stopped")")
                return
            }
            let id = newChannel()
            emit(.accepted(id))
            adopt(channel, as: id, owner: nil)
            attach(id, to: channel.peer.identifier)
            retryServing()
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
            retryServing()
            if let advert = BLEAdvert.payload(advertisementData) {
                emit(.sighted(RadioSighting(address: address, advert: advert, rssi: strength)))
            } else if BLEAdvert.listsService(advertisementData) {
                // A payload whose address went quiet goes before this advert can be sighted with it (rule 3).
                forgetQuietPayloads()
                gatt.heard(address, now: clock.monotonicMilliseconds())
                if let advert = gatt.payload(of: address) {
                    emit(.sighted(RadioSighting(address: address, advert: advert, rssi: strength)))
                } else {
                    beginGattRead(peripheral)
                }
            }
        }

        func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
            peripheral.delegate = self
            for (channel, device) in attached where device == peripheral.identifier {
                log.log(.info, "ble watching \(channel)'s connection to \(device), connected")
            }
            openPending(on: peripheral)
            if gattTarget == peripheral.identifier {
                peripheral.discoverServices([Self.serviceUUID])
            }
            retryServing()
        }

        func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
            log.log(.info, "ble could not connect \(peripheral.identifier): \(error.map { "\($0)" } ?? "no reason")")
            // The link may still be up on its channel; only its end goes unwatched.
            for (channel, device) in attached where device == peripheral.identifier {
                attached[channel] = nil
            }
            failDials(on: peripheral.identifier)
            finishGattRead(peripheral.identifier, .failed)
        }

        func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
            let uuid = peripheral.identifier
            doorbells.forget(uuid)
            failDials(on: uuid)
            finishGattRead(uuid, .failed)
            // Dialed links and accepted ones alike. Says why a link ended; `interop.py iphone-soak` reads it.
            let under =
                owners.filter { $0.value == uuid }.keys.sorted { $0.rawValue < $1.rawValue }
                + attached.filter { $0.value == uuid }.keys.sorted { $0.rawValue < $1.rawValue }
            for channel in under {
                log.log(.info, "ble \(channel) lost its connection: \(error.map { "\($0)" } ?? "no reason")")
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
            // A doorbell missing this soon after the link opened may be on its way (``DoorbellLookup``).
            doorbells.settlingSince[uuid] = clock.monotonicMilliseconds()
        }

        // MARK: Reading a GATT payload

        /// The peer's `0xFE30` services, for the payload read and the doorbell lookup alike. A blinding iPhone serves two,
        /// the doorbell's and the payload's, so each search asks every one of them for both characteristics and ends only
        /// once all have answered (``GattSweep``; ADR 2026-11.prsp). Both characteristics every time, so whichever search's
        /// discovery answers first, its answer holds what the other looks for too.
        func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
            let uuid = peripheral.identifier
            let services = error == nil ? (peripheral.services ?? []).filter { $0.uuid == Self.serviceUUID } : []
            let keys = services.map(ObjectIdentifier.init)
            var searching = false
            if gattTarget == uuid, case .services = gattStage {
                if keys.isEmpty {
                    finishGattRead(uuid, error == nil ? .stranger : .failed)
                } else {
                    gattStage = .characteristics(GattSweep(keys))
                    searching = true
                }
            }
            if doorbells.isLooking(uuid), doorbells.sweeps[uuid] == nil {
                if keys.isEmpty {
                    endDoorbellLookup(peripheral, found: nil, failed: error != nil)
                } else {
                    doorbells.sweeps[uuid] = GattSweep(keys)
                    searching = true
                }
            }
            guard searching else {
                return
            }
            for service in services {
                peripheral.discoverCharacteristics([Self.characteristicUUID, Self.doorbellUUID], for: service)
            }
        }

        func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
            let uuid = peripheral.identifier
            let key = ObjectIdentifier(service)
            let held = error == nil ? service.characteristics ?? [] : []
            if let ended = doorbells.sweeps[uuid]?.answered(key, found: held.first { $0.uuid == Self.doorbellUUID }, failed: error != nil) {
                switch ended {
                case .found(let doorbell):
                    endDoorbellLookup(peripheral, found: doorbell, failed: false)
                case .missing(let failed):
                    endDoorbellLookup(peripheral, found: nil, failed: failed)
                }
            }
            guard gattTarget == uuid, case .characteristics(var sweep) = gattStage else {
                return
            }
            let ended = sweep.answered(key, found: held.first { $0.uuid == Self.characteristicUUID }, failed: error != nil)
            gattStage = .characteristics(sweep)
            switch ended {
            case .found(let characteristic):
                gattStage = .value
                peripheral.readValue(for: characteristic)
            case .missing(let failed):
                finishGattRead(uuid, failed ? .failed : .stranger)
            case nil:
                return
            }
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
            // A value flagged blinded without a tag's prefix is no payload; one with it is a blinding peer's form, logged without
            // its tag (ADR 2026-11.prsp).
            guard let advert = characteristic.value.flatMap({ AdvertPayload(gattValue: Array($0)) }) else {
                finishGattRead(uuid, .stranger)
                return
            }
            log.log(.info, "ble read \(advert.shownForm) on PSM \(advert.psm) from \(uuid) over GATT")
            let strength = strengths[uuid] ?? Int(LinkManager.Configuration().unsightedLinkRssi)
            emit(.sighted(RadioSighting(address: RadioAddress(uuid.uuidString), advert: advert, rssi: strength)))
            gatt.finish(RadioAddress(uuid.uuidString), .read(advert), now: clock.monotonicMilliseconds(), wall: clock.wallMilliseconds())
            gattTarget = nil
            gattStage = nil
            // A seeking link manager dials on this sighting, and its dial reaches this queue a moment from now. Dropped
            // now, the connection's end would fail that dial (``failDials(on:)``), so it waits to see if one comes.
            queue.asyncAfter(deadline: .now() + .milliseconds(Self.readReleaseGraceMilliseconds)) { [weak self] in
                self?.releaseIfIdle(uuid)
            }
        }
    }
#endif
