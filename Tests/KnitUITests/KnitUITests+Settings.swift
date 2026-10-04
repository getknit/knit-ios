// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Settings and the content filter

// Apart from the rest only to keep the class under SwiftLint's body and file lengths.
extension KnitUITests {
    /// How long a photo shown with the filter off is watched, in seconds, for hiding when it must not.
    private static let quiet: TimeInterval = 3
    /// The marketing scene's post by the fire, Dani's, which carries a photo.
    private static let firePost = "room-5"
    /// The room's newest post, Priya's, which carries words alone.
    private static let newestPost = "room-9"
    /// What the walk tries to post, which the demo's classifier finds abusive like everything else.
    private static let refusedWords = "Heading up now"

    /// Settings: the profile, About and Diagnostics, each audited, and Stop, which leaves the chat list saying so.
    func walkSettings() throws {
        let app = launch()
        try app.appear(AccessibilityID.chatListSettings).tap()
        try audit(app, AccessibilityID.settingsScreen)

        try app.reveal(AccessibilityID.settingsProfileRow).tap()
        try audit(app, AccessibilityID.profileScreen)
        app.back()
        try app.reveal(AccessibilityID.settingsAbout).tap()
        try audit(app, AccessibilityID.aboutScreen)
        app.back()
        try app.reveal(AccessibilityID.settingsDiagnostics).tap()
        try audit(app, AccessibilityID.diagnosticsScreen)
        app.back()

        let mesh = try app.reveal(AccessibilityID.settingsMesh)
        let running = mesh.label
        mesh.tap()
        let turned = app.buttons.matching(NSPredicate(format: "label != %@ AND identifier == %@", running, AccessibilityID.settingsMesh))
        try turned.firstMatch.appear("Start, once stopped")
        app.back()
        try audit(app, AccessibilityID.chatListStatus)
        app.terminate()
    }

