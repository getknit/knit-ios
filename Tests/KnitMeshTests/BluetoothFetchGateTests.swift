import Testing

@testable import KnitMesh

/// Which of our photos declare their length (`BluetoothFetchGate.declaresSize` at knit-next `eac3debc`, knit-ios #7): from
/// 1,000,000 bytes up, and nothing below.
@Suite struct BluetoothFetchGateTests {
    @Test func theFloorDeclaresAndOneByteUnderDoesNot() {
        #expect(BluetoothFetchGate.declareSizeFloor == 1_000_000)
        #expect(!BluetoothFetchGate.declaresSize(BluetoothFetchGate.declareSizeFloor - 1))
        #expect(BluetoothFetchGate.declaresSize(BluetoothFetchGate.declareSizeFloor))
        #expect(!BluetoothFetchGate.declaresSize(0))
    }

    @Test func aPhotoDeclaresItsByteCountFromTheFloor() {
        #expect(OutgoingPhoto(bytes: [UInt8](repeating: 1, count: 999_999), mime: "image/jpeg").declaredSize == nil)
        #expect(OutgoingPhoto(bytes: [UInt8](repeating: 1, count: 1_000_000), mime: "image/jpeg").declaredSize == 1_000_000)
    }
}
