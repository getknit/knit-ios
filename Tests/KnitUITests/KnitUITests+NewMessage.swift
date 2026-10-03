// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: New message

// The New message walks, apart from the rest only to keep the class under SwiftLint's body and file lengths.
extension KnitUITests {
    /// New message's sheet, audited; Cancel closes it, and one pick opens that person's DM.
    func walkNewMessage() throws {
        let app = launch()
        try app.appear(AccessibilityID.chatListNewMessage).tap()
        settle(try app.appear(AccessibilityID.newMessageScreen))
        audit(app, screen: AccessibilityID.newMessageScreen)
        app.buttons["Cancel"].tap()
        XCTAssert(app.element(AccessibilityID.newMessageScreen).waitForNonExistence(timeout: Walking.appears), "Cancel left the sheet up")

        try app.appear(AccessibilityID.chatListNewMessage).tap()
        try pick(1, in: app)
        try app.appear(AccessibilityID.newMessageStart).tap()
        try app.appear(AccessibilityID.chatThread)
        try app.appear(AccessibilityID.chatProfile)
        app.terminate()
    }

    /// Two picks in New message start a group, and its thread opens.
    func walkNewGroup() throws {
        let app = launch()
        try app.appear(AccessibilityID.chatListNewMessage).tap()
        try pick(2, in: app)
        try app.appear(AccessibilityID.newMessageStart).tap()
        try app.appear(AccessibilityID.chatThread)
        try app.appear(AccessibilityID.chatGroupInfo)
        app.terminate()
    }

    /// Picks the first `count` people in New message. They sit at the top of the sheet, so nothing swipes: a swipe
    /// down there would close it.
    private func pick(_ count: Int, in app: XCUIApplication) throws {
        let people = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.newMessageContact("")))
        for index in 0..<count {
            try people.element(boundBy: index).appear("person \(index + 1) to pick").tap()
        }
    }
}

// swiftlint:enable prefer_nimble
