import KnitWire

@testable import KnitBlueZ

/// The objects BlueZ exports for a linked device's GATT server, for the model tests and the fake BlueZ: one primary
/// service with one readable characteristic.
enum RemoteGattObjects {
    /// The service and characteristic BlueZ finds on `device`: Knit's `0xFE30` service with the payload
    /// characteristic, and the doorbell beside it when asked, or, for a device whose `0xFE30` UUID is someone else's, a
    /// battery service.
    static func on(_ device: String, knit: Bool, doorbell: Bool = false) -> [DBusEntry] {
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
        var entries = [
            DBusEntry(key: .objectPath(service), value: interfaces(BlueZ.gattService, serviceProperties)),
            DBusEntry(key: .objectPath(characteristic), value: interfaces(BlueZ.gattCharacteristic, characteristicProperties)),
        ]
        if knit, doorbell {
            let doorbellProperties = DBusValue.properties([
                ("UUID", .string(AdvertPayload.doorbellUUID)), ("Service", .objectPath(service)),
                ("Flags", .strings(["write-without-response", "write"])),
            ])
            entries.append(
                DBusEntry(key: .objectPath(doorbellPath(of: device)), value: interfaces(BlueZ.gattCharacteristic, doorbellProperties)))
        }
        return entries
    }

    /// Where the fake puts `device`'s doorbell.
    static func doorbellPath(of device: String) -> String {
        device + "/service0010/char0013"
    }

    /// `GetManagedObjects`' answer holding `entries`.
    static func managedObjects(_ entries: [DBusEntry]) -> DBusValue {
        .dictionary(key: .objectPath, value: .dictionary(key: .string, value: .dictionary(key: .string, value: .variant)), entries)
    }

    private static func interfaces(_ name: String, _ properties: DBusValue) -> DBusValue {
        .dictionary(key: .string, value: .dictionary(key: .string, value: .variant), [DBusEntry(key: .string(name), value: properties)])
    }
}
