#if os(Linux)
    @testable import KnitBlueZ
    import KnitWire

    /// Just enough of bluetoothd for the radio: an object tree with `hci1` (and `hci0`, which the radio must ignore),
    /// discovery, the advertising manager, which reads each advert back through `Properties.GetAll` before it
    /// answers as BlueZ does, and the GATT manager, which reads the application's objects.
    final class FakeBlueZ {
        static let adapter = "/org/bluez/hci1"
        static let adapterAddress = "0A:BC:DE:00:00:A1"
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
                return .values([])
            default:
                return .unknown
            }
        }

        private func register(advert path: String, call: BusMessage) -> BusConnection.Answer {
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
        static func device(address: String, random: Bool = true, rssi: Int16? = -55, advert: AdvertPayload?) -> DBusValue {
            var pairs: [(String, DBusValue)] = [("Address", .string(address)), ("AddressType", .string(random ? "random" : "public"))]
            if let rssi {
                pairs.append(("RSSI", .int16(rssi)))
            }
            if let advert {
                pairs.append(("ServiceData", .properties([(AdvertPayload.serviceUUID, .bytes(advert.bytes))])))
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
        func setPowered(_ on: Bool) throws {
            powered = on
            if !on {
                registered.removeAll()
                applicationRoot = nil
            }
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
#endif
