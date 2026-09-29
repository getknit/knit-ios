import XCTest

/// MVP item 10 on the iPhone, live: Stop and Start, and Bluetooth switched off and on in the Settings app, each read from
/// the state the chat list's status line names.
@MainActor
final class RadioTests: XCTestCase {
    /// Settings stops the mesh and starts it again; the stopped line offers its own Start, which starts it too.
    func testStopAndStart() throws {
        let phone = Phone()
        try phone.restore()
        defer { try? phone.restore() }
        let knit = phone.knit

        try knit.toggleMeshInSettings()
        try knit.status(in: [.stopped])
        try knit.toggleMeshInSettings()
        try knit.status(in: LiveKnit.running)

        try knit.toggleMeshInSettings()
        try knit.status(in: [.stopped])
        try knit.app.appear(AccessibilityID.chatListStatusStart).tap()
        try knit.status(in: LiveKnit.running)
    }

    /// Bluetooth off has its own line, and the mesh comes back when Bluetooth does, in the same process.
    func testBluetoothOffAndOn() throws {
        let phone = Phone()
        try phone.restore()
        defer { try? phone.restore() }
        let knit = phone.knit

        try phone.system.setBluetooth(on: false)
        try knit.stillRunning()
        knit.app.activate()
        try knit.status(in: [.bluetoothOff])

        try phone.system.setBluetooth(on: true)
        try knit.stillRunning()
        knit.app.activate()
        try knit.status(in: LiveKnit.running)
    }
}