    /// The content filter (ADR 2026-10.rpmq, ADR 2026-10.e4kz) on the marketing scene under `-demoSensitive`, where the
    /// demo's classifiers find every photo explicit and every message abusive, and `-demoPhoto`, under which Add photo
    /// picks a painted picture:
    ///
    /// - the room's post by the fire hides its photo behind a tap, and a tap shows it;
    /// - the room's newest post hides its words behind a tap, and a tap shows them;
    /// - a photo picked for the room is refused, and so are words sent there, which stay in the composer;
    /// - a photo picked for Sam's DM asks before it goes in the composer;
    /// - Sam's face shows his initial, so his profile offers no photo to open;
    /// - Content filtering off shows the post by the fire at once.
    func walkContentFilter() throws {
        let app = launch("-demoScene", "marketing", "-demoPhoto", "-demoSensitive")
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        // A message reads as one element, whose value says when its photo is hidden. The post sits above the newest, and
        // at the largest sizes scrolls in and out of the list's reach, so each step finds it afresh.
        try app.reveal(fire(in: app, hidden: true), "the post by the fire, hidden")
        audit(app, screen: AccessibilityID.chatThread)
        // The tap goes where the photo is: under Dani's name, left of the bubble's middle, which her name's link spans.
        try tapWhenStill(AccessibilityID.chatPhoto(Self.firePost), at: CGVector(dx: 0.3, dy: 0.35), in: app)
        try app.reveal(fire(in: app, hidden: false), "the post by the fire, shown")

        // The words hide too. The tap goes left of the bubble's middle, below Priya's name, on the line that stands in.
        try app.reveal(message(Self.newestPost, in: app, hidden: true), "the newest post, hidden")
        try tapWhenStill(AccessibilityID.chatMessage(Self.newestPost), at: CGVector(dx: 0.2, dy: 0.55), in: app)
        try app.reveal(message(Self.newestPost, in: app, hidden: false), "the newest post, shown")

        try app.appear(AccessibilityID.chatAddPhoto).tap()
        try app.alerts.firstMatch.appear("the room's refusal")
        app.alerts.buttons["Done"].tap()
        XCTAssertFalse(app.element(AccessibilityID.chatStagedPhoto).exists, "the room held an explicit photo")
        let input = try app.appear(AccessibilityID.chatInput)
        input.tap()
        input.typeText(Self.refusedWords)
        try app.appear(AccessibilityID.chatSend).tap()
        try app.alerts.firstMatch.appear("the room's refusal of words")
        app.alerts.buttons["Done"].tap()
        XCTAssertEqual(input.value as? String, Self.refusedWords, "the refused words left the composer")
        XCTAssertFalse(app.staticTexts[Self.refusedWords].exists, "the refused words were posted")
        app.back()

        try openDirect(in: app)
        try app.appear(AccessibilityID.chatAddPhoto).tap()
        try app.alerts.firstMatch.appear("the DM's question")
        app.alerts.buttons["Send anyway"].tap()
        try app.appear(AccessibilityID.chatStagedPhoto)
        try app.appear(AccessibilityID.chatProfile).tap()
        try app.appear(AccessibilityID.profileDetailsScreen)
        XCTAssert(
            app.element(AccessibilityID.profileDetailsPhoto).waitForNonExistence(timeout: Walking.appears),
            "Sam's hidden photo still opens"
        )
        app.back()
        app.back()

        try app.appear(AccessibilityID.chatListSettings).tap()
        try app.reveal(AccessibilityID.settingsContentFiltering)
        audit(app, screen: AccessibilityID.settingsScreen)
        // A toggle's element spans its row, and a tap on the middle lands on its words: the switch sits at the end. The
        // audit may have scrolled the row away at the largest sizes, so it is found afresh.
        try app.reveal(AccessibilityID.settingsContentFiltering).coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let off = NSPredicate(format: "identifier == %@ AND value == '0'", AccessibilityID.settingsContentFiltering)
        try app.reveal(app.descendants(matching: .any).matching(off).firstMatch, "Content filtering, off")
        app.back()
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        // Screening takes a moment, so the photo gets a few seconds to hide, which it must not.
        try app.reveal(fire(in: app, hidden: false), "the post by the fire, filter off")
        let hides = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: fire(in: app, hidden: true))
        hides.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [hides], timeout: Self.quiet), .completed, "the photo hid with the filter off")
        app.terminate()
    }

    /// The room's post by the fire, with its photo hidden or not. A query rather than an element, so asking about a post
    /// out of the list's reach answers that it is not there rather than failing the walk.
    private func fire(in app: XCUIApplication, hidden: Bool) -> XCUIElement {
        hiding(AccessibilityID.chatPhoto(Self.firePost), in: app, hidden: hidden)
    }

    /// A post that carries words alone, with them hidden or not.
    private func message(_ id: String, in app: XCUIApplication, hidden: Bool) -> XCUIElement {
        hiding(AccessibilityID.chatMessage(id), in: app, hidden: hidden)
    }

    /// Taps `identifier` at `offset` within it once the thread holds still. A swipe's glide carries the thread on after
    /// `reveal` finds the element, and a tap on the moving thread lands on whatever slid under it: an author's name, whose
    /// link opens their profile.
    private func tapWhenStill(_ identifier: String, at offset: CGVector, in app: XCUIApplication) throws {
        let element = try app.reveal(identifier)
        settle(element)
        element.coordinate(withNormalizedOffset: offset).tap()
    }

    /// The element `identifier` names, while its value says the filter hides something of it, or while it does not.
    private func hiding(_ identifier: String, in app: XCUIApplication, hidden: Bool) -> XCUIElement {
        let format = hidden ? "identifier == %@ AND value CONTAINS 'hidden'" : "identifier == %@ AND NOT (value CONTAINS 'hidden')"
        return app.descendants(matching: .any).matching(NSPredicate(format: format, identifier)).firstMatch
    }
}

// swiftlint:enable prefer_nimble
