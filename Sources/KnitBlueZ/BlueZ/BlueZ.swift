import KnitWire

/// How the peer shows itself on the air.
public enum RadioProfile: Sendable, CaseIterable {
    /// Exactly Android's advert: the 24-byte payload as `0xFE30` service data, no name, no UUID list.
    case android
    /// What an iPhone can advertise: the `0xFE30` UUID alone, with the payload in a GATT characteristic. Android
    /// 2.7 cannot see it, so it stands in for an iPhone in interop runs.
    case ios

    /// The profile named `android` or `ios`, as `--radio-profile` spells it.
    public init?(name: String) {
        guard let profile = Self.allCases.first(where: { $0.name == name }) else {
            return nil
        }
        self = profile
    }

    /// The profile's name.
    public var name: String {
        switch self {
        case .android:
            "android"
        case .ios:
            "ios"
        }
    }
}

/// BlueZ's D-Bus names (`doc/org.bluez.*.rst` in BlueZ 5.72).
internal enum BlueZ {
    static let service = "org.bluez"
    static let adapterInterface = "org.bluez.Adapter1"
    static let deviceInterface = "org.bluez.Device1"
    static let advertisingManager = "org.bluez.LEAdvertisingManager1"
    static let advertisementInterface = "org.bluez.LEAdvertisement1"
    static let gattManager = "org.bluez.GattManager1"
    static let gattService = "org.bluez.GattService1"
    static let gattCharacteristic = "org.bluez.GattCharacteristic1"
    static let objectManager = "org.freedesktop.DBus.ObjectManager"
    static let properties = "org.freedesktop.DBus.Properties"
    static let bus = "org.freedesktop.DBus"
    static let busPath = "/org/freedesktop/DBus"

    static let accessDenied = "org.freedesktop.DBus.Error.AccessDenied"
    static let unknownInterface = "org.freedesktop.DBus.Error.UnknownInterface"
    static let unknownProperty = "org.freedesktop.DBus.Error.UnknownProperty"
    static let bluezInvalidOffset = "org.bluez.Error.InvalidOffset"

    /// The `0xFE30` UUID as BlueZ spells a 16-bit one in an advertisement's properties.
    static let knitShortUUID = "FE30"

    /// `GetManagedObjects`' answer, as each object path with its interfaces and their properties.
    static func objects(from value: DBusValue) -> [(path: String, interfaces: [(name: String, properties: DBusValue)])] {
        (value.textKeyed ?? []).map { object in
            (path: object.key, interfaces: (object.value.textKeyed ?? []).map { (name: $0.key, properties: $0.value) })
        }
    }
}

/// What BlueZ has said about one remote device, from `org.bluez.Device1`'s properties.
internal struct BlueZDevice: Equatable {
    /// Its object path, which is also its ``RadioAddress``.
    let path: String
    var address: String?
    /// `public` or `random`.
    var addressType: String?
    var rssi: Int?
    /// Whether BlueZ holds a link to it.
    var connected = false
    /// Service data by lower-case 128-bit UUID.
    var serviceData: [String: [UInt8]] = [:]

    init(path: String) {
        self.path = path
    }

    /// Takes the properties in an `a{sv}` from `InterfacesAdded`, `GetManagedObjects` or `PropertiesChanged`.
    mutating func apply(_ properties: DBusValue) {
        for (name, wrapped) in properties.textKeyed ?? [] {
            let value = wrapped.unwrapped
            switch name {
            case "Address":
                address = value.text
            case "AddressType":
                addressType = value.text
            case "RSSI":
                rssi = value.integer.map { Int($0) }
            case "Connected":
                connected = value.bool ?? connected
            case "ServiceData":
                let pairs = (value.textKeyed ?? []).compactMap { entry in entry.value.byteArray.map { (entry.key.lowercased(), $0) } }
                serviceData = Dictionary(pairs) { _, last in last }
            default:
                continue
            }
        }
    }

