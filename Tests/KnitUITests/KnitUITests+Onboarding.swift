import XCTest

// MARK: Onboarding

// The onboarding walk, apart from the rest only to keep the class under SwiftLint's file length.
extension KnitUITests {
    /// Onboarding from the welcome page: each page audited, the terms agreed to (ADR 2026-10.cgm3), a name typed, Bluetooth
    /// allowed, and the chat list reached.
    func walkOnboarding() throws {
        let app = launch("-demoOnboarding")
        try audit(app, AccessibilityID.onboardingWelcome)
        try app.reveal(AccessibilityID.onboardingNext).tap()

        try audit(app, AccessibilityID.onboardingTerms)
        try app.reveal(AccessibilityID.onboardingAgree).tap()

        try audit(app, AccessibilityID.onboardingNamePage)
        let name = try app.appear(AccessibilityID.onboardingName)
        name.tap()
        name.typeText("Robin")
        try app.reveal(AccessibilityID.onboardingNext).tap()

        try audit(app, AccessibilityID.onboardingPermissions)
        try app.reveal(AccessibilityID.onboardingAllowBluetooth).tap()
        try app.reveal(AccessibilityID.onboardingStart).tap()
        try app.appear(AccessibilityID.chatListStatus)
        app.terminate()
    }
}
