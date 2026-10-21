// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Sharing to Knit

// The share walks, apart from the rest only to keep the class under SwiftLint's body and file lengths. The system's share
// sheet runs outside Knit, so `-demoShare` leaves words in the inbox as the sheet would, and the walks watch the app
// drain them (ADR 2026-10.z7a8).
extension KnitUITests {
    private static let sharedWords = "Shared from another app"

    func testWordsTheShareSheetLeftArePostedInTheRoom() throws {
        let app = launch("-demoShare", Self.sharedWords)
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        try app.appear(AccessibilityID.chatThread)
        try app.staticTexts[Self.sharedWords].appear("the shared words, posted")
        app.terminate()
    }

    /// Under `-demoSensitive` the room refuses every message, so the drain holds the share, and the room's composer takes
    /// it back with the refusal the composer itself shows.
    func testAShareTheRoomRefusedWaitsInItsComposer() throws {
        let app = launch("-demoShare", Self.sharedWords, "-demoSensitive")
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        try app.alerts.firstMatch.appear("the room's refusal of the shared words")
        app.alerts.buttons["Done"].tap()
        let input = try app.appear(AccessibilityID.chatInput)
        XCTAssertEqual(input.value as? String, Self.sharedWords, "the held share is not in the composer")
        XCTAssertFalse(app.staticTexts[Self.sharedWords].exists, "the refused share was posted")
        audit(app, screen: AccessibilityID.chatThread)
        app.terminate()
    }
}
// swiftlint:enable prefer_nimble
