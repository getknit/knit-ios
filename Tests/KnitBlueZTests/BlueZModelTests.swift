import KnitTestSupport
import KnitWire
import Testing

@testable import KnitBlueZ

/// The adapter guard, and what the radio makes of BlueZ's properties.
@Suite struct BlueZModelTests {
    // MARK: The adapter

    /// The maintainer's adapter is refused by its address, whatever index the kernel gave it this boot.
    @Test(arguments: ["hci0", "hci1"])
    func theMaintainersAdapterIsRefusedUnderAnyName(_ name: String) {
        #expect(throws: AdapterSelection.Refusal.reservedAdapter) {
            try AdapterSelection(name: name, expectedAddress: "a0:00:00:00:00:01")
        }
    }

    @Test func theMaintainersAdapterIsTakenOnlyAsSharedAndStillByItsAddress() throws {
        let selection = try AdapterSelection(name: "hci1", expectedAddress: "A0:00:00:00:00:01", shared: true)
        #expect(selection.shared)
        #expect(selection.path == "/org/bluez/hci1")
        try selection.check(reportedAddress: "A0:00:00:00:00:01")
        #expect(throws: AdapterSelection.Refusal.self) { try selection.check(reportedAddress: "F0:0D:00:00:00:02") }
        #expect(try !AdapterSelection(name: "hci1", expectedAddress: "F0:0D:00:00:00:02").shared)
    }

    /// A reboot on 2026-10-01 made the ATS2851 `hci0`, which is no reason to refuse it.
    @Test func hci0IsTakenLikeAnyOtherName() throws {
        let selection = try AdapterSelection(name: "hci0", expectedAddress: "F0:0D:00:00:00:02")
        #expect(selection.path == "/org/bluez/hci0")
        #expect(!selection.shared)
    }

    /// `GetManagedObjects`' answer on 2026-10-01: the ATS2851 at `hci0`, the maintainer's adapter at `hci1`, and a
    /// device of the ATS2851's that, being no adapter, never matches.
    private let swapped: [(path: String, interfaces: [(name: String, properties: DBusValue)])] = [
        ("/org/bluez", [(name: "org.bluez.AgentManager1", properties: .properties([]))]),
        ("/org/bluez/hci0", [(name: BlueZ.adapterInterface, properties: .properties([("Address", .string("F0:0D:00:00:00:02"))]))]),
        (
            "/org/bluez/hci0/dev_00_11_22_33_44_55",
            [(name: BlueZ.deviceInterface, properties: .properties([("Address", .string("00:11:22:33:44:55"))]))]
        ),
        ("/org/bluez/hci1", [(name: BlueZ.adapterInterface, properties: .properties([("Address", .string("A0:00:00:00:00:01"))]))]),
    ]

    @Test func anAdapterIsFoundByItsAddressUnderWhateverNameItHas() throws {
        let dongle = try AdapterSelection.find("f0:0d:00:00:00:02", shared: false, among: swapped)
        #expect(dongle == (try AdapterSelection(name: "hci0", expectedAddress: "F0:0D:00:00:00:02")))
        #expect(throws: AdapterSelection.Refusal.reservedAdapter) {
            try AdapterSelection.find("A0:00:00:00:00:01", shared: false, among: swapped)
        }
        #expect(try AdapterSelection.find("A0:00:00:00:00:01", shared: true, among: swapped).name == "hci1")
        #expect(throws: AdapterSelection.Refusal.absent("00:11:22:33:44:55"), "a device is no adapter") {
            try AdapterSelection.find("00:11:22:33:44:55", shared: false, among: swapped)
        }
        #expect(throws: AdapterSelection.Refusal.notAnAddress("hci0")) { try AdapterSelection.find("hci0", shared: false, among: swapped) }
    }

    @Test(arguments: ["", "hci", "hci1a", "HCI1", "wlan0", "hci-1", "/org/bluez/hci1"])
    func onlyAnHciNameIsAnAdapter(_ name: String) {
        #expect(throws: AdapterSelection.Refusal.notAnAdapterName(name)) {
            try AdapterSelection(name: name, expectedAddress: "0A:BC:DE:00:00:A1")
        }
    }

    @Test func theExpectedAddressMustBeAnAddress() {
        #expect(throws: AdapterSelection.Refusal.notAnAddress("0A:BC:DE")) {
            try AdapterSelection(name: "hci1", expectedAddress: "0A:BC:DE")
        }
    }

    @Test func theAdapterMustBePresentWithItsAddress() throws {
        let selection = try AdapterSelection(name: "hci1", expectedAddress: "0a:bc:de:00:00:a1")
        #expect(selection.path == "/org/bluez/hci1")
        try selection.check(reportedAddress: "0A:BC:DE:00:00:A1")
        #expect(throws: AdapterSelection.Refusal.absent("hci1")) { try selection.check(reportedAddress: nil) }
        #expect(throws: AdapterSelection.Refusal.self) { try selection.check(reportedAddress: "0B:00:00:00:00:13") }
        #expect(throws: AdapterSelection.Refusal.self) { try selection.check(reportedAddress: "garbage") }
    }

    @Test func onlyTheAdapterAndItsDevicesBelongToIt() throws {
        let selection = try AdapterSelection(name: "hci1", expectedAddress: "0A:BC:DE:00:00:A1")
        #expect(selection.owns("/org/bluez/hci1"))
        #expect(selection.owns("/org/bluez/hci1/dev_4A_00_00_00_00_EF"))
        #expect(!selection.owns("/org/bluez/hci0"))
        #expect(!selection.owns("/org/bluez/hci0/dev_4A_00_00_00_00_EF"))
        #expect(!selection.owns("/org/bluez/hci10"), "hci10 is not hci1")
        #expect(!selection.owns("/org/bluez"))
    }

    @Test func onlyAQuietUnlinkedDeviceNobodyOwnsIsStale() {
        var device = BlueZDevice(path: "/org/bluez/hci1/dev_4A_00_00_00_00_EF")
        #expect(!device.isStale(now: 100_000, quietMilliseconds: 60_000), "never heard, so never forgotten")
        device.heardAt = 30_000
        #expect(!device.isStale(now: 89_999, quietMilliseconds: 60_000))
        #expect(device.isStale(now: 90_000, quietMilliseconds: 60_000))
        for owned in ["Paired", "Bonded", "Trusted", "Connected"] {
            var kept = device
            kept.apply(.properties([(owned, .boolean(true))]))
            #expect(!kept.isStale(now: 1_000_000, quietMilliseconds: 60_000), "\(owned) is kept")
        }
        device.listedBeforeUs = true
        #expect(!device.isStale(now: 1_000_000, quietMilliseconds: 60_000), "a shared adapter's own list is kept")
    }

    @Test func aDevicesPathComesFromItsAddress() throws {
        let adapter = try AdapterSelection(name: "hci1", expectedAddress: "0A:BC:DE:00:00:A1")
        let address = try #require(BluetoothAddress("4a:00:00:00:00:ef"))
        #expect(BlueZDevice.path(of: address, on: adapter) == "/org/bluez/hci1/dev_4A_00_00_00_00_EF")
        #expect(BluetoothAddress(bytes: address.bytes) == address)
        #expect(BluetoothAddress(bytes: [1, 2, 3]) == nil)
    }

    @Test func addressesParseEitherCaseAndPrintInUpperCase() throws {
        let address = try #require(BluetoothAddress("0a:bc:de:00:00:a1"))
        #expect(address.description == "0A:BC:DE:00:00:A1")
        #expect(address.bytes == [0x0A, 0xBC, 0xDE, 0x00, 0x00, 0xA1])
        #expect(address.littleEndian == [0xA1, 0x00, 0x00, 0xDE, 0xBC, 0x0A], "bdaddr_t is least significant first")
        #expect(BluetoothAddress("0:1:2:3:4:5") == nil)
        #expect(BluetoothAddress("0A:BC:DE:00:00") == nil)
        #expect(BluetoothAddress("0A:BC:DE:00:00:GG") == nil)
        #expect(BluetoothAddress("") == nil)
    }

    // MARK: Devices

    @Test func aDeviceTakesWhatBlueZSays() throws {
        let advert = AdvertPayload(capabilities: 0xFFF, nodeId: fixtureNodeId(4), digestCue: 1, psm: 0x81)
        var device = BlueZDevice(path: "/org/bluez/hci1/dev_x")
        device.apply(
            .properties([
                ("Address", .string("4A:00:00:00:00:EF")), ("AddressType", .string("random")), ("RSSI", .int16(-58)),
                ("ServiceData", .properties([("0000FE30-0000-1000-8000-00805F9B34FB", .bytes(advert.bytes))])),
                ("Name", .string("ignored")),
            ])
        )
        #expect(device.rssi == -58)
        #expect(device.advert == advert, "the UUID is matched in any case")
        let target = try #require(device.dialTarget)
        #expect(target.isRandom)
        #expect(target.address.description == "4A:00:00:00:00:EF")
        #expect(!device.connected)
        device.apply(.properties([("Connected", .boolean(true))]))
        #expect(device.connected)
        device.apply(.properties([("Connected", .string("garbled"))]))
        #expect(device.connected, "a value that is not a boolean changes nothing")
        device.invalidate(["RSSI", "Name"])
        #expect(device.rssi == nil)
        device.invalidate(["ServiceData"])
        #expect(device.advert == nil)
    }

    @Test func aPublicAddressDialsAsPublic() throws {
        var device = BlueZDevice(path: "/org/bluez/hci1/dev_x")
        device.apply(.properties([("Address", .string("0A:BC:DE:00:00:A1")), ("AddressType", .string("public"))]))
        #expect(try #require(device.dialTarget).isRandom == false)
    }

    @Test func serviceDataThatIsNotAKnitAdvertIsNoAdvert() {
        var device = BlueZDevice(path: "/org/bluez/hci1/dev_x")
        device.apply(.properties([("ServiceData", .properties([(AdvertPayload.serviceUUID, .bytes([1, 2, 3]))]))]))
        #expect(device.advert == nil)
        device.apply(
            .properties([("ServiceData", .properties([("0000feaa-0000-1000-8000-00805f9b34fb", .bytes([UInt8](repeating: 1, count: 24)))]))]
            ))
        #expect(device.advert == nil)
        #expect(device.dialTarget == nil)
    }

    @Test func aDeviceListingTheServiceWithoutServiceDataServesItsPayloadOverGATT() {
        var device = BlueZDevice(path: "/org/bluez/hci1/dev_x")
        #expect(!device.servesPayloadOverGatt)
        device.apply(.properties([("UUIDs", .strings(["0000180F-0000-1000-8000-00805F9B34FB", "0000FE30-0000-1000-8000-00805F9B34FB"]))]))
        #expect(device.servesPayloadOverGatt, "the UUID is matched in any case")
        device.apply(.properties([("UUIDs", .string("garbled"))]))
        #expect(device.servesPayloadOverGatt, "a value that is not a list changes nothing")
        let advert = AdvertPayload(capabilities: 0xFFF, nodeId: fixtureNodeId(4), digestCue: 1, psm: 0x81)
        device.apply(.properties([("ServiceData", .properties([(AdvertPayload.serviceUUID, .bytes(advert.bytes))]))]))
        #expect(!device.servesPayloadOverGatt, "its service data is the advert")
        device.invalidate(["ServiceData", "UUIDs"])
        #expect(device.uuids.isEmpty)
        #expect(!device.servesPayloadOverGatt)
        #expect(!device.servicesResolved)
        device.apply(.properties([("ServicesResolved", .boolean(true))]))
        #expect(device.servicesResolved)
    }

    @Test func thePayloadCharacteristicIsTheKnitOneInAnFE30ServiceOfThatDevice() {
        let device = "/org/bluez/hci1/dev_x"
        let knit = RemoteGattObjects.managedObjects(RemoteGattObjects.on(device, knit: true))
        #expect(BlueZ.payloadCharacteristic(in: knit, on: device) == device + "/service0010/char0011")
        #expect(BlueZ.payloadCharacteristic(in: knit, on: "/org/bluez/hci1/dev_y") == nil, "another device's")
        #expect(BlueZ.payloadCharacteristic(in: knit, on: "/org/bluez/hci1/dev") == nil, "a path that only starts alike")
        let battery = RemoteGattObjects.on(device, knit: false)
        #expect(BlueZ.payloadCharacteristic(in: RemoteGattObjects.managedObjects(battery), on: device) == nil)
        // The Knit characteristic, but in a service that is not 0xFE30.
        let misplaced = [battery[0], RemoteGattObjects.on(device, knit: true)[1]]
        #expect(BlueZ.payloadCharacteristic(in: RemoteGattObjects.managedObjects(misplaced), on: device) == nil)
    }

    @Test func managedObjectsReadAsPathsAndInterfaces() {
        let objects = DBusValue.dictionary(
            key: .objectPath,
            value: .dictionary(key: .string, value: .dictionary(key: .string, value: .variant)),
            [
                DBusEntry(
                    key: .objectPath("/a"),
                    value: .dictionary(
                        key: .string,
                        value: .dictionary(key: .string, value: .variant),
                        [DBusEntry(key: .string("org.example.One"), value: .properties([("X", .int32(1))]))]
                    )
                )
            ]
        )
        let read = BlueZ.objects(from: objects)
        #expect(read.map(\.path) == ["/a"])
        #expect(read.first?.interfaces.first?.name == "org.example.One")
        #expect(BlueZ.objects(from: .string("nothing")).isEmpty)
    }

    // MARK: What the radio publishes

    @Test func theAndroidAdvertIsServiceDataWithNoName() {
        let advert = AdvertPayload(capabilities: .local, nodeId: fixtureNodeId(5), digestCue: 0, psm: 0x80)
        let properties = DBusValue.properties(AdvertisementProperties.of(advert, profile: .android))
        #expect(properties.textKeyed?.map(\.key) == ["Type", "Discoverable", "ServiceData"])
        #expect(properties["ServiceData"]?["FE30"]?.byteArray == advert.bytes)
    }

    @Test func theIOSAdvertIsTheUUIDAlone() {
        let advert = AdvertPayload(capabilities: .local, nodeId: fixtureNodeId(5), digestCue: 0, psm: 0x80)
        let properties = DBusValue.properties(AdvertisementProperties.of(advert, profile: .ios))
        #expect(properties.textKeyed?.map(\.key) == ["Type", "Discoverable", "ServiceUUIDs"])
        #expect(properties["ServiceUUIDs"]?.textArray == ["FE30"])
    }

    @Test func aGATTReadHonoursItsOffset() {
        let value: [UInt8] = Array(0..<24)
        #expect(GattApplication.read(value, options: nil) == value)
        #expect(GattApplication.read(value, options: .properties([("offset", .uint16(22))])) == [22, 23])
        #expect(GattApplication.read(value, options: .properties([("offset", .uint16(24))]))?.isEmpty == true)
        #expect(GattApplication.read(value, options: .properties([("offset", .uint16(25))])) == nil)
        #expect(GattApplication.read(value, options: .properties([("offset", .int32(-1))])) == nil)
    }

    @Test func theApplicationIsOneServiceWithThePayloadAndTheDoorbell() {
        let application = GattApplication(root: "/app/x/gatt")
        #expect(application.servicePath == "/app/x/gatt/service0")
        #expect(application.characteristicPath == "/app/x/gatt/service0/char0")
        #expect(application.doorbellPath == "/app/x/gatt/service0/char1")
        #expect(application.managedObjects.isWellFormed)
        #expect(
            BlueZ.objects(from: application.managedObjects).map(\.path)
                == [application.servicePath, application.characteristicPath, application.doorbellPath])
        #expect(BlueZ.doorbellCharacteristic(in: application.managedObjects, on: "/app/x/gatt") == application.doorbellPath)
    }

    @Test func everyProfileHasAName() {
        #expect(RadioProfile.allCases.map(\.name) == ["android", "ios"])
        #expect(RadioProfile(name: "ios") == .ios)
        #expect(RadioProfile(name: "lora") == nil)
    }

    @Test func eachProfileFindsPeersAsItsPlatformDoes() {
        #expect(RadioProfile.android.advertisesServiceData)
        #expect(!RadioProfile.android.readsGattPayloads, "by default, as Android before knit-next 713b29d6 reads none")
        #expect(!RadioProfile.ios.advertisesServiceData)
        #expect(RadioProfile.ios.readsGattPayloads)
    }
}
