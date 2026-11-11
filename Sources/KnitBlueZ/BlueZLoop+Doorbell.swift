#if os(Linux)
    import KnitMesh
    import KnitWire

    /// The loop's side of ringing a peer's doorbell (``Radio/ring(_:)``): a write without response to the doorbell
    /// characteristic BlueZ found among the services of the device on the channel's other end. That device is the
    /// peer, so the write rides the link the channel already uses. BlueZ reads the services of a peer that dialed us
    /// on its own, a while after the link comes up, and a ring asked for before then waits for that read.
    ///
    /// The doorbell is looked up once among every `0xFE30` service (``BlueZ/doorbellCharacteristic(in:on:)``), since a
    /// blinding iPhone serves it in a service of its own beside the payload's (ADR 2026-11.prsp). A lookup that finds none
    /// within ``DoorbellLookup/doorbellSettleMilliseconds`` of BlueZ resolving the services, or of one of the device's GATT
    /// objects going, tries again at the next ring; and a doorbell whose object BlueZ removes, or whose write fails, is
    /// looked up again, since a write without response to a handle that moved is lost unseen.
    extension BlueZLoop {
        /// What a lookup found on a device.
        enum Doorbell: Equatable {
            case absent
            case at(String)
        }

        /// The doorbell's value; it means nothing, and one byte is the least a write carries.
        static let doorbellValue: [UInt8] = [1]

        func ring(_ id: ChannelID, now: Int64) {
            guard let path = channels[id]?.devicePath, configuration.adapter.owns(path) else {
                return
            }
            switch doorbells[path] {
            case .at(let characteristic):
                writeDoorbell(characteristic, of: path, now: now)
            case .absent:
                return
            case nil:
                ringsWaiting.insert(path)
                if devices[path]?.servicesResolved == true {
                    findDoorbell(path, now: now)
                }
            }
        }

        /// Follows a device's link and services: a ring waiting on the device goes out once BlueZ has read them, and
        /// what was found goes when they or the link do.
        func doorbellDeviceChanged(_ path: String, _ changed: DBusValue, now: Int64) {
            if changed["Connected"]?.bool == false || changed["ServicesResolved"]?.bool == false {
                doorbells[path] = nil
                ringsWaiting.remove(path)
                doorbellSettlingSince[path] = nil
            } else if changed["ServicesResolved"]?.bool == true {
                doorbellSettlingSince[path] = now
                if ringsWaiting.contains(path) {
                    findDoorbell(path, now: now)
                }
            }
        }

        /// BlueZ forgot the device.
        func doorbellDeviceGone(_ path: String) {
            doorbells[path] = nil
            ringsWaiting.remove(path)
            doorbellSettlingSince[path] = nil
        }

        /// BlueZ removed a GATT service or characteristic at `path`, as it does when a peer's services change: a doorbell
        /// at or under it goes, one found absent is looked for again, and the device's services settle again.
        func doorbellObjectRemoved(_ path: String, now: Int64) {
            guard let device = devices.keys.first(where: { path.hasPrefix($0 + "/") }) else {
                return
            }
            if devices[device]?.servicesResolved == true {
                doorbellSettlingSince[device] = now
            }
            switch doorbells[device] {
            case .at(let characteristic) where characteristic == path || characteristic.hasPrefix(path + "/"):
                doorbells[device] = nil
                log.log(.info, "bluez forgot the doorbell of \(Self.deviceName(device)): BlueZ removed it")
            case .absent:
                // Its services changed, so a doorbell may have come.
                doorbells[device] = nil
            case .at, nil:
                return
            }
        }

        /// BlueZ found a new `0xFE30` service at `path`, as a blinding iPhone's doorbell service comes up after its link or
        /// a services change: a doorbell found absent on that device is looked for again, and its services settle again.
        func doorbellServiceAdded(_ path: String, now: Int64) {
            guard let device = devices.keys.first(where: { path.hasPrefix($0 + "/") }) else {
                return
            }
            if devices[device]?.servicesResolved == true {
                doorbellSettlingSince[device] = now
            }
            if doorbells[device] == .absent {
                doorbells[device] = nil
            }
        }

        private func findDoorbell(_ path: String, now: Int64) {
            guard let bus, !doorbellLookups.contains(path),
                let call = BusMessage.methodCall(
                    destination: BlueZ.service, path: "/", interface: BlueZ.objectManager, member: "GetManagedObjects")
            else {
                return
            }
            doorbellLookups.insert(path)
            bus.call(call, now: now) { [weak self] result in
                self?.foundObjects(path, result)
            }
        }

        private func foundObjects(_ path: String, _ result: Result<BusMessage, BusError>) {
            doorbellLookups.remove(path)
            guard ringsWaiting.contains(path), case .success(let reply) = result, let objects = (try? reply.arguments())?.first else {
                return
            }
            ringsWaiting.remove(path)
            let now = Monotonic.milliseconds()
            guard let characteristic = BlueZ.doorbellCharacteristic(in: objects, on: path) else {
                switch DoorbellLookup.missing(failed: false, settlingSince: doorbellSettlingSince[path], now: now) {
                case .retry:
                    doorbells[path] = nil
                    log.log(.info, "bluez found no doorbell on \(Self.deviceName(path)) yet, and looks again at the next ring")
                case .absent:
                    doorbells[path] = .absent
                    log.log(.info, "bluez found no doorbell on \(Self.deviceName(path))")
                }
                return
            }
            doorbells[path] = .at(characteristic)
            log.log(.info, "bluez found the doorbell of \(Self.deviceName(path))")
            writeDoorbell(characteristic, of: path, now: now)
        }

        private func writeDoorbell(_ characteristic: String, of path: String, now: Int64) {
            guard let bus, configuration.adapter.owns(characteristic),
                let call = BusMessage.methodCall(
                    destination: BlueZ.service, path: characteristic, interface: BlueZ.gattCharacteristic, member: "WriteValue"),
                (try? call.append([.bytes(Self.doorbellValue), .properties([("type", .string("command"))])])) != nil
            else {
                return
            }
            log.log(.debug, "bluez ringing \(Self.deviceName(path))")
            bus.call(call, now: now) { [weak self] result in
                guard let self, case .failure(let error) = result else {
                    return
                }
                log.log(.info, "bluez could not ring \(Self.deviceName(path)): \(error)")
                // It may have moved: the next ring looks it up again.
                if doorbells[path] == .at(characteristic) {
                    doorbells[path] = nil
                }
            }
        }
    }
#endif
