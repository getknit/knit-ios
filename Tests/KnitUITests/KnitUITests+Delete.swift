// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Deleting

// The delete walks (ADR 2026-10.u7cq), apart from the rest only to keep the class under SwiftLint's body and file
// lengths.
extension KnitUITests {
    /// A message's menu deletes it once its confirmation is taken (ADR 2026-10.u7cq).
    func testAMessagesMenuDeletesItAfterAsking() throws {
        try walkDeleteMessage()
    }

    /// A chat's swipe deletes it, the room's clears it, and a request's deletes it, each after asking (ADR 2026-10.u7cq).
    func testASwipeDeletesAChatClearsTheRoomAndDeletesARequest() throws {
        try walkDeleteChat()
    }

    /// Both delete walks, for the walks every screen takes again (``walkMessageMenus()``).
    func walkDeletes() throws {
        try walkDeleteMessage()
        try walkDeleteChat()
    }

    /// A room post's menu, by a long press on its bubble: Copy and Delete, then Delete's confirmation, audited and taken,
    /// and the post gone.
    private func walkDeleteMessage() throws {
        let app = launch()
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        try app.appear(AccessibilityID.chatThread)
        // A long post, so the press lands on its bubble rather than the space beside it.
        let post = try app.reveal(AccessibilityID.chatMessage("room-1"))
        post.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)).press(forDuration: 1)
        try app.appear(AccessibilityID.chatMessageCopy)
        try app.appear(AccessibilityID.chatMessageDelete).tap()
        let delete = try confirmation("Delete", in: app)
        audit(app, screen: "the message's delete confirmation")
        delete.tap()
        XCTAssert(app.element(AccessibilityID.chatMessage("room-1")).waitForNonExistence(timeout: Walking.appears), "the post stayed")
        app.terminate()
    }

    /// The chat list's swipes: a group's Delete, whose confirmation is audited and taken, and its row gone; the room's
    /// Clear, audited, and its row still there; then a request's Delete, and the request gone.
    private func walkDeleteChat() throws {
        let app = launch()
        let group = try app.reveal(app.matching(prefix: AccessibilityID.chatRow("g-")), "a group")
        let row = group.identifier
        group.swipeLeft()
        try app.appear(prefix: AccessibilityID.chatRowDelete("g-"), "the group's Delete").tap()
        let delete = try confirmation("Delete", in: app)
        audit(app, screen: "the chat's delete confirmation")
        delete.tap()
        XCTAssert(app.element(row).waitForNonExistence(timeout: Walking.appears), "the group's row stayed")

        try app.reveal(AccessibilityID.chatRow("nearby")).swipeLeft()
        try app.appear(AccessibilityID.chatRowDelete("nearby")).tap()
        let clear = try confirmation("Clear", in: app)
        audit(app, screen: "the room's clear confirmation")
        clear.tap()
        try app.appear(AccessibilityID.chatRow("nearby"))

        try app.reveal(AccessibilityID.chatListRequests).tap()
        let request = try app.appear(prefix: "request_row_", "a request")
        let asked = request.identifier
        request.swipeLeft()
        try app.appear(prefix: AccessibilityID.requestDelete(""), "the request's Delete").tap()
        try confirmation("Delete", in: app).tap()
        XCTAssert(app.element(asked).waitForNonExistence(timeout: Walking.appears), "the request stayed")
        app.terminate()
    }

    /// The confirmation's `action`, once it has stopped moving. Its buttons carry no identifier, which tells it from the
    /// Delete or Clear that opened it.
    private func confirmation(_ action: String, in app: XCUIApplication) throws -> XCUIElement {
        let button = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", action, "")).firstMatch
        settle(try button.appear("the \(action) confirmation"))
        return button
    }
}

// swiftlint:enable prefer_nimble
