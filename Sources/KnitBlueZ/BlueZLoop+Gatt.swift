#if os(Linux)
    import KnitMesh
    import KnitWire

    /// The loop's side of reading a GATT payload, when the radio reads them (`readsGattPayloads`). A peer that lists
    /// the `0xFE30` service without a Knit advert is linked through `Device1.Connect`. BlueZ then reads its services,
    /// the loop reads the payload characteristic, and it drops the link again unless a channel uses it. Whom to read
    /// and when is ``GattPayloads``' call; this is the D-Bus side (ADR 2026-09.xzpt).
    extension BlueZLoop {
        /// Where the read in progress stands.
        enum GattStage: Equatable {
            /// `Device1.Connect` is out.
            case connecting
            /// Linked, and waiting for BlueZ to resolve the device's services.
            case resolving
            /// Finding the characteristic among BlueZ's objects, and reading it.
            case reading
        }

        /// The payload a read found for `device`. When there is none and a read is due, this starts one, and the
        /// peer is sighted once it ends.
        func gattPayload(of device: BlueZDevice, now: Int64) -> AdvertPayload? {
            let address = RadioAddress(device.path)
            if let payload = gatt.payload(of: address) {
                return payload
            }
            guard configuration.readsGattPayloads, device.servesPayloadOverGatt, !linkInUse(device.path), gatt.begin(address, now: now)
            else {
                return nil
            }
            gattStage = .connecting
            gattReads += 1
            let number = gattReads
            log.log(.info, "bluez reading the GATT payload of \(Self.deviceName(device.path))")
            gattCall("Connect", interface: BlueZ.deviceInterface, on: device.path, now: now) { [weak self] result in
                self?.gattConnected(device.path, number, result)
            }
            return nil
        }

        /// Whether a channel or a GATT read uses the link to the device at `path`, which must then stay up.
        func linkInUse(_ path: String) -> Bool {
            gatt.current?.address.rawValue == path || channels.values.contains { $0.devicePath == path }
        }

        /// Follows the read in progress through its device's `PropertiesChanged`.
        func gattDeviceChanged(_ path: String, _ changed: DBusValue, now: Int64) {
            guard gatt.current?.address.rawValue == path, let stage = gattStage else {
                return
            }
            if changed["Connected"]?.bool == false, stage != .connecting {
                failGattRead(path, "its link dropped", now: now)
            } else if changed["ServicesResolved"]?.bool == true, stage == .resolving {
                findPayloadCharacteristic(path, gattReads, now: now)
            }
        }

        /// Ends the read in progress once it has run past its deadline, and drops the link it may be making.
        func expireGattRead(now: Int64) {
            guard let read = gatt.current, now >= read.deadline else {
                return
            }
            failGattRead(read.address.rawValue, "it took longer than \(gatt.configuration.readTimeoutMilliseconds) ms", now: now)
        }

        /// Gives up the read in progress without a wait before the next, since the plane went down under it, and
        /// answers the device it was reading so its link can be dropped with the rest.
        func cancelGattRead() -> String? {
            let path = gatt.current?.address.rawValue
            gatt.cancel()
            gattStage = nil
            return path
        }

        /// BlueZ forgot the device at `path`, so its payload goes too, and a read of it ends.
        func gattDeviceRemoved(_ path: String) {
            if gatt.current?.address.rawValue == path {
                _ = cancelGattRead()
            }
            gatt.forget(RadioAddress(path))
        }

        /// A dial to the device at `path` failed. Its payload may name a PSM it no longer listens on, so the next
        /// advert reads it again.
        func gattDialFailed(_ path: String) {
            let address = RadioAddress(path)
            if gatt.payload(of: address) != nil {
                log.log(.info, "bluez will read the GATT payload of \(Self.deviceName(path)) again")
            }
            gatt.forget(address)
        }

        /// The last part of a device's object path, `dev_4A_00_00_00_00_EF`, for logs.
        static func deviceName(_ path: String) -> Substring {
            path.split(separator: "/").last ?? ""
        }

        // MARK: The steps of a read

        /// Whether read `number` is the one in progress, at `stage`. An answer to a read already given up on, even one
        /// of the same device, fails this and is dropped.
        private func isReading(_ number: Int, at stage: GattStage) -> Bool {
            gattReads == number && gattStage == stage
        }

        private func gattConnected(_ path: String, _ number: Int, _ result: Result<BusMessage, BusError>) {
            guard isReading(number, at: .connecting) else {
                return
            }
            let now = Monotonic.milliseconds()
            if case .failure(let error) = result, devices[path]?.connected != true {
                failGattRead(path, "it did not connect: \(error)", now: now)
                return
            }
            gattStage = .resolving
            if devices[path]?.servicesResolved == true {
                findPayloadCharacteristic(path, number, now: now)
            }
        }

        private func findPayloadCharacteristic(_ path: String, _ number: Int, now: Int64) {
            gattStage = .reading
            guard let bus,
                let call = BusMessage.methodCall(
                    destination: BlueZ.service, path: "/", interface: BlueZ.objectManager, member: "GetManagedObjects")
            else {
                failGattRead(path, "the bus is gone", now: now)
                return
            }
            bus.call(call, now: now) { [weak self] result in
                self?.foundObjects(path, number, result)
            }
        }

        private func foundObjects(_ path: String, _ number: Int, _ result: Result<BusMessage, BusError>) {
            guard isReading(number, at: .reading) else {
                return
            }
            let now = Monotonic.milliseconds()
            guard case .success(let reply) = result, let objects = (try? reply.arguments())?.first else {
                failGattRead(path, "BlueZ did not list its services", now: now)
                return
            }
            guard let characteristic = BlueZ.payloadCharacteristic(in: objects, on: path) else {
                failGattRead(path, "it serves no Knit payload", outcome: .stranger, now: now)
                return
            }
            let read: (Result<BusMessage, BusError>) -> Void = { [weak self] result in self?.readPayload(path, number, result) }
            gattCall("ReadValue", interface: BlueZ.gattCharacteristic, on: characteristic, [.properties([])], now: now, then: read)
        }

        private func readPayload(_ path: String, _ number: Int, _ result: Result<BusMessage, BusError>) {
            guard isReading(number, at: .reading) else {
                return
            }
            let now = Monotonic.milliseconds()
            let value: [UInt8]?
            do {
                value = try result.get().arguments().first?.byteArray
            } catch {
                failGattRead(path, "its characteristic did not read: \(error)", now: now)
                return
            }
            guard let payload = value.flatMap(AdvertPayload.init(serviceData:)) else {
                failGattRead(path, "its characteristic holds no payload", outcome: .stranger, now: now)
                return
            }
            log.log(.info, "bluez read \(payload.nodeId) on PSM \(payload.psm) from \(Self.deviceName(path)) over GATT")
            endGattRead(path, .read(payload), now: now)
            sight(path)
        }

        private func failGattRead(_ path: String, _ reason: String, outcome: GattPayloads.Outcome = .failed, now: Int64) {
            log.log(.info, "bluez could not read the GATT payload of \(Self.deviceName(path)): \(reason)")
            endGattRead(path, outcome, now: now)
        }

        /// Records how the read ended, and drops the link it made unless a channel came to use it meanwhile.
        private func endGattRead(_ path: String, _ outcome: GattPayloads.Outcome, now: Int64) {
            gatt.finish(RadioAddress(path), outcome, now: now)
            gattStage = nil
            if !linkInUse(path) {
                dropLink(to: path, now: now)
            }
        }

        /// Calls a method on one of this adapter's devices or their characteristics. The read's own deadline bounds
        /// the wait, and an answer after it is dropped by its number.
        private func gattCall(
            _ member: String, interface: String, on path: String, _ arguments: [DBusValue] = [], now: Int64,
            then: @escaping (Result<BusMessage, BusError>) -> Void
        ) {
            guard let bus, configuration.adapter.owns(path), path != configuration.adapter.path,
                let call = BusMessage.methodCall(destination: BlueZ.service, path: path, interface: interface, member: member),
                (try? call.append(arguments)) != nil
            else {
                then(.failure(.malformed(path)))
                return
            }
            bus.call(call, now: now, reply: then)
        }
    }
#endif
