// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Codes

// The verify code's walk, apart from the rest for the same reason as New message's.
extension KnitUITests {
    /// The profile's code, audited, then its scanner in each state the Simulator can show: it has no scanner, and
    /// `-demoCamera` stands in for a refused camera and for one that fails to start. Cancel says nothing.
    func walkScan() throws {
        let cameras: [(arguments: [String], state: AccessibilityID.ScanState)] = [
            ([], .unsupported),
            (["-demoCamera", "denied"], .notAllowed),
            (["-demoCamera", "allowed"], .unavailable),
        ]
        for (index, camera) in cameras.enumerated() {
            let app = launch(camera.arguments)
            try openDirect(in: app)
            try app.appear(AccessibilityID.chatProfile).tap()
            try app.appear(AccessibilityID.profileDetailsScreen)
            // Scan their code sits under the code, so revealing it brings the whole code on screen; revealing the code
            // itself stops once its top is, and the rest reads black below the screen's edge.
            try app.reveal(AccessibilityID.profileDetailsScan)
            if index == 0 {
                // A form scrolled by a swipe is still moving as the swipe returns, and the audit would read it blank.
                let code = app.element(AccessibilityID.profileDetailsCode)
                settle(code)
                let shot = XCTAttachment(screenshot: code.screenshot())
                shot.name = "the profile's code (\(sizeName))"
                shot.lifetime = .keepAlways
                add(shot)
                audit(app, screen: AccessibilityID.profileDetailsCode)
            }
            // Again: the audit resizes the text in place, which leaves the form scrolled away from the button.
            try app.reveal(AccessibilityID.profileDetailsScan).tap()
            settle(try app.appear(AccessibilityID.scanScreen))
            try audit(app, AccessibilityID.scanState(camera.state))
            if camera.state == .notAllowed {
                try app.buttons["Open Settings"].appear("the refusal's way to Settings")
            }
            app.buttons["Cancel"].tap()
            XCTAssert(app.element(AccessibilityID.scanScreen).waitForNonExistence(timeout: Walking.appears), "Cancel left the scanner up")
            XCTAssertFalse(app.alerts.firstMatch.exists, "a scan that read nothing says nothing")
            app.terminate()
        }
    }
}

// swiftlint:enable prefer_nimble
