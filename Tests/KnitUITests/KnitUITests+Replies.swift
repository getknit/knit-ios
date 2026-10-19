// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Replying

// The reply walk (ADR 2026-10.mn29), apart from the rest only to keep the class under SwiftLint's body and file lengths.
// The edge-cases scene seeds Priya's room post quoting ours, and ours in the group quoting hers, so every walk of the
// room and the group audits a quote too.
extension KnitUITests {
    /// Reply from a message's menu holds its quote over the composer, and Cancel reply puts it away; a swipe holds one
    /// too, and Send carries it; a tap on a quote takes the thread to the message it names.
    func testRepliesStartFromTheMenuOrASwipeAndAQuoteLeadsToItsOriginal() throws {
        try walkReplies()
    }

    /// The room's walks: the menu's Reply, the bar audited and cancelled, then a swipe's reply sent. Then the group's: a
    /// tap on our quote of Priya. `arguments` go to the launches.
    func walkReplies(_ arguments: String...) throws {
        try walkMenuReply(arguments)
        try walkSwipeReply(arguments)
    }

    /// The room's first post's menu: Reply, the bar audited, and Cancel reply.
    private func walkMenuReply(_ arguments: [String]) throws {
        let app = launch(arguments)
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        try app.appear(AccessibilityID.chatThread)
        // A long post, so the press lands on its bubble rather than the space beside it.
        let post = try app.reveal(AccessibilityID.chatMessage("room-1"))
        post.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)).press(forDuration: 1)
        settle(try app.element(AccessibilityID.chatMessageReply).appear("Reply in the menu"))
        app.element(AccessibilityID.chatMessageReply).tap()
        let bar = try app.element(AccessibilityID.chatReplyBar).appear("the reply bar")
        settle(bar)
        audit(app, screen: "the composer holding a quote")
        try app.appear(AccessibilityID.chatReplyCancel).tap()
        XCTAssert(bar.waitForNonExistence(timeout: Walking.appears), "Cancel reply left the bar")
        app.terminate()
    }

    /// A swipe on the room's first post, its reply sent, then a tap on our quote of Priya in the group. A launch of its
    /// own, so the keyboard the menu's Reply raised is gone: a tap on the thread puts it away, but at the largest sizes
    /// the thread's middle can hold an author's name, which opens their profile.
    private func walkSwipeReply(_ arguments: [String]) throws {
        let app = launch(arguments)
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        try app.appear(AccessibilityID.chatThread)
        // A long post, so the swipe lands on its bubble rather than the space beside it.
        let shown = try app.reveal(AccessibilityID.chatMessage("room-1"))
        // A drag of a set length, where `swipeRight` goes as far as XCUITest likes.
        let start = shown.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: Self.swipe, dy: 0)))
        let bar = try app.element(AccessibilityID.chatReplyBar).appear("the reply bar, after a swipe")
        let input = try app.appear(AccessibilityID.chatInput)
        input.tap()
        input.typeText("Same here")
        try app.appear(AccessibilityID.chatSend).tap()
        XCTAssert(bar.waitForNonExistence(timeout: Walking.appears), "Send left the bar")
        let sent = try app.staticTexts["Same here"].appear("our reply")
        wait(for: sent, until: "isHittable == true")
        app.back()
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.chatRow("g-")))
        try app.reveal(group.firstMatch, "a group").tap()
        try app.appear(AccessibilityID.chatThread)
        // Our own reply has no name over it, so its quote is the top of its column, at its trailing side.
        let reply = try app.reveal(AccessibilityID.chatMessage("group-2"))
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.15)).tap()
        wait(for: try app.element(AccessibilityID.chatMessage("group-1")).appear("Priya's message"), until: "isHittable == true")
        app.terminate()
    }

    /// How far the walk's swipe drags a bubble, in points: well past where a reply starts.
    private static let swipe: CGFloat = 150
}

// swiftlint:enable prefer_nimble
