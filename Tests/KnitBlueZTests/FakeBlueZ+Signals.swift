#if os(Linux)
    @testable import KnitBlueZ
    import KnitWire

    /// What the fake BlueZ tells the radio: devices appearing and going, their properties changing, and the adapter's power.
    extension FakeBlueZ {
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

        /// A GATT object of a linked device appears, as BlueZ adds it after a services change.
        func addObject(_ path: String, interface: String, _ properties: DBusValue) throws {
            let values: [DBusValue] = [.objectPath(path), Self.interfaces([(interface, properties)])]
            try radio?.emit(path: "/", interface: BlueZ.objectManager, member: "InterfacesAdded", values: values)
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
    }
#endif
