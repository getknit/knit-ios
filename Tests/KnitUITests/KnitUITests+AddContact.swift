// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Add contact

// The Add contact walk, apart from the rest only to keep the class under SwiftLint's body and file lengths.
extension KnitUITests {
    /// Android's `minimalCard` (`ContactCardTest.kt`, knit-next ADR 042): the contact-card identity's link, with no name.
    private static let minimalCard =
        "omRib2R5WGijYXYBYmlkeBo0Y2dxMnBuaGg2cDNqM2Fmd3N1ZTNjaHJwaWJwa1hA5AMJmM_VrRcj"
        + "wWn5VqoLnrhhm1mSvWEsKvQo68efjfBz55lxyREAKXI2MqgLcHv09iwSV2M0bh6HGNbA3MOqOmNz"
        + "aWdYQLL2FdNZ6dxdvl8HfEBnbj8yNsSoGoCPELMEIXuO6kA04Ra6SeNRPkpg1UGmp1ZQgU3qjVOp"
        + "M6JdH3puOvfihQA"

    /// Add contact from New message, audited; then a contact link opened from outside Knit, as a tap in Messages opens
    /// one: its preview, audited, adds the person and opens their profile (ADR 2026-10.tpr5).
    func testAContactLinkOpensAddContactAndAddsThePerson() throws {
        let app = launch()
        try app.appear(AccessibilityID.chatListNewMessage).tap()
        try app.appear(AccessibilityID.newMessageAddContact).tap()
        settle(try app.appear(AccessibilityID.addContactScreen))
        audit(app, screen: AccessibilityID.addContactScreen)
        app.open(try XCTUnwrap(URL(string: "knit://c/" + Self.minimalCard)))
        settle(try app.appear(AccessibilityID.addContactPreview))
        audit(app, screen: AccessibilityID.addContactPreview)
        try app.reveal(AccessibilityID.addContactConfirm).tap()
        try app.appear(AccessibilityID.profileDetailsScreen)
        XCTAssertFalse(app.alerts.firstMatch.exists, "a link that was added says nothing more")
        app.terminate()
    }
}

// swiftlint:enable prefer_nimble
