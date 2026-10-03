// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Notifications

// The notification walk, apart from the rest only to keep the class under SwiftLint's body and file lengths.
extension KnitUITests {
    /// Apple's words on iOS 27, which move between versions.
    private enum Words {
        static let allow = "Allow"
    }

    /// How long the system's question whether Knit may notify gets to show. The Simulator asks once, and the answer
    /// stands after that.
    private static let promptWait: TimeInterval = 5

    /// Under `-demoNotification` the demo asks to notify, and posts the room's notification as Knit goes to the
    /// background. Its banner, tapped on the home screen, reaches Knit while it is still in the background, as a tap on
    /// the lock screen does, and opens the room. Knit used to finish that tap off the main thread, which UIKit aborts
    /// on (2026-10-03).
    func walkNotification() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = launch("-demoNotification")
        let prompt = springboard.alerts.firstMatch
        if prompt.waitForExistence(timeout: Self.promptWait) {
            try prompt.buttons[Words.allow].appear("Allow").tap()
        }
        try app.appear(AccessibilityID.chatListStatus)

        XCUIDevice.shared.press(.home)
        // The room's newest post by someone else, which the banner quotes.
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "On my way.")).firstMatch
        try banner.appear("the room's notification").tap()
        XCTAssert(app.wait(for: .runningForeground, timeout: Walking.appears), "Knit never came to the front")
        try app.appear(AccessibilityID.chatThread)
        try app.staticTexts["Is anyone else at the festival without signal?"].appear("the room's first post")
        app.terminate()
    }
}
// swiftlint:enable prefer_nimble
