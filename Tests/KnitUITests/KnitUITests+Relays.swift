// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Internet relays

// The relay walk (ADR 2026-11.adrq, P6), apart from the rest only to keep the class under SwiftLint's body and file
// lengths. It runs once, at the default size: the UI job sits near its hour limit (ADR 2026-11.aykf).
extension KnitUITests {
    /// The invite for `wss://lab.relay.example/spool/v1?k=walk`, Android's compact form (`RelayInvite.mint`, which
    /// `RelayInviteSheetTests` holds to this text): a private relay no socket ever reaches, since `-demoRelays` opens none.
    private static let invite = "knit://r/omF2AWF1eCd3c3M6Ly9sYWIucmVsYXkuZXhhbXBsZS9zcG9vbC92MT9rPXdhbGs"

    /// Under `-demoRelays`, whose stand-in opens no socket: the switch turns on through its consent sheet, audited; a pasted
    /// invite opens its own sheet, audited, and adds the relay; then Stop using and Remove, each by the relay's handle.
    func testTheRelaySwitchAndAPastedInviteGoThroughConsent() throws {
        let app = launch("-demoRelays")
        try app.appear(AccessibilityID.chatListSettings).tap()
        // A toggle's element spans its row, and a tap on the middle lands on its words: the switch sits at the end.
        try app.reveal(AccessibilityID.settingsInternetRelays).coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        settle(try app.appear(AccessibilityID.relaysConsent))
        audit(app, screen: AccessibilityID.relaysConsent)
        try app.appear(AccessibilityID.relaysConsentAccept).tap()
        let on = NSPredicate(format: "identifier == %@ AND value == '1'", AccessibilityID.settingsInternetRelays)
        try app.reveal(app.descendants(matching: .any).matching(on).firstMatch, "Internet relays, on")
        try app.reveal(AccessibilityID.relayRow(1))

        // The system's Paste reads the pasteboard on a tap, with no prompt to allow it.
        UIPasteboard.general.string = Self.invite
        try app.reveal(AccessibilityID.relaysPaste).tap()
        settle(try app.appear(AccessibilityID.relaysConsent))
        audit(app, screen: "\(AccessibilityID.relaysConsent) for an invite")
        try app.appear(AccessibilityID.relaysConsentAccept).tap()
        try app.reveal(AccessibilityID.relayRow(2))
        let named = NSPredicate(format: "label BEGINSWITH %@", "lab.relay.example, Not run by Knit, Access key in link")
        XCTAssertTrue(app.descendants(matching: .any).matching(named).firstMatch.exists, "the row names the host the sheet named")

        try app.reveal(AccessibilityID.relayPark(2)).tap()
        try app.reveal(AccessibilityID.relayRemove(2)).tap()
        XCTAssertFalse(app.element(AccessibilityID.relayRow(2)).exists, "removed")
        audit(app, screen: AccessibilityID.settingsScreen)
        app.terminate()
    }
}

// swiftlint:enable prefer_nimble
