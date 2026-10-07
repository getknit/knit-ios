// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Reacting

// The reaction walk (ADR 2026-10.ehe6), apart from the rest only to keep the class under SwiftLint's body and file
// lengths. The edge-cases scene seeds chips on our own room post, so every walk of the room audits them too.
extension KnitUITests {
    /// A message's menu opens on the six; 👍 chosen there shows its chip, a tap on the chip takes it back, and so does
    /// choosing it in the menu again.
    func testAMessagesMenuReactsAndItsChipOrTheMenuTakesItBack() throws {
        try walkReactions()
    }

    /// The menus a message and a chat open, deleting, reporting and reacting, for the walks every screen takes again.
    func walkMessageMenus() throws {
        try walkDeletes()
        try walkReports()
        try walkReactions()
    }

    /// A room post's menu, by a long press on its bubble: the six above Copy and Delete, and 👍 chosen, which closes the
    /// menu; its chip shows, and the post's value says so, since VoiceOver reads a bubble and its chips as one. A tap on
    /// the chip takes it back. Then 👍 again from the menu, and choosing it there once more takes it back too. Last, the
    /// menu is audited. `arguments` go to the launch.
    private func walkReactions(_ arguments: String...) throws {
        let app = launch(arguments)
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        try app.appear(AccessibilityID.chatThread)
        // A long post, so the press lands on its bubble rather than the space beside it.
        let post = try app.reveal(AccessibilityID.chatMessage("room-1"))
        let chip = app.element(AccessibilityID.chatReaction("room-1", Self.thumbs))
        try choose(Self.thumbs, on: post, in: app, step: "first")
        try chip.appear("the 👍 chip")
        wait(for: post, until: "value CONTAINS 'Reactions'")
        settle(chip)
        chip.tap()
        XCTAssert(chip.waitForNonExistence(timeout: Walking.appears), "a tap on our chip left it")
        wait(for: post, until: "NOT (value CONTAINS 'Reactions')")
        try choose(Self.thumbs, on: post, in: app, step: "second")
        try chip.appear("the 👍 chip, again")
        try choose(Self.thumbs, on: post, in: app, step: "third")
        XCTAssert(chip.waitForNonExistence(timeout: Walking.appears), "choosing 👍 again left its chip")
        // Audited last: at the largest sizes the menu scrolls, and the audit leaves its row of six out of reach.
        post.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)).press(forDuration: 1)
        settle(try app.element(AccessibilityID.chatMessageDelete).appear("the menu, to audit"))
        audit(app, screen: "a message's menu, with the six")
        app.terminate()
    }

    /// Opens `post`'s menu with a long press and chooses `emoji` in its palette, which carries no identifiers; the menu
    /// closes. `step` names the press in a failure.
    private func choose(_ emoji: String, on post: XCUIElement, in app: XCUIApplication, step: String) throws {
        post.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)).press(forDuration: 1)
        settle(try app.element(AccessibilityID.chatMessageDelete).appear("the menu, \(step)"))
        let button = try app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == ''", emoji)).firstMatch.appear(
            "\(emoji) in the menu, \(step)")
        button.tap()
        // The menu fades out over the thread, and takes any tap that lands before it has gone.
        XCTAssert(app.element(AccessibilityID.chatMessageDelete).waitForNonExistence(timeout: Walking.appears), "the menu stayed")
    }

    private static let thumbs = "\u{1F44D}"
}

// swiftlint:enable prefer_nimble
