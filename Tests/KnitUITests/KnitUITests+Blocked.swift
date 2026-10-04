// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Blocking

// The blocking walks (ADR 2026-10.5wgg), apart from the rest only to keep the class under SwiftLint's body and file
// lengths.
extension KnitUITests {
    /// Settings' blocked people, audited; the person blocked in the demo, whose profile says so, audited; Unblock, which
    /// acts at once; and Block, whose confirmation is audited and taken.
    func walkBlocked() throws {
        let app = launch()
        try app.appear(AccessibilityID.chatListSettings).tap()
        try app.reveal(AccessibilityID.settingsBlocked).tap()
        try app.appear(AccessibilityID.blockedScreen)
        audit(app, screen: AccessibilityID.blockedScreen)
        try app.appear(prefix: AccessibilityID.blockedUnblock(""), "someone's Unblock")

        try app.reveal(app.matching(prefix: AccessibilityID.blockedRow("")), "someone blocked").tap()
        try app.appear(AccessibilityID.profileDetailsBlocked)
        audit(app, screen: "a blocked profile")
        try app.reveal(AccessibilityID.profileDetailsBlock).tap()
        XCTAssert(
            app.element(AccessibilityID.profileDetailsBlocked).waitForNonExistence(timeout: Walking.appears),
            "the badge stays after Unblock")

        try app.reveal(AccessibilityID.profileDetailsBlock).tap()
        let confirm = try confirmation(in: app)
        audit(app, screen: "the block confirmation")
        confirm.tap()
        try app.appear(AccessibilityID.profileDetailsBlocked)
        app.terminate()
    }

    /// A stranger's request opened: Block under Accept asks first, the thread then shows Unblock in the composer's place,
    /// audited, and Unblock brings the request back.
    func walkRequestBlock() throws {
        let app = launch()
        try app.reveal(AccessibilityID.chatListRequests).tap()
        try app.appear(prefix: "request_row_", "a request").tap()
        try app.reveal(AccessibilityID.chatRequestBlock).tap()
        try confirmation(in: app).tap()
        try app.appear(AccessibilityID.chatUnblock)
        audit(app, screen: "a blocked thread")
        try app.appear(AccessibilityID.chatUnblock).tap()
        try app.appear(AccessibilityID.chatRequestBlock)
        app.terminate()
    }

    /// The confirmation's Block, once it has stopped moving. Its buttons carry no identifier, which tells it from the
    /// Block that opened it.
    private func confirmation(in app: XCUIApplication) throws -> XCUIElement {
        let block = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", "Block", "")).firstMatch
        settle(try block.appear("the block confirmation"))
        return block
    }
}

extension XCUIApplication {
    /// The first element whose identifier starts with `prefix`.
    func matching(prefix: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    /// The first element whose identifier starts with `prefix`, once it appears.
    @discardableResult
    func appear(prefix: String, _ what: String) throws -> XCUIElement {
        try matching(prefix: prefix).appear(what)
    }
}

// swiftlint:enable prefer_nimble
