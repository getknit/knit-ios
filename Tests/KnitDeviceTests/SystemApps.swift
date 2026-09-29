import XCTest

/// The two system apps the device tests drive beside Knit: the Settings app, for Bluetooth and Knit's own permission,
/// and SpringBoard, which asks for that permission. Apple's words live here and nowhere else, because they move
/// between iOS versions; when a step here fails, the app's element tree is attached, which names the new ones.
@MainActor
struct SystemApps {
    /// Apple's words on iOS 27.
    private enum Words {
        static let bluetooth = "Bluetooth"
        static let allow = "Allow"
        static let dontAllow = "Don’t Allow"
    }

    /// How long a prompt that may be on its way gets to show.
    private static let promptWait: TimeInterval = 2

    let preferences = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// Switches Bluetooth on or off in the Settings app, as someone would, and leaves the Settings app in front.
    func setBluetooth(on: Bool) throws {
        try explained(preferences, "the Settings app") {
            preferences.launch()
            try preferences.reveal(preferences.staticTexts[Words.bluetooth].firstMatch, "Settings' Bluetooth row").tap()
            try flip(preferences.switches[Words.bluetooth].firstMatch, on: on, "the Bluetooth switch")
        }
    }

    /// Switches Knit's Bluetooth permission on Knit's own page in the Settings app, where the status line's Settings
    /// button lands. Changing it ends Knit's process either way, so Knit launches again after.
    func setKnitBluetooth(on: Bool) throws {
        try explained(preferences, "the Settings app") {
            guard preferences.wait(for: .runningForeground, timeout: Walking.appears) else {
                throw Missing(what: "the Settings app")
            }
            try flip(preferences.switches[Words.bluetooth].firstMatch, on: on, "Knit's Bluetooth switch")
        }
    }

    /// Answers the system's question whether Knit may use Bluetooth.
    func answerBluetoothPrompt(allow: Bool) throws {
        try explained(springboard, "SpringBoard") {
            let alert = springboard.alerts.firstMatch
            try alert.appear("the Bluetooth prompt")
            try alert.buttons[allow ? Words.allow : Words.dontAllow].appear(allow ? "Allow" : "Don't Allow").tap()
        }
    }

    /// Throws if a system prompt is up before `step`, which should be the one to ask. XCTest answers an alert that
    /// blocks a tap by itself, so a prompt that came early would otherwise pass unseen.
    func noPrompt(before step: String) throws {
        if springboard.alerts.firstMatch.waitForExistence(timeout: Self.promptWait) {
            throw Mismatch(what: "the Bluetooth prompt", expected: "only after \(step)", found: "up before it")
        }
    }

    /// Answers the Bluetooth prompt with Allow if it is up, as it is after a reset permission.
    func allowBluetoothIfAsked() {
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: Self.promptWait) {
            alert.buttons[Words.allow].tap()
        }
    }

    /// Sets `toggle` to `on` and waits for it to say so. A switch in a list row answers a tap on itself, or only on
    /// the switch nested inside it; the tap goes to whichever there is.
    private func flip(_ toggle: XCUIElement, on: Bool, _ what: String) throws {
        try toggle.appear(what)
        let wanted = on ? "1" : "0"
        if toggle.value as? String == wanted {
            return
        }
        let nested = toggle.switches.firstMatch
        (nested.exists ? nested : toggle).tap()
        let flipped = NSPredicate(format: "value == %@", wanted)
        let waited = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: flipped, object: toggle)], timeout: Walking.appears)
        guard waited == .completed else {
            throw Mismatch(what: what, expected: wanted, found: "\(toggle.value ?? "nothing")")
        }
    }

    /// Runs `step`, and when it throws, attaches `app`'s element tree and a screenshot before passing the error on.
    private func explained(_ app: XCUIApplication, _ name: String, _ step: () throws -> Void) throws {
        do {
            try step()
        } catch {
            XCTContext.runActivity(named: "what \(name) showed") { activity in
                let tree = XCTAttachment(string: app.debugDescription)
                tree.lifetime = .keepAlways
                activity.add(tree)
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.lifetime = .keepAlways
                activity.add(shot)
            }
            throw error
        }
    }
}
