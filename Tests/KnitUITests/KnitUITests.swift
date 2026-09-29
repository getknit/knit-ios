// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

/// Every MVP screen in the Simulator, each through `performAccessibilityAudit` (MVP item 12), on `-seedDemo`'s seeded
/// stores and a radio that goes nowhere. XcodeGen builds this target from `App/project.yml`, with
/// `AccessibilityID.swift` compiled in beside it, so the identifiers have one source; SwiftPM never sees it.
///
/// Each walk runs at the default text size, and again, all in one test, at the largest accessibility size, where a
/// screenshot of every screen is kept for a person to look over. What the audit may skip, and why, is ``AuditPolicy``.
@MainActor
final class KnitUITests: XCTestCase {
    /// The text size a walk runs at.
    private enum TextSize {
        case standard
        case largest

        var arguments: [String] {
            switch self {
            case .standard:
                []
            case .largest:
                ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
        }
    }

    /// How often, and how many times, a moving element's frame is read until it holds still.
    private static let frameInterval: TimeInterval = 0.25
    private static let frameReads = 20

    private var size = TextSize.standard

    func testOnboardingWalksWelcomeNameAndPermissions() throws {
        try walkOnboarding()
    }

    func testTheChatListAndTheRoomTakeAPost() throws {
        try walkRoom()
    }

    func testADirectThreadLeadsToTheProfileAndItsEncryption() throws {
        try walkDirect()
    }

    func testARequestOpensAndIsAccepted() throws {
        try walkRequests()
    }

    func testSettingsReachEveryPageAndStopTheMesh() throws {
        try walkSettings()
    }

    /// Bluetooth off, not allowed and unsupported each have their own line (MVP item 10).
    func testEachRadioStateHasItsOwnStatusLine() throws {
        try walkRadioStates()
    }

    /// Every walk again at the largest accessibility size: the audit's Dynamic Type check, which the default walks skip,
    /// is this.
    func testEveryScreenAtTheLargestTextSize() throws {
        size = .largest
        try walkOnboarding()
        try walkRoom()
        try walkDirect()
        try walkRequests()
        try walkSettings()
        try walkRadioStates()
    }

    // MARK: Walks

    private func walkOnboarding() throws {
        let app = launch("-demoOnboarding")
        try audit(app, AccessibilityID.onboardingWelcome)
        try app.reveal(AccessibilityID.onboardingNext).tap()

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

    private func walkRoom() throws {
        let app = launch()
        try audit(app, AccessibilityID.chatListStatus)
        try app.reveal(AccessibilityID.chatRow("nearby")).tap()

        try audit(app, AccessibilityID.chatThread)
        let input = try app.appear(AccessibilityID.chatInput)
        input.tap()
        input.typeText("Anyone near the stage?")
        try app.appear(AccessibilityID.chatSend).tap()
        try app.staticTexts["Anyone near the stage?"].appear("the post")
        app.terminate()
    }

    private func walkDirect() throws {
        let app = launch()
        let direct = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "contact_", AccessibilityID.chatRow("nearby"))
        )
        try app.reveal(direct.firstMatch, "a direct thread").tap()
        try audit(app, AccessibilityID.chatThread)

        try app.appear(AccessibilityID.chatVerified).tap()
        settle(try app.buttons["Done"].appear("the encryption sheet"))
        audit(app, screen: "the encryption sheet")
        app.buttons["Done"].tap()

        try app.appear(AccessibilityID.chatProfile).tap()
        try audit(app, AccessibilityID.profileDetailsScreen)
        try app.reveal(AccessibilityID.profileDetailsMessage).tap()
        try app.appear(AccessibilityID.chatThread)
        app.terminate()
    }

