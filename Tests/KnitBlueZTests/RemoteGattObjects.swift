import KnitWire

@testable import KnitBlueZ

/// The objects BlueZ exports for a linked device's GATT server, for the model tests and the fake BlueZ: one primary
/// service with one readable characteristic.
enum RemoteGattObjects {
    /// The service and characteristic BlueZ finds on `device`: Knit's `0xFE30` service with the payload
    /// characteristic, and the doorbell beside it when asked, or, for a device whose `0xFE30` UUID is someone else's, a
    /// battery service. With `apart`, the doorbell sits in a `0xFE30` service of its own listed first, as a blinding
    /// iPhone serves it (ADR 2026-11.prsp).
    static func on(_ device: String, knit: Bool, doorbell: Bool = false, apart: Bool = false) -> [DBusEntry] {
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
            let doorbellService = apart ? doorbellServicePath(of: device) : service
            let doorbellProperties = DBusValue.properties([
                ("UUID", .string(AdvertPayload.doorbellUUID)), ("Service", .objectPath(doorbellService)),
                ("Flags", .strings(["write-without-response", "write"])),
            ])
            let doorbellEntry = DBusEntry(
                key: .objectPath(doorbellPath(of: device, apart: apart)), value: interfaces(BlueZ.gattCharacteristic, doorbellProperties))
            if apart {
                entries.insert(DBusEntry(key: .objectPath(doorbellService), value: interfaces(BlueZ.gattService, serviceProperties)), at: 0)
                entries.insert(doorbellEntry, at: 1)
            } else {
                entries.append(doorbellEntry)
            }
        }
        return entries
    }

    #if os(Linux)
        /// The objects BlueZ finds on `device` serving `gatt`. Linux only, as the fake BlueZ is.
        static func on(_ device: String, serving gatt: FakeBlueZ.RemoteGatt?) -> [DBusEntry] {
            on(device, knit: gatt?.value != nil, doorbell: gatt?.doorbell == true, apart: gatt?.doorbellApart == true)
        }
    #endif

    /// Where the fake puts `device`'s doorbell: beside the payload, or `apart` in a service of its own.
    static func doorbellPath(of device: String, apart: Bool = false) -> String {
        apart ? doorbellServicePath(of: device) + "/char000b" : device + "/service0010/char0013"
    }

    /// The doorbell's own `0xFE30` service, when it sits apart.
    static func doorbellServicePath(of device: String) -> String {
        device + "/service000a"
    }

    /// `GetManagedObjects`' answer holding `entries`.
    static func managedObjects(_ entries: [DBusEntry]) -> DBusValue {
        .dictionary(key: .objectPath, value: .dictionary(key: .string, value: .dictionary(key: .string, value: .variant)), entries)
    }

    private static func interfaces(_ name: String, _ properties: DBusValue) -> DBusValue {
        .dictionary(key: .string, value: .dictionary(key: .string, value: .variant), [DBusEntry(key: .string(name), value: properties)])
    }
}
