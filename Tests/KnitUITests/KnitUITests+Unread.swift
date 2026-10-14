// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Unread

// Unread counts on the chat list (ADR 2026-10.frmj), apart from the rest only to keep the class under SwiftLint's body and
// file lengths. The edge-cases scene leaves Priya's reply in the room unread, so every walk that audits the chat list
// audits its count too; the long room's count in the hundreds is the widest one the list draws.
extension KnitUITests {
    /// The room's row says, in words, how many of its messages nobody has read; opening the room reads them.
    func testAnUnreadRowSaysHowManyAndOpeningItClearsIt() throws {
        try walkUnread()
    }

    /// The edge cases' room, its count read and gone once the room has been open; then the long room's, audited.
    /// `arguments` go to each launch.
    func walkUnread(_ arguments: String...) throws {
        let app = launch(arguments)
        let room = try app.reveal(AccessibilityID.chatRow("nearby"))
        XCTAssert(room.label.contains("1 unread message"), "the room's row reads \(room.label)")
        room.tap()
        try app.appear(AccessibilityID.chatThread)
        app.back()
        wait(for: try app.reveal(AccessibilityID.chatRow("nearby")), until: "NOT (label CONTAINS 'unread')")
        app.terminate()

        let long = launch(["-demoScene", "long-room"] + arguments)
        let busy = try long.reveal(AccessibilityID.chatRow("nearby"))
        XCTAssert(busy.label.contains("unread messages"), "the long room's row reads \(busy.label)")
        audit(long, screen: "the chat list with a count in the hundreds")
        long.terminate()
    }
}

// swiftlint:enable prefer_nimble
