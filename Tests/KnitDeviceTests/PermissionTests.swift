import XCTest

/// Knit's Bluetooth permission on the iPhone, live: asked through the system's own prompt, refused, and given back.
@MainActor
final class PermissionTests: XCTestCase {
    /// MVP item 10: a refusal has its own line, whose button opens Knit's page in the Settings app, and allowing
    /// Bluetooth there brings the mesh back once Knit launches again, since iOS ends Knit's process at the change.
    func testRefusedThenAllowedFromTheStatusLine() throws {
        let phone = Phone()
        try phone.restore()
        defer { try? phone.restore() }
        let knit = phone.knit

        knit.app.resetAuthorizationStatus(for: .bluetooth)
        knit.launch()
        try phone.system.answerBluetoothPrompt(allow: false)
        try knit.status(in: [.notAllowed])

        try knit.app.appear(AccessibilityID.chatListStatusSettings).tap()
        try phone.system.setKnitBluetooth(on: true)
        knit.launch()
        try knit.status(in: LiveKnit.running)
    }

    /// MVP item 1: onboarding's Allow asks through the system's prompt, and finishing starts the mesh. Finishing
    /// publishes whatever the name page holds (ADR 2026-09.tkww), so the run types the profile's own name back.
    func testOnboardingAsksForBluetooth() throws {
        let phone = Phone()
        try phone.restore()
        defer { try? phone.restore() }
        let knit = phone.knit
        let app = knit.app
        let name = try knit.profileName()

        // With the mesh running, the prompt came before onboarding asked (2026-09-29), most likely from a background
        // relaunch iOS made for the mesh's links as the reset ended Knit, which remembered onboarding and started the
        // radio. Stopped, the radio leaves iOS nothing to relaunch Knit for, as on a first install.
        try knit.toggleMeshInSettings()
        try knit.status(in: [.stopped])
        knit.app.resetAuthorizationStatus(for: .bluetooth)
        // UserDefaults reads the argument domain first, so this launch alone forgets that onboarding is done.
        knit.launch("-hasOnboarded", "NO")
        try app.appear(AccessibilityID.onboardingWelcome)
        try phone.system.noPrompt(before: "onboarding's Allow")
        try app.reveal(AccessibilityID.onboardingNext).tap()
        try app.reveal(AccessibilityID.onboardingAgree).tap()
        let field = try app.appear(AccessibilityID.onboardingName)
        if !name.isEmpty {
            field.tap()
            field.typeText(name)
        }
        try app.reveal(AccessibilityID.onboardingNext).tap()

        try app.appear(AccessibilityID.onboardingPermissions)
        try phone.system.noPrompt(before: "onboarding's Allow")
        try app.reveal(AccessibilityID.onboardingAllowBluetooth).tap()
        try phone.system.answerBluetoothPrompt(allow: true)
        guard app.element(AccessibilityID.onboardingAllowBluetooth).waitForNonExistence(timeout: Walking.appears) else {
            throw Mismatch(what: "onboarding's Bluetooth row", expected: "allowed", found: "still asking")
        }
        try app.reveal(AccessibilityID.onboardingStart).tap()
        try knit.status(in: LiveKnit.running)
    }
}