    private func walkRequests() throws {
        let app = launch()
        try app.reveal(AccessibilityID.chatListRequests).tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "request_row_")).firstMatch
        try row.appear("a request")
        audit(app, screen: "the requests")

        row.tap()
        try audit(app, AccessibilityID.chatThread)
        app.back()

        let accept = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "request_accept_")).firstMatch
        try app.reveal(accept, "Accept").tap()
        XCTAssert(accept.waitForNonExistence(timeout: Walking.appears), "the request stays after Accept")
        app.terminate()
    }

    private func walkSettings() throws {
        let app = launch()
        try app.appear(AccessibilityID.chatListSettings).tap()
        try audit(app, AccessibilityID.settingsScreen)

        try app.reveal(AccessibilityID.settingsProfileRow).tap()
        try audit(app, AccessibilityID.profileScreen)
        app.back()
        try app.reveal(AccessibilityID.settingsAbout).tap()
        try audit(app, AccessibilityID.aboutScreen)
        app.back()
        try app.reveal(AccessibilityID.settingsDiagnostics).tap()
        try audit(app, AccessibilityID.diagnosticsScreen)
        app.back()

        let mesh = try app.reveal(AccessibilityID.settingsMesh)
        let running = mesh.label
        mesh.tap()
        let turned = app.buttons.matching(NSPredicate(format: "label != %@ AND identifier == %@", running, AccessibilityID.settingsMesh))
        try turned.firstMatch.appear("Start, once stopped")
        app.back()
        try audit(app, AccessibilityID.chatListStatus)
        app.terminate()
    }

    private func walkRadioStates() throws {
        var lines: Set<String> = []
        for state in ["off", "unauthorized", "unsupported"] {
            let app = launch("-demoRadio", state)
            try audit(app, AccessibilityID.chatListStatus)
            lines.insert(try app.element(AccessibilityID.chatListStatus).staticTexts.firstMatch.appear(state).label)
            app.terminate()
        }
        XCTAssertEqual(lines.count, 3, "\(lines)")
    }

    // MARK: Helpers

    private func launch(_ arguments: String...) -> XCUIApplication {
        // An audit finding fails the test and the walk goes on, so one run lists every screen's; a screen that never
        // appears throws ``Missing`` instead.
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo"] + arguments + size.arguments
        app.launch()
        return app
    }

    /// Waits for `element` to stop moving. A sheet audited mid-slide is measured against the dimmed screen behind it;
    /// XCUITest has no event for the end of an animation, so this reads the frame until two reads agree.
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

    /// Waits for the screen that holds `identifier`, then audits everything on it.
    private func audit(_ app: XCUIApplication, _ identifier: String) throws {
        try app.appear(identifier)
        audit(app, screen: identifier)
    }

    /// Audits what is on screen, and fails once with every issue found and the element it is about. The largest-size
    /// walk keeps a screenshot of every screen; a failing one keeps its own at either size.
    private func audit(_ app: XCUIApplication, screen: String) {
        // A thread scrolls to its newest message as it opens, which at the largest sizes outlasts its appearing.
        if let last = app.scrollViews.firstMatch.staticTexts.allElementsBoundByIndex.last {
            settle(last)
        }
        var issues: [String] = []
        var shots: [XCTAttachment] = []
        let label = "\(screen) (\(size))"
        let bars = app.navigationBars.allElementsBoundByIndex.map(\.frame)
        let window = app.windows.firstMatch.frame
        do {
            try app.performAccessibilityAudit(for: .all.subtracting(.dynamicType)) { issue in
                if AuditPolicy.exempt(issue, bars: bars, window: window) {
                    return true
                }
                let element =
                    issue.element.map { "\($0.elementType.rawValue) '\($0.label)' #\($0.identifier) at \($0.frame)" } ?? "the screen"
                issues.append("\(issue.compactDescription): \(element). \(issue.detailedDescription)")
                if let found = issue.element, found.exists {
                    let shot = XCTAttachment(screenshot: found.screenshot())
                    shot.name = "\(label): \(issue.compactDescription), \(found.label)"
                    shot.lifetime = .keepAlways
                    shots.append(shot)
                }
                return true
            }
        } catch {
            issues.append("the audit failed: \(error)")
        }
        shots.forEach(add)
        if !issues.isEmpty || size == .largest {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "\(screen) (\(size))"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssert(issues.isEmpty, "\(screen) (\(size)), \(issues.count) issues:\n" + issues.joined(separator: "\n"))
    }
}

// swiftlint:enable prefer_nimble
