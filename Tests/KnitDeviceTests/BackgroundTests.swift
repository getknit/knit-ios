import XCTest

/// Two steps `interop.py` runs from the Mac, one at a time, to move Knit out of the front and back with nobody at the
/// iPhone: the Settings app in front leaves Knit in the background, where iOS moves its service UUID to the overflow
/// area (knit-next's AND-3 trial, `.agents/context/linux-peer.md`). Neither step launches or ends Knit: a new process
/// would end the links the trial watches. So they reach the running Knit by its bundle id, which works when the run
/// leaves the app out of the install (`KNIT_DEVICE_KEEP_KNIT`, `scripts/check.sh`), and never call `Phone.restore`.
@MainActor
final class BackgroundTests: XCTestCase {
    /// The debug build's bundle id (`App/project.yml`), the only Knit the bridge answers in.
    private static let knitBundle = "app.getknit.knit.dev"

    /// How long iOS gets to move an app to the front or away from it.
    private static let settles: TimeInterval = 20

    private let knit = XCUIApplication(bundleIdentifier: BackgroundTests.knitBundle)
    private let system = SystemApps()

    /// Brings the Settings app to the front, which sends a running Knit to the background.
    func testSendKnitToBackground() throws {
        try requireRunningKnit()
        system.preferences.activate()
        guard system.preferences.wait(for: .runningForeground, timeout: Self.settles) else {
            throw Mismatch(what: "the Settings app", expected: "in front", found: "\(system.preferences.state)")
        }
        let away = NSPredicate { app, _ in
            guard let state = (app as? XCUIApplication)?.state else { return false }
            return state == .runningBackground || state == .runningBackgroundSuspended
        }
        let waited = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: away, object: knit)], timeout: Self.settles)
        guard waited == .completed else {
            throw Mismatch(what: "Knit", expected: "in the background", found: "\(knit.state)")
        }
    }

    /// Brings the running Knit back to the front, as its app switcher card would.
    func testBringKnitToFront() throws {
        try requireRunningKnit()
        knit.activate()
        guard knit.wait(for: .runningForeground, timeout: Self.settles) else {
            throw Mismatch(what: "Knit", expected: "in front", found: "\(knit.state)")
        }
    }

    /// Skips the step when Knit is not running, since starting it is the one thing these steps must never do. In the
    /// whole suite that is an earlier test's leftover; from `interop.py`, the bridge then stays silent, and the run
    /// fails there.
    private func requireRunningKnit() throws {
        if knit.state == .notRunning {
            throw XCTSkip("Knit is not running, and this step never launches it")
        }
    }
}
