// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: The keyboard

extension KnitUITests {
    /// The composer's keyboard goes on a tap on the thread, stays away once the profile has covered the thread, and never
    /// hides the composer after the encryption sheet.
    func testTheKeyboardGoesOnATapAndNeverHidesTheComposer() throws {
        try walkKeyboard()
    }

    /// A direct thread with the keyboard up. A tap on the thread puts it away. Up again, then the profile opened and closed,
    /// it once came back with the thread laid out as if it had not, the composer under it and nothing on the thread
    /// putting it away.
    func walkKeyboard() throws {
        let app = launch()
        try openDirect(in: app)
        let thread = try app.appear(AccessibilityID.chatThread)
        let input = try app.appear(AccessibilityID.chatInput)
        let keyboard = app.keyboards.firstMatch

        input.tap()
        try keyboard.appear("the keyboard")
        thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssert(keyboard.waitForNonExistence(timeout: Walking.appears), "a tap on the thread left the keyboard up")

        input.tap()
        try keyboard.appear("the keyboard, again")
        try app.appear(AccessibilityID.chatProfile).tap()
        try app.appear(AccessibilityID.profileDetailsScreen)
        app.back()
        settle(input)
        XCTAssertFalse(keyboard.exists, "the keyboard came back with the thread")
        XCTAssert(input.isHittable, "the composer is out of reach")

        // A sheet leaves the thread on screen under it. Whether the keyboard comes back, the composer stays above it.
        input.tap()
        try keyboard.appear("the keyboard, before the encryption sheet")
        try app.appear(AccessibilityID.chatVerified).tap()
        try app.buttons["Done"].appear("the encryption sheet").tap()
        settle(input)
        if keyboard.exists {
            XCTAssertLessThanOrEqual(input.frame.maxY, keyboard.frame.minY, "the keyboard came back over the composer")
        }
        XCTAssert(input.isHittable, "the composer is out of reach after the encryption sheet")
        app.terminate()
    }
}

// swiftlint:enable prefer_nimble
