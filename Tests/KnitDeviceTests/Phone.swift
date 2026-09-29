import XCTest

/// Knit and the system apps on the one iPhone, and the state every device test starts from and leaves behind.
@MainActor
struct Phone {
    /// How many things `restore` may put right before the mesh has to be running.
    private static let repairs = 4

    let knit = LiveKnit()
    let system = SystemApps()

    /// Brings the phone back to where every test starts: Bluetooth on, Knit allowed it, and Knit's mesh running on
    /// the chat list. Each test calls it first, and again as it ends, so one that fails leaves the next a phone it can
    /// use, and the phone is left as `interop.py` expects it.
    func restore() throws {
        knit.launch()
        var settled = Set(AccessibilityID.StatusState.allCases)
        settled.remove(.starting)
        for _ in 0..<Self.repairs {
            system.allowBluetoothIfAsked()
            switch try knit.status(in: settled) {
            case .linked, .looking:
                return
            case .stopped:
                try knit.app.appear(AccessibilityID.chatListStatusStart).tap()
            case .bluetoothOff:
                try system.setBluetooth(on: true)
                knit.app.activate()
            case .notAllowed:
                try knit.app.appear(AccessibilityID.chatListStatusSettings).tap()
                try system.setKnitBluetooth(on: true)
                knit.launch()
            case .starting:
                // Not among the settled states, which `status` waits through.
                continue
            case .unsupported:
                throw Mismatch(what: "the radio", expected: "Bluetooth LE", found: "none")
            }
        }
        try knit.status(in: LiveKnit.running)
    }
}
