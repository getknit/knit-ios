// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Typing

// Who is typing, at a thread's foot, apart from the rest only to keep the class under SwiftLint's body and file lengths.
// The edge-cases scene holds Priya and Sam typing in the room, and Jonas, whom his block hides, and Priya in the group, so
// every walk of the room and the group audits the row too, in each size and appearance.
extension KnitUITests {
    /// The room's row names Priya and others, Jonas left out; the group's names Priya alone.
    func testWhoIsTypingShowsAtTheThreadsFoot() throws {
        let app = launch()
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        XCTAssertEqual(try app.reveal(AccessibilityID.chatTyping).label, "Priya and others are typing")
        app.back()
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.chatRow("g-")))
        try app.reveal(group.firstMatch, "a group").tap()
        XCTAssertEqual(try app.reveal(AccessibilityID.chatTyping).label, "Priya is typing")
        app.terminate()
    }
}

// swiftlint:enable prefer_nimble
