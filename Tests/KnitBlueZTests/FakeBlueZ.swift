#if os(Linux)
    @testable import KnitBlueZ
    import KnitWire

    /// Just enough of bluetoothd for the radio: an object tree with `hci1` (and `hci0`, which the radio must ignore),
    /// discovery, the advertising manager, which reads each advert back through `Properties.GetAll` before it
    /// answers as BlueZ does, the GATT manager, which reads the application's objects, and remote devices' GATT
    /// servers, which BlueZ resolves once `Device1.Connect` links them.
    final class FakeBlueZ {
        /// A remote device's GATT server, as BlueZ finds it once linked.
        struct RemoteGatt {
            /// The payload characteristic's value, or `nil` for a device whose `0xFE30` UUID is someone else's: it
            /// serves a battery service instead.
            var value: [UInt8]?
            /// Whether `Connect` links it; if not, `Connect` answers `org.bluez.Error.Failed`.
            var connects = true
            /// Whether `Connect` is answered at all.
            var answersConnect = true
            /// Whether BlueZ resolves its services once linked.
            var resolves = true
            /// Whether they are resolved before `Connect` is answered. BlueZ 5.72 answers first, once the link is up
            /// (`att_connect_cb` in `src/device.c`), but the radio must not depend on the order.
            var resolvesBeforeAnswering = false
            /// Whether `ReadValue` fails.
            var readFails = false
            /// Whether it serves the doorbell beside the payload.
            var doorbell = false
        }

        /// A write to a remote characteristic.
        struct Write: Equatable {
            var path: String
            var value: [UInt8]
            /// The `type` option: `command` for a write without response.
            var type: String?
        }

        static let adapter = "/org/bluez/hci1"
        static let adapterAddress = "0A:BC:DE:00:00:A1"
        static let advertisingSets = 4 // adverts the controller holds at once, as the lab's dongles do
        static let otherAdapter = "/org/bluez/hci0"

        let server: BusServer
        var address: String { server.address }

        var adapterAddress = FakeBlueZ.adapterAddress
        var powered = true
        var hasAdapter = true
        /// Devices already known when the radio asks, by path.
        var knownDevices: [String: DBusValue] = [:]
        /// Every method the radio called, as `Interface.Member`, in order.
        private(set) var calls: [String] = []
        /// Each advert's properties, as read through `GetAll`, by object path.
        private(set) var advertisements: [String: DBusValue] = [:]
        /// The adverts registered now, oldest first.
        private(set) var registered: [String] = []
        private(set) var discovering = false
        private(set) var discoveryFilter: DBusValue?
        /// The GATT application's objects, as read when it registered.
        private(set) var application: DBusValue?
        private(set) var applicationRoot: String?
        /// The answer to the last ``read(characteristic:offset:)``.
        private(set) var readResult: Result<[UInt8], BusError>?
        /// Fails the next advert registration, as BlueZ does when its instances run out.
        var refuseNextRegistration = false
        /// Answers `GetManagedObjects` with an error, as a bus with no bluetoothd does.
        var refusesInventory = false
        /// The devices the radio asked to disconnect, in order.
        private(set) var disconnected: [String] = []
        /// The devices the radio asked BlueZ to forget, in order.
        private(set) var forgotten: [String] = []
        /// The GATT servers of remote devices, by device path.
        var remoteGatt: [String: RemoteGatt] = [:]
        /// The devices the radio asked to link, in order.
        private(set) var connectRequests: [String] = []
        /// The devices linked through `Connect` and not disconnected since.
        private(set) var linked: Set<String> = []
        /// The `Connect` calls left unanswered, oldest first.
        private(set) var heldConnects: [BusMessage] = []
        /// Every `WriteValue` to a remote characteristic, in order.
        private(set) var writes: [Write] = []

        init() throws {
            server = try BusServer()
        }

        /// The radio's connection, once it has connected: the newest, after a reconnect.
        var radio: BusConnection? {
            guard let connection = server.connections.last(where: \.isOpen) else {
                return nil
            }
            if connection.fallback == nil {
                connection.fallback = { [weak self] call in self?.answer(call) ?? .unknown }
            }
            return connection
        }

        func iterate(waitMilliseconds: Int32 = 0) {
            _ = radio
            server.iterate(waitMilliseconds: waitMilliseconds)
        }

        /// Closes the radio's connection, as a bus daemon restart would.
        func dropRadio() {
            radio?.close()
        }

        // MARK: What the radio calls

        private func answer(_ call: BusMessage) -> BusConnection.Answer {
            let interface = call.interface ?? ""
            let member = call.member ?? ""
            calls.append(interface + "." + member)
            let arguments = (try? call.arguments()) ?? []
            switch (interface, member) {
            case (BlueZ.bus, "AddMatch"):
                return .values([])
            case (BlueZ.objectManager, "GetManagedObjects"):
                guard !refusesInventory else {
                    return .error(name: "org.freedesktop.DBus.Error.ServiceUnknown", message: "The name org.bluez was not provided")
                }
                return .values([managedObjects()])
            case (BlueZ.adapterInterface, "SetDiscoveryFilter"):
                discoveryFilter = arguments.first
                return .values([])
            case (BlueZ.adapterInterface, "StartDiscovery"):
                discovering = true
                return .values([])
            case (BlueZ.adapterInterface, "StopDiscovery"):
                discovering = false
                return .values([])
            case (BlueZ.adapterInterface, "RemoveDevice"):
                let path = arguments.first?.text ?? ""
                forgotten.append(path)
                try? remove(path, interfaces: [BlueZ.deviceInterface])
                return .values([])
            case (BlueZ.advertisingManager, "RegisterAdvertisement"):
                return register(advert: arguments.first?.text ?? "", call: call)
            case (BlueZ.advertisingManager, "UnregisterAdvertisement"):
                registered.removeAll { $0 == arguments.first?.text }
                return .values([])
            case (BlueZ.gattManager, "RegisterApplication"):
                return register(application: arguments.first?.text ?? "", call: call)
            case (BlueZ.gattManager, "UnregisterApplication"):
                applicationRoot = nil
                return .values([])
            case (BlueZ.deviceInterface, "Disconnect"):
                disconnected.append(call.path ?? "")
                unlink(call.path ?? "")
                return .values([])
            case (BlueZ.deviceInterface, "Connect"):
                return connect(call)
            case (BlueZ.gattCharacteristic, "ReadValue"):
                return readValue(call)
            case (BlueZ.gattCharacteristic, "WriteValue"):
                return writeValue(call, arguments)
            default:
                return .unknown
            }
        }

        private func register(advert path: String, call: BusMessage) -> BusConnection.Answer {
            guard registered.count < Self.advertisingSets else {
                return .error(name: "org.bluez.Error.NotPermitted", message: "Maximum advertisements reached")
            }
            guard let radio,
                let getAll = BusMessage.methodCall(destination: nil, path: path, interface: BlueZ.properties, member: "GetAll"),
                (try? getAll.append(.string(BlueZ.advertisementInterface))) != nil
            else {
                return .error(name: "org.bluez.Error.Failed", message: "cannot read \(path)")
            }
            radio.call(getAll, now: Monotonic.milliseconds()) { [weak self] result in
                guard let self else {
                    return
                }
                guard case .success(let reply) = result, let properties = (try? reply.arguments())?.first, !refuseNextRegistration else {
                    refuseNextRegistration = false
                    radio.reply(to: call, error: "org.bluez.Error.Failed", message: "Maximum advertisements reached")
                    return
                }
                advertisements[path] = properties
                registered.append(path)
                radio.reply(to: call, with: [])
            }
            return .later
        }

        private func register(application root: String, call: BusMessage) -> BusConnection.Answer {
            guard applicationRoot == nil else {
                return .error(name: "org.bluez.Error.AlreadyExists", message: "Already Exists")
            }
            guard let radio,
                let objects = BusMessage.methodCall(
                    destination: nil, path: root, interface: BlueZ.objectManager, member: "GetManagedObjects")
            else {
                return .error(name: "org.bluez.Error.Failed", message: "cannot read \(root)")
            }
            radio.call(objects, now: Monotonic.milliseconds()) { [weak self] result in
                guard case .success(let reply) = result else {
                    radio.reply(to: call, error: "org.bluez.Error.Failed", message: "no objects")
                    return
                }
                self?.application = (try? reply.arguments())?.first
                self?.applicationRoot = root
                radio.reply(to: call, with: [])
            }
            return .later
        }

        private func managedObjects() -> DBusValue {
            let interfacesType = DBusType.dictionary(key: .string, value: .dictionary(key: .string, value: .variant))
            var objects: [DBusEntry] = []
            let hci0 = DBusValue.properties([("Address", .string("AA:AA:AA:AA:AA:AA")), ("Powered", .boolean(true))])
            objects.append(DBusEntry(key: .objectPath(Self.otherAdapter), value: Self.interfaces([(BlueZ.adapterInterface, hci0)])))
            if hasAdapter {
                let hci1 = DBusValue.properties([("Address", .string(adapterAddress)), ("Powered", .boolean(powered))])
                objects.append(DBusEntry(key: .objectPath(Self.adapter), value: Self.interfaces([(BlueZ.adapterInterface, hci1)])))
            }
            for (path, properties) in knownDevices.sorted(by: { $0.key < $1.key }) {
                objects.append(DBusEntry(key: .objectPath(path), value: Self.interfaces([(BlueZ.deviceInterface, properties)])))
            }
            for path in linked.sorted() {
                objects += RemoteGattObjects.on(path, knit: remoteGatt[path]?.value != nil, doorbell: remoteGatt[path]?.doorbell == true)
            }
            return .dictionary(key: .objectPath, value: interfacesType, objects)
        }

        static func interfaces(_ pairs: [(String, DBusValue)]) -> DBusValue {
            .dictionary(
                key: .string,
                value: .dictionary(key: .string, value: .variant),
                pairs.map { DBusEntry(key: .string($0.0), value: $0.1) }
            )
        }

        // MARK: What BlueZ tells the radio

        /// A device's properties, as BlueZ publishes them.
        static func device(
            address: String, random: Bool = true, rssi: Int16? = -55, advert: AdvertPayload?, uuids: [String] = []
        ) -> DBusValue {
            var pairs: [(String, DBusValue)] = [("Address", .string(address)), ("AddressType", .string(random ? "random" : "public"))]
            if let rssi {
                pairs.append(("RSSI", .int16(rssi)))
            }
            if let advert {
                pairs.append(("ServiceData", .properties([(AdvertPayload.serviceUUID, .bytes(advert.bytes))])))
            }
            if !uuids.isEmpty {
                pairs.append(("UUIDs", .strings(uuids)))
            }
            return .properties(pairs)
        }

        /// A device appears.
        func add(device path: String, _ properties: DBusValue) throws {
            try radio?.emit(
                path: "/",
                interface: BlueZ.objectManager,
                member: "InterfacesAdded",
                values: [.objectPath(path), Self.interfaces([(BlueZ.deviceInterface, properties)])]
            )
        }

        /// Interfaces go from an object.
        func remove(_ path: String, interfaces: [String]) throws {
            try radio?.emit(
                path: "/", interface: BlueZ.objectManager, member: "InterfacesRemoved", values: [.objectPath(path), .strings(interfaces)])
        }

        /// Properties change on an object.
        func change(_ path: String, interface: String, _ properties: DBusValue, invalidated: [String] = []) throws {
            try radio?.emit(
                path: path,
                interface: BlueZ.properties,
                member: "PropertiesChanged",
                values: [.string(interface), properties, .strings(invalidated)]
            )
        }

        /// The adapter's power changes.
        /// Turns the adapter on or off, keeping what is registered through it, as BlueZ 5.72 does.
        func setPowered(_ on: Bool) throws {
            powered = on
            try change(Self.adapter, interface: BlueZ.adapterInterface, .properties([("Powered", .boolean(on))]))
        }

        /// Reads the GATT characteristic as a central would, from `offset`.
        func read(characteristic path: String, offset: UInt16? = nil) throws {
            guard let radio,
                let call = BusMessage.methodCall(destination: nil, path: path, interface: BlueZ.gattCharacteristic, member: "ReadValue")
            else {
                return
            }
            try call.append(.properties(offset.map { [("offset", .uint16($0))] } ?? []))
            readResult = nil
            radio.call(call, now: Monotonic.milliseconds()) { [weak self] result in
                self?.readResult = result.flatMap { reply in
                    Result { try reply.arguments().first?.byteArray ?? [] }.mapError { $0 as? BusError ?? .timedOut }
                }
            }
        }

        /// Calls any method on one of the radio's objects, and hands back the answer.
        func call(
            _ path: String, interface: String, member: String, _ arguments: [DBusValue] = [],
            then: @escaping (Result<BusMessage, BusError>) -> Void
        ) throws {
            guard let radio, let call = BusMessage.methodCall(destination: nil, path: path, interface: interface, member: member) else {
                return
            }
            try call.append(arguments)
            radio.call(call, now: Monotonic.milliseconds(), reply: then)
        }
    }

    /// The remote devices' GATT servers: linking them, reading them, and letting them go.
    extension FakeBlueZ {
        private func connect(_ call: BusMessage) -> BusConnection.Answer {
            let path = call.path ?? ""
            connectRequests.append(path)
            guard !linked.contains(path) else {
                return .error(name: "org.bluez.Error.AlreadyConnected", message: "Already Connected")
            }
            guard let gatt = remoteGatt[path], gatt.connects else {
                return .error(name: "org.bluez.Error.Failed", message: "le-connection-abort-by-local")
            }
            guard gatt.answersConnect else {
                heldConnects.append(call)
                return .later
            }
            linked.insert(path)
            _ = try? change(path, interface: BlueZ.deviceInterface, .properties([("Connected", .boolean(true))]))
            if gatt.resolves, gatt.resolvesBeforeAnswering {
                _ = try? change(path, interface: BlueZ.deviceInterface, .properties([("ServicesResolved", .boolean(true))]))
                return .values([])
            }
            radio?.reply(to: call, with: [])
            if gatt.resolves {
                _ = try? change(path, interface: BlueZ.deviceInterface, .properties([("ServicesResolved", .boolean(true))]))
            }
            return .later
        }

        /// Answers the oldest `Connect` left unanswered with the error BlueZ gives a cancelled one.
        func failHeldConnect() {
            guard !heldConnects.isEmpty else {
                return
            }
            radio?.reply(to: heldConnects.removeFirst(), error: "org.bluez.Error.Failed", message: "Connection canceled")
        }

        /// Links a device and resolves its services without being asked, as bluetoothd does for a peer that dials us.
        func holdLink(_ path: String) throws {
            linked.insert(path)
            try change(
                path, interface: BlueZ.deviceInterface, .properties([("Connected", .boolean(true)), ("ServicesResolved", .boolean(true))]))
        }

        /// Links a device that dialed us, and leaves its services unread until ``resolve(_:)``, as bluetoothd does for a
        /// while after such a link comes up.
        func holdLinkUnresolved(_ path: String) throws {
            linked.insert(path)
            try change(path, interface: BlueZ.deviceInterface, .properties([("Connected", .boolean(true))]))
        }

        /// bluetoothd finished reading a linked device's services.
        func resolve(_ path: String) throws {
            try change(path, interface: BlueZ.deviceInterface, .properties([("ServicesResolved", .boolean(true))]))
        }

        private func writeValue(_ call: BusMessage, _ arguments: [DBusValue]) -> BusConnection.Answer {
            let path = call.path ?? ""
            guard linked.contains(where: { path.hasPrefix($0 + "/") }) else {
                return .error(name: "org.bluez.Error.Failed", message: "Not connected")
            }
            let type = arguments.dropFirst().first?["type"]?.text
            writes.append(Write(path: path, value: arguments.first?.byteArray ?? [], type: type))
            return .values([])
        }

        private func unlink(_ path: String) {
            guard linked.remove(path) != nil else {
                return
            }
            let down = DBusValue.properties([("Connected", .boolean(false)), ("ServicesResolved", .boolean(false))])
            _ = try? change(path, interface: BlueZ.deviceInterface, down)
        }

        private func readValue(_ call: BusMessage) -> BusConnection.Answer {
            let path = call.path ?? ""
            guard let device = linked.first(where: { path.hasPrefix($0 + "/") }), let gatt = remoteGatt[device], !gatt.readFails,
                let value = gatt.value
            else {
                return .error(name: "org.bluez.Error.Failed", message: "Operation failed with ATT error: 0x0e")
            }
            return .values([.bytes(value)])
        }
    }
#endif
