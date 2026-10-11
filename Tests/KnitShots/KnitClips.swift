// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

/// App Review's clips (ADR 2026-10.yddp): each test plays the user through one feature on a scripted demo scene while
/// `scripts/check.sh clips` films the Simulator, and the app's `DemoDirector` plays everyone else.
///
/// Each keeps marks on the host's clock, as `KnitTrailer` does, in an attachment named `<clip>_marks`, which the gate
/// turns into seconds into its recording, so the cut and its captions need nobody's eye. Between steps it holds still
/// for as long as a person watching needs to read what changed: the test itself would move on at once.
@MainActor
final class KnitClips: XCTestCase {
    /// How long the film holds on something new, for someone watching to read it.
    private static let read: TimeInterval = 2.5
    /// How long it holds before a tap, for someone watching to see where it lands.
    private static let glance: TimeInterval = 1
    /// How long a step gets: the director's beats run at a person's pace.
    private static let step: TimeInterval = 30
    /// How many times a sliding control's frame is read, and how far apart, before it counts as still.
    private static let frameReads = 20
    private static let frameInterval: TimeInterval = 0.1

    private var marks: [String] = []

    /// A stranger in the room turns on the user, who reports the post from its menu with Report and Email Knit. The
    /// post goes and the stranger is blocked; the Simulator has no Mail, so the alert naming Knit's address shows. The
    /// stranger posts again and nothing arrives, while Sam's post does. Then Settings' blocked people, the stranger's
    /// profile, and Unblock.
    func testBlock() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-demoScene", "block"]
        app.launch()
        let room = try app.appear(AccessibilityID.chatRow("nearby"))
        mark("room")
        room.tap()
        try app.appear(AccessibilityID.chatThread)

        let rude = try app.element(AccessibilityID.chatMessage("block-1")).appear("the stranger's post", timeout: Self.step)
        mark("abuse")
        hold(Self.read)
        rude.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)).press(forDuration: 1)
        let report = try app.appear(AccessibilityID.chatMessageReport)
        hold(Self.glance)
        report.tap()
        let email = try confirmation("Report and Email Knit", in: app)
        mark("confirm")
        hold(Self.read)
        email.tap()
        let copy = try confirmation("Copy Address", in: app)
        mark("address")
        hold(Self.read)
        copy.tap()
        XCTAssert(rude.waitForNonExistence(timeout: Walking.appears), "the reported post stayed")
        mark("reported")

        try app.element(AccessibilityID.chatMessage("block-3")).appear("Sam's post", timeout: Self.step)
        XCTAssertFalse(app.element(AccessibilityID.chatMessage("block-2")).exists, "the blocked stranger's post arrived")
        mark("quiet")
        hold(Self.read)

        try unblockFromSettings(in: app)
        mark("unblocked")
        hold(Self.read)
        mark("end")
        keep("block")
        app.terminate()
    }

    /// Back to the chat list, then Settings' blocked people, the stranger's profile, and its Unblock, which acts at once.
    private func unblockFromSettings(in app: XCUIApplication) throws {
        mark("leaving")
        app.back()
        try app.appear(AccessibilityID.chatListSettings).tap()
        let blocked = try app.reveal(AccessibilityID.settingsBlocked)
        hold(Self.glance)
        blocked.tap()
        let row = try app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.blockedRow("")))
            .firstMatch.appear("the stranger's row")
        mark("list")
        hold(Self.read)
        row.tap()
        try app.appear(AccessibilityID.profileDetailsBlocked)
        let unblock = try app.reveal(AccessibilityID.profileDetailsBlock)
        mark("profile")
        hold(Self.read)
        unblock.tap()
        XCTAssert(
            app.element(AccessibilityID.profileDetailsBlocked).waitForNonExistence(timeout: Walking.appears),
            "the badge stayed after Unblock")
    }

    /// Notes the host's time now under `name`.
    private func mark(_ name: String) {
        marks.append("\(name)=\(Date().timeIntervalSince1970)")
    }

    /// Keeps the marks for the gate, as `<clip>_marks`.
    private func keep(_ clip: String) {
        let attachment = XCTAttachment(string: marks.joined(separator: "\n"))
        attachment.name = "\(clip)_marks"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Holds the film still for `seconds`.
    private func hold(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "someone watching")], timeout: seconds)
    }

    /// The alert's `action`, once it has stopped moving. Its buttons carry no identifier, which tells it from the control
    /// that opened it.
    private func confirmation(_ action: String, in app: XCUIApplication) throws -> XCUIElement {
        let button = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", action, "")).firstMatch
        try button.appear("the \(action) button")
        var last = CGRect.null
        for _ in 0..<Self.frameReads where button.frame != last {
            last = button.frame
            hold(Self.frameInterval)
        }
        return button
    }
}

// swiftlint:enable prefer_nimble
