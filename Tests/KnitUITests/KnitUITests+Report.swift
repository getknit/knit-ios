// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Reporting

// The report walks (ADR 2026-10.f6kf), apart from the rest only to keep the class under SwiftLint's body and file
// lengths.
extension KnitUITests {
    /// A message's menu reports it once its confirmation is taken, and the post goes (ADR 2026-10.f6kf).
    func testAMessagesMenuReportsItAfterAsking() throws {
        try walkReportMessage()
    }

    /// A profile's Report and Email Knit says where to write when the phone has no way to send email, as the Simulator
    /// has none (ADR 2026-10.f6kf).
    func testAReportsEmailNamesTheAddressWithoutMail() throws {
        try walkReportEmail()
    }

    /// Both report walks, for the walks every screen takes again (``walkMessageMenus()``).
    func walkReports() throws {
        try walkReportMessage()
        try walkReportEmail()
    }

    /// Someone else's room post, by a long press on its bubble: Report, its confirmation audited and taken, and the post
    /// gone with its author's block.
    private func walkReportMessage() throws {
        let app = launch()
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        try app.appear(AccessibilityID.chatThread)
        // A long post, so the press lands on its bubble rather than the space beside it.
        let post = try app.reveal(AccessibilityID.chatMessage("room-1"))
        post.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)).press(forDuration: 1)
        try app.appear(AccessibilityID.chatMessageReport).tap()
        let report = try confirmation("Report", in: app)
        audit(app, screen: "the message's report confirmation")
        report.tap()
        XCTAssert(app.element(AccessibilityID.chatMessage("room-1")).waitForNonExistence(timeout: Walking.appears), "the post stayed")
        app.terminate()
    }

    /// The person blocked in the demo, reported from their profile with Report and Email Knit: with no mail account and
    /// no app for `mailto:`, the alert naming the address shows, and is audited.
    private func walkReportEmail() throws {
        let app = launch()
        try app.appear(AccessibilityID.chatListSettings).tap()
        try app.reveal(AccessibilityID.settingsBlocked).tap()
        try app.reveal(app.matching(prefix: AccessibilityID.blockedRow("")), "someone blocked").tap()
        try app.reveal(AccessibilityID.profileDetailsReport).tap()
        try confirmation("Report", in: app)
        try confirmation("Report and Email Knit", in: app).tap()
        let copy = try confirmation("Copy Address", in: app)
        audit(app, screen: "the report's no-mail alert")
        copy.tap()
        app.terminate()
    }

    /// The alert's `action`, once it has stopped moving. Its buttons carry no identifier, which tells it from the Report
    /// that opened it.
    @discardableResult
    private func confirmation(_ action: String, in app: XCUIApplication) throws -> XCUIElement {
        let button = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", action, "")).firstMatch
        settle(try button.appear("the \(action) button"))
        return button
    }
}

// swiftlint:enable prefer_nimble
