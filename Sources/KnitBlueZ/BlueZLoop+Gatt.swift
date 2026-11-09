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

            /// The stage as a timed-out read's reason names it, so a trial's log says where the time went.
            var shown: String {
                switch self {
                case .connecting:
                    "connecting"
                case .resolving:
                    "resolving services"
                case .reading:
                    "reading"
                }
            }
        }

        /// The payload a read found for `device`. When there is none and a read is due, this starts one, and the
        /// peer is sighted once it ends.
        func gattPayload(of device: BlueZDevice, now: Int64) -> AdvertPayload? {
            let address = RadioAddress(device.path)
            if device.servesPayloadOverGatt {
                // A payload whose address went quiet goes before this advert can be sighted with it (rule 3).
                forgetQuietPayloads(now: now)
                gatt.heard(address, now: now)
            }
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
            let stage = gattStage.map { " (\($0.shown))" } ?? ""
            failGattRead(read.address.rawValue, "it took longer than \(gatt.configuration.readTimeoutMilliseconds) ms\(stage)", now: now)
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
            readReleases[path] = nil
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

        /// The HELLO on channel `id` named `node` and told `told`, `announced` being the tag that node announced: a payload read
        /// at the channel's device for another node goes, since a new node took the address, and a blinded one for another
        /// tag goes, since the node rotated (the payload lifetime's rule 2; ADR 2026-11.prsp), and the next advert there reads
        /// it afresh.
        func gattHeardHello(_ node: NodeId, told: NodeId?, announced: NodeId?, on id: ChannelID) {
            guard let path = channels[id]?.devicePath, gatt.helloNamed(node, told: told, announced: announced, at: RadioAddress(path))
            else {
                return
            }
            log.log(.info, "bluez forgetting the GATT payload of \(Self.deviceName(path)): its HELLO named \(node)")
        }

        /// Our plain dial to the device at `address`, whose HELLO carried the seal's bit, got no reply: a payload there
        /// without `FLAG_LINK_SEAL` goes, once, so the next advert reads it afresh (``GattPayloads/noReply(at:)``; the
        /// `link-seal` contract, §7, revision 1).
        func gattNoReply(_ address: RadioAddress) {
            guard gatt.noReply(at: address) else {
                return
            }
            log.log(.info, "bluez forgetting the GATT payload of \(Self.deviceName(address.rawValue)): a plain dial to it got no reply")
        }

        /// Forgets the payloads of the addresses unheard for a minute of scanning, bar those a channel or a read holds
        /// (the payload lifetime's rule 3).
        func forgetQuietPayloads(now: Int64) {
            var linked = Set(channels.values.compactMap(\.devicePath).map(RadioAddress.init))
            if let reading = gatt.current?.address {
                linked.insert(reading)
            }
            for address in gatt.forgetQuiet(now: now, linked: linked) {
                log.log(.info, "bluez forgetting the GATT payload of \(Self.deviceName(address.rawValue)): quiet for a minute of scanning")
            }
            // Rule 4: a blinded payload lasts its slot, so each address costs one read a slot (ADR 2026-11.prsp).
            for address in gatt.forgetPastEdge(wall: Wall.milliseconds(), linked: linked) {
                log.log(.info, "bluez forgetting the GATT payload of \(Self.deviceName(address.rawValue)): its slot ended")
            }
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
            // A value flagged blinded without a tag's prefix is no payload; one with it is a blinding peer's form, logged without
            // its tag (ADR 2026-11.prsp).
            guard let payload = value.flatMap(AdvertPayload.init(gattValue:)) else {
                failGattRead(path, "its characteristic holds no payload", outcome: .stranger, now: now)
                return
            }
            log.log(.info, "bluez read \(payload.shownForm) on PSM \(payload.psm) from \(Self.deviceName(path)) over GATT")
            endGattRead(path, .read(payload), now: now)
            sight(path)
        }

        private func failGattRead(_ path: String, _ reason: String, outcome: GattPayloads.Outcome = .failed, now: Int64) {
            log.log(.info, "bluez could not read the GATT payload of \(Self.deviceName(path)): \(reason)")
            endGattRead(path, outcome, now: now)
        }

        /// Records how the read ended, and drops the link it made unless a channel came to use it meanwhile. A read that
        /// found a payload keeps the link ``Configuration/readReleaseGraceMilliseconds`` longer, as KnitBLE's reader does
        /// (`BLERadio.readReleaseGraceMilliseconds`): an iPhone ends its link to a device that connects to it again, so the
        /// read of its new address ended the peer's link. In the one case logged, the iPhone's redial came over the read's own
        /// connection 10 s after its link ended (its backoff) and 100 ms after a 12 s read ended, and our Disconnect, sent at
        /// the read's end, would have ended it (`.agents/context/linux-peer.md`, "The iPhone ends a link when the same device
        /// connects to it again"). A redial that comes later makes its own connection. A failed read drops its link at once,
        /// since its connection may still be on its way.
        private func endGattRead(_ path: String, _ outcome: GattPayloads.Outcome, now: Int64) {
            gatt.finish(RadioAddress(path), outcome, now: now, wall: Wall.milliseconds())
            gattStage = nil
            guard !linkInUse(path) else {
                return
            }
            if case .read = outcome, configuration.readReleaseGraceMilliseconds > 0 {
                readReleases[path] = now + configuration.readReleaseGraceMilliseconds
            } else {
                dropLink(to: path, now: now)
            }
        }

        /// When the read in progress times out, or a read's grace ends, whichever comes first.
        var gattDue: Int64? {
            [gatt.current?.deadline, readReleases.values.min()].compactMap(\.self).min()
        }

        /// Gives up the read in progress past its deadline, and drops the links whose grace ran out.
        func fireGattTimers(now: Int64) {
            expireGattRead(now: now)
            releaseReadLinks(now: now)
        }

        /// The devices still in their grace, forgotten here: the plane is going down, and their links with it.
        func takeReadReleases() -> [String] {
            defer { readReleases.removeAll() }
            return Array(readReleases.keys)
        }

        /// Drops the link of each read whose grace has run out, unless a channel or a new read uses it by now. Short of the
        /// held links 5323bbd fixed: a link nothing uses still goes, 2 s after its read.
        func releaseReadLinks(now: Int64) {
            for (path, due) in readReleases.sorted(by: { $0.key < $1.key }) where now >= due {
                readReleases[path] = nil
                if !linkInUse(path) {
                    dropLink(to: path, now: now)
                }
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
