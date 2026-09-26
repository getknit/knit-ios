import KnitWire

@testable import KnitBlueZ

/// The objects BlueZ exports for a linked device's GATT server, for the model tests and the fake BlueZ: one primary
/// service with one readable characteristic.
enum RemoteGattObjects {
    /// The service and characteristic BlueZ finds on `device`: Knit's `0xFE30` service with the payload
    /// characteristic, or, for a device whose `0xFE30` UUID is someone else's, a battery service.
    static func on(_ device: String, knit: Bool) -> [DBusEntry] {
        let service = device + "/service0010"
        let characteristic = service + "/char0011"
        let serviceUUID = knit ? AdvertPayload.serviceUUID : "0000180f-0000-1000-8000-00805f9b34fb"
        let characteristicUUID = knit ? AdvertPayload.characteristicUUID : "00002a19-0000-1000-8000-00805f9b34fb"
        let serviceProperties = DBusValue.properties([
            ("UUID", .string(serviceUUID)), ("Device", .objectPath(device)), ("Primary", .boolean(true)),
        ])
        let characteristicProperties = DBusValue.properties([
            ("UUID", .string(characteristicUUID)), ("Service", .objectPath(service)), ("Flags", .strings(["read"])),
        ])
        return [
            DBusEntry(key: .objectPath(service), value: interfaces(BlueZ.gattService, serviceProperties)),
            DBusEntry(key: .objectPath(characteristic), value: interfaces(BlueZ.gattCharacteristic, characteristicProperties)),
        ]
    }

    /// `GetManagedObjects`' answer holding `entries`.
    static func managedObjects(_ entries: [DBusEntry]) -> DBusValue {
        .dictionary(key: .objectPath, value: .dictionary(key: .string, value: .dictionary(key: .string, value: .variant)), entries)
    }

    private static func interfaces(_ name: String, _ properties: DBusValue) -> DBusValue {
        .dictionary(key: .string, value: .dictionary(key: .string, value: .variant), [DBusEntry(key: .string(name), value: properties)])
    }
}
