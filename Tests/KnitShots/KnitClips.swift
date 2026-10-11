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

    /// The demo's filters flag a stranger's words and photo in the room, and both show hidden; a tap shows the words, never
    /// the photo. The room then refuses a flagged reply, typed into its composer, and Settings shows Content filtering.
    /// What is flagged is the scene's choice, not the model's (ADR 2026-10.yddp): the photo is an ordinary one standing in.
    func testFilter() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-demoScene", "filter"]
        app.launch()
        let room = try app.appear(AccessibilityID.chatRow("nearby"))
        mark("room")
        room.tap()
        try app.appear(AccessibilityID.chatThread)

        try hiding(AccessibilityID.chatMessage("filter-1"), in: app, hidden: true).appear(
            "the stranger's words, hidden", timeout: Self.step)
        mark("words")
        hold(Self.read)
        try hiding(AccessibilityID.chatPhoto("filter-2"), in: app, hidden: true).appear("the stranger's photo, hidden", timeout: Self.step)
        mark("photo")
        hold(Self.read)
        try app.element(AccessibilityID.chatMessage("filter-3")).appear("Sam's post", timeout: Self.step)
        hold(Self.glance)
        // The tap goes left of the bubble's middle, on the line that stands in for the words, below the author's name.
        app.element(AccessibilityID.chatMessage("filter-1")).coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6)).tap()
        try hiding(AccessibilityID.chatMessage("filter-1"), in: app, hidden: false).appear("the stranger's words, shown")
        mark("shown")
        hold(Self.read)
        XCTAssert(hiding(AccessibilityID.chatPhoto("filter-2"), in: app, hidden: true).exists, "the photo showed with the words")

        try refuseReply(in: app)
        mark("leaving")
        app.back()
        try app.appear(AccessibilityID.chatListSettings).tap()
        try app.reveal(AccessibilityID.settingsContentFiltering)
        mark("setting")
        hold(Self.read)
        hold(Self.glance)
        mark("end")
        keep("filter")
        app.terminate()
    }

    /// Types the scene's flagged reply into the room's composer and sends it: the room refuses it, and Done puts the alert
    /// away with the words still in the composer.
    private func refuseReply(in app: XCUIApplication) throws {
        // `DemoCast.filteredReply`, which the demo's text filter is told to flag.
        let reply = "Get lost, creep."
        let input = try app.appear(AccessibilityID.chatInput)
        mark("typing")
        input.tap()
        input.typeText(reply)
        try app.appear(AccessibilityID.chatSend).tap()
        let done = try confirmation("Done", in: app)
        mark("refused")
        hold(Self.read)
        hold(Self.glance)
        done.tap()
        XCTAssertFalse(app.staticTexts[reply].exists, "the room posted the flagged reply")
    }

    /// The element with `identifier`, with the filter hiding it or not: a hidden message or photo says so in its value.
    private func hiding(_ identifier: String, in app: XCUIApplication, hidden: Bool) -> XCUIElement {
        let format = hidden ? "identifier == %@ AND value CONTAINS 'hidden'" : "identifier == %@ AND NOT (value CONTAINS 'hidden')"
        return app.descendants(matching: .any).matching(NSPredicate(format: format, identifier)).firstMatch
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