    /// Forgets properties BlueZ invalidated: an RSSI goes when the device has not been heard lately.
    mutating func invalidate(_ names: [String]) {
        for name in names {
            switch name {
            case "RSSI":
                rssi = nil
            case "ServiceData":
                serviceData = [:]
            default:
                continue
            }
        }
    }

    /// The Knit advert in its service data, if it has one that parses.
    var advert: AdvertPayload? {
        serviceData[AdvertPayload.serviceUUID].flatMap(AdvertPayload.init(serviceData:))
    }

    /// BlueZ's object path for the device with `address` on `adapter`: `/org/bluez/hci1/dev_4A_00_00_00_00_EF`.
    static func path(of address: BluetoothAddress, on adapter: AdapterSelection) -> String {
        adapter.path + "/dev_" + String(address.description.map { $0 == ":" ? "_" : $0 })
    }

    /// Where to dial it: its address and whether that address is random, as Android's always is.
    var dialTarget: DialTarget? {
        guard let parsed = address.flatMap(BluetoothAddress.init) else {
            return nil
        }
        return DialTarget(address: parsed, isRandom: addressType == "random")
    }
}

/// The properties of this peer's `org.bluez.LEAdvertisement1` object (`doc/org.bluez.LEAdvertisement.rst`).
internal enum AdvertisementProperties {
    /// What BlueZ reads for `payload` under `profile`. Neither profile has a local name or `Includes`: Android's
    /// advert has neither, and 24 bytes of service data leave room for nothing else in 31.
    static func of(_ payload: AdvertPayload, profile: RadioProfile) -> [(String, DBusValue)] {
        let common: [(String, DBusValue)] = [("Type", .string("peripheral")), ("Discoverable", .boolean(true))]
        switch profile {
        case .android:
            let serviceData = DBusValue.properties([(BlueZ.knitShortUUID, .bytes(payload.bytes))])
            return common + [("ServiceData", serviceData)]
        case .ios:
            return common + [("ServiceUUIDs", .strings([BlueZ.knitShortUUID]))]
        }
    }
}

/// The GATT application a `--radio-profile ios` peer registers: one primary `0xFE30` service with one read-only
/// characteristic holding the payload (``AdvertPayload/gattValue``), the way an iPhone serves it.
internal struct GattApplication {
    let root: String

    var servicePath: String { root + "/service0" }
    var characteristicPath: String { servicePath + "/char0" }

    /// `GetManagedObjects`' answer for the application.
    var managedObjects: DBusValue {
        let service = DBusValue.properties([("UUID", .string(AdvertPayload.serviceUUID)), ("Primary", .boolean(true))])
        let characteristic = DBusValue.properties([
            ("UUID", .string(AdvertPayload.characteristicUUID)),
            ("Service", .objectPath(servicePath)),
            ("Flags", .strings(["read"])),
        ])
        let interfaces: (String, DBusValue) -> DBusValue = { name, properties in
            .dictionary(key: .string, value: .dictionary(key: .string, value: .variant), [DBusEntry(key: .string(name), value: properties)])
        }
        return .dictionary(
            key: .objectPath,
            value: .dictionary(key: .string, value: .dictionary(key: .string, value: .variant)),
            [
                DBusEntry(key: .objectPath(servicePath), value: interfaces(BlueZ.gattService, service)),
                DBusEntry(key: .objectPath(characteristicPath), value: interfaces(BlueZ.gattCharacteristic, characteristic)),
            ]
        )
    }

    /// `ReadValue`'s answer: the value from the requested offset, which BlueZ passes when the value is longer than
    /// one ATT read carries. `nil` for an offset past the end.
    static func read(_ value: [UInt8], options: DBusValue?) -> [UInt8]? {
        let offset = options?["offset"]?.integer ?? 0
        guard offset >= 0, offset <= value.count else {
            return nil
        }
        return Array(value[Int(offset)...])
    }
}
