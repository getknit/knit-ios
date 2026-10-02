import XCTest

/// Knit's camera permission on the iPhone, live (ADR 2026-10.65xx): asked only once a profile's Scan their code is
/// tapped, refused, and then given. The scanner's state comes from its identifier (``AccessibilityID/ScanState``),
/// never its words. It needs a direct thread with someone whose key has pinned, which a lab phone gives it.
///
/// The scanner needs no radio, so unlike the other tests this one never calls ``Phone/restore()``: it leaves Bluetooth
/// and the mesh as it found them, which lets it run while a lab phone is busy with something else. What it puts back
/// is the camera, unasked, as a fresh install has it.
@MainActor
final class CameraTests: XCTestCase {
    func testScanAsksForTheCameraOnlyWhenTapped() throws {
        let knit = LiveKnit()
        let system = SystemApps()
        let app = knit.app
        // Resetting the permission ends Knit's process, so Knit opens again after it.
        defer {
            app.resetAuthorizationStatus(for: .camera)
            knit.launch()
        }

        app.resetAuthorizationStatus(for: .camera)
        knit.launch()
        try openScanner(app, system: system)
        try system.answerCameraPrompt(allow: false)
        try app.appear(AccessibilityID.scanState(.notAllowed))
        try closeScanner(app)
        try app.reveal(AccessibilityID.profileDetailsScan).tap()
        try app.appear(AccessibilityID.scanState(.notAllowed))
        try closeScanner(app)

        app.resetAuthorizationStatus(for: .camera)
        knit.launch()
        try openScanner(app, system: system)
        try system.answerCameraPrompt(allow: true)
        try app.appear(AccessibilityID.scanState(.scanning))
        try closeScanner(app)
    }

    /// Opens the first direct thread's profile, keeps a picture of the code it draws, and taps Scan their code,
    /// checking that nothing asked first.
    private func openScanner(_ app: XCUIApplication, system: SystemApps) throws {
        let direct = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier != %@ AND NOT identifier BEGINSWITH %@",
                "contact_",
                AccessibilityID.chatRow("nearby"),
                AccessibilityID.chatRow("g-")
            )
        )
        guard direct.firstMatch.waitForExistence(timeout: Walking.appears) else {
            throw XCTSkip("no direct thread on this phone: chat with a lab phone first")
        }
        try app.reveal(direct.firstMatch, "a direct thread").tap()
        try app.appear(AccessibilityID.chatProfile).tap()
        try app.appear(AccessibilityID.profileDetailsScreen)
        // Scan their code sits under the code, so revealing it brings the whole code on screen.
        guard (try? app.reveal(AccessibilityID.profileDetailsScan)) != nil else {
            throw XCTSkip("the first direct thread's key has not pinned, so its profile has nothing to scan")
        }
        let code = app.element(AccessibilityID.profileDetailsCode)
        settle(code)
        let shot = XCTAttachment(screenshot: code.screenshot())
        shot.name = "the profile's code"
        shot.lifetime = .keepAlways
        add(shot)
        try system.noPrompt(before: "Scan their code")
        try app.reveal(AccessibilityID.profileDetailsScan).tap()
        try app.appear(AccessibilityID.scanScreen)
    }

    /// Waits for `element` to stop moving: a form scrolled by a swipe is still moving as the swipe returns.
    private func settle(_ element: XCUIElement) {
        var last = CGRect.null
        for _ in 0..<Self.frameReads {
            let frame = element.frame
            if frame == last {
                return
            }
            last = frame
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the next frame")], timeout: Self.frameInterval)
        }
    }

    /// How often, and how many times, a moving element's frame is read until it holds still.
    private static let frameInterval: TimeInterval = 0.25
    private static let frameReads = 20

    private func closeScanner(_ app: XCUIApplication) throws {
        app.buttons["Cancel"].tap()
        guard app.element(AccessibilityID.scanScreen).waitForNonExistence(timeout: Walking.appears) else {
            throw Mismatch(what: "the scanner", expected: "closed", found: "still up")
        }
    }
}
