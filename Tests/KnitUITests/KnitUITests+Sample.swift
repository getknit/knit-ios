// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: The sample chats

// The sample chats (ADR 2026-11.pydf), apart from the rest only to keep the class under SwiftLint's body and file lengths.
extension KnitUITests {
    /// What App Review does on one device: into the sample from the first-run card; messages from other people; a post of
    /// ours answered; and Leave, back where it started.
    func testTheSampleChatsOpenFromTheFirstRunCardAndAnswer() throws {
        try walkSampleChats()
    }

    /// Everyone agrees to the terms before using Knit (ADR 2026-10.cgm3), and App Review checks it: no page before them
    /// offers the sample, and it waits on the chat list behind them, whatever the user says to Bluetooth.
    func testTheSampleChatsComeAfterTheTerms() throws {
        let app = launch("-demoOnboarding", "-demoScene", "fresh")
        let sample = app.buttons["Try sample chats"]
        try app.appear(AccessibilityID.onboardingWelcome)
        XCTAssertFalse(sample.exists, "the welcome page skips the terms")
        try app.reveal(AccessibilityID.onboardingNext).tap()
        try app.appear(AccessibilityID.onboardingTerms)
        XCTAssertFalse(sample.exists, "the terms page offers the sample before Agree")
        try app.reveal(AccessibilityID.onboardingAgree).tap()
        try app.reveal(AccessibilityID.onboardingNext).tap()
        try app.reveal(AccessibilityID.onboardingStart).tap()
        try app.reveal(AccessibilityID.chatListTrySample)
        app.terminate()
    }

    /// Settings opens them at any time, the banner stays over every screen, and Settings doesn't offer them inside themselves.
    func testTheSampleChatsOpenFromSettingsAndTheBannerStays() throws {
        let app = launch()
        try app.appear(AccessibilityID.chatListSettings).tap()
        try app.reveal(AccessibilityID.settingsTrySample).tap()
        try app.appear(AccessibilityID.sampleBanner)
        try app.appear(AccessibilityID.chatListSettings).tap()
        try app.appear(AccessibilityID.settingsScreen)
        XCTAssertTrue(app.element(AccessibilityID.sampleBanner).exists, "the banner left Settings")
        XCTAssertFalse(app.element(AccessibilityID.settingsTrySample).exists, "Settings offered the sample inside the sample")
        app.terminate()
    }

    /// The walk the size and appearance runs take too: each sample screen audited with the banner over it.
    func walkSampleChats() throws {
        let app = launch("-demoScene", "fresh")
        try app.reveal(AccessibilityID.chatListTrySample).tap()
        try audit(app, AccessibilityID.sampleBanner)
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()
        try app.appear(AccessibilityID.chatThread)
        // Someone else's posts, and the banner still there over the thread.
        try app.reveal(AccessibilityID.chatMessage("sample-rude"))
        XCTAssertTrue(app.element(AccessibilityID.sampleBanner).exists, "the banner left the thread")
        audit(app, screen: "the sample's room")

        let input = try app.appear(AccessibilityID.chatInput)
        input.tap()
        input.typeText("Hello")
        try app.appear(AccessibilityID.chatSend).tap()
        try app.reveal(AccessibilityID.chatMessage("answer-0"))

        // The banner must leave the bar alone: a reviewer who can't get back out of a thread is stuck in it.
        app.back()
        let settings = try app.appear(AccessibilityID.chatListSettings)
        XCTAssertTrue(settings.isHittable, "the banner covers the navigation bar")
        settings.tap()
        try app.appear(AccessibilityID.settingsScreen)
        app.back()
        try app.reveal(AccessibilityID.sampleLeave).tap()
        try app.reveal(AccessibilityID.chatListTrySample)
        XCTAssertFalse(app.element(AccessibilityID.sampleBanner).exists, "the banner outlived the sample")
        app.terminate()
    }
}

// swiftlint:enable prefer_nimble
