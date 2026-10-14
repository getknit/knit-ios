// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Mentioning

// The mention walk (ADR 2026-10.nbhj), apart from the rest only to keep the class under SwiftLint's body and file lengths.
// The edge-cases scene seeds the other Sam's room post mentioning Sam, and ours in the group mentioning Priya, so every
// walk of the room and the group audits a lit name too.
extension KnitUITests {
    /// An "@" in the composer offers the people to mention, a pick puts their name in the field as one chip, which
    /// backspace takes whole, and Send carries it.
    func testAnAtOffersPeopleAndAPickedNameEditsWhole() throws {
        try walkMentions()
    }

    /// The room's walk: "@pri" offers Priya, audited; her pick, audited as a chip; two backspaces, the space and then the
    /// whole name; then a pick sent. `arguments` go to the launch.
    func walkMentions(_ arguments: String...) throws {
        let app = launch(arguments)
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        try app.appear(AccessibilityID.chatThread)
        try app.reveal(AccessibilityID.chatMessage("room-2"))
        let input = try app.appear(AccessibilityID.chatInput)
        input.tap()
        input.typeText("@pri")
        let picker = try app.element(AccessibilityID.chatMentions).appear("the people to mention")
        settle(picker)
        audit(app, screen: "the composer offering people to mention")
        try app.appear(prefix: AccessibilityID.chatMention(""), "Priya's row").tap()
        XCTAssert(picker.waitForNonExistence(timeout: Walking.appears), "a pick left the picker open")
        XCTAssertEqual(input.value as? String, "@Priya ", "the pick wrote something else")
        audit(app, screen: "the composer holding a mention")
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(input.value as? String, "@Priya", "the first backspace took more than the space")
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual((input.value as? String) ?? "", "", "a backspace left part of the name")
        input.typeText("@pri")
        try app.appear(prefix: AccessibilityID.chatMention(""), "Priya's row, again").tap()
        input.typeText("see you at 6")
        try app.appear(AccessibilityID.chatSend).tap()
        let sent = try app.staticTexts["@Priya see you at 6"].appear("our post")
        wait(for: sent, until: "isHittable == true")
        app.terminate()
    }
}

// swiftlint:enable prefer_nimble
