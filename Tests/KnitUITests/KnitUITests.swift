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

    /// A screen or control that never appeared, which ends the test.
    private struct Missing: Error, CustomStringConvertible {
        let what: String

        var description: String { "\(what) never appeared" }
    }

    /// How long a screen gets to appear. A cold Simulator takes seconds for the first launch.
    private static let appears: TimeInterval = 20
    /// How many swipes a control lower down a screen gets to come into view.
    private static let swipes = 8
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
        try reveal(app, AccessibilityID.onboardingNext).tap()

        try audit(app, AccessibilityID.onboardingNamePage)
        let name = try appear(app, AccessibilityID.onboardingName)
        name.tap()
        name.typeText("Robin")
        try reveal(app, AccessibilityID.onboardingNext).tap()

        try audit(app, AccessibilityID.onboardingPermissions)
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Bluetooth")).firstMatch.tap()
        try reveal(app, AccessibilityID.onboardingStart).tap()
        try appear(app, AccessibilityID.chatListStatus)
        app.terminate()
    }

    private func walkRoom() throws {
        let app = launch()
        try audit(app, AccessibilityID.chatListStatus)
        try reveal(app, AccessibilityID.chatRow("nearby")).tap()

        try audit(app, AccessibilityID.chatThread)
        let input = try appear(app, AccessibilityID.chatInput)
        input.tap()
        input.typeText("Anyone near the stage?")
        try appear(app, AccessibilityID.chatSend).tap()
        try appear(app.staticTexts["Anyone near the stage?"], "the post")
        app.terminate()
    }

    private func walkDirect() throws {
        let app = launch()
        let direct = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "contact_", AccessibilityID.chatRow("nearby"))
        )
        try reveal(app, direct.firstMatch, "a direct thread").tap()
        try audit(app, AccessibilityID.chatThread)

        try appear(app, AccessibilityID.chatVerified).tap()
        settle(try appear(app.buttons["Done"], "the encryption sheet"))
        audit(app, screen: "the encryption sheet")
        app.buttons["Done"].tap()

        try appear(app, AccessibilityID.chatProfile).tap()
        try audit(app, AccessibilityID.profileDetailsScreen)
        try reveal(app, AccessibilityID.profileDetailsMessage).tap()
        try appear(app, AccessibilityID.chatThread)
        app.terminate()
    }

    private func walkRequests() throws {
        let app = launch()
        try reveal(app, AccessibilityID.chatListRequests).tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "request_row_")).firstMatch
        try appear(row, "a request")
        audit(app, screen: "the requests")

        row.tap()
        try audit(app, AccessibilityID.chatThread)
        back(app)

        let accept = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "request_accept_")).firstMatch
        try reveal(app, accept, "Accept").tap()
        XCTAssert(accept.waitForNonExistence(timeout: Self.appears), "the request stays after Accept")
        app.terminate()
    }

    private func walkSettings() throws {
        let app = launch()
        try appear(app, AccessibilityID.chatListSettings).tap()
        try audit(app, AccessibilityID.settingsScreen)

        try reveal(app, AccessibilityID.settingsProfileRow).tap()
        try audit(app, AccessibilityID.profileScreen)
        back(app)
        try reveal(app, AccessibilityID.settingsAbout).tap()
        try audit(app, AccessibilityID.aboutScreen)
        back(app)
        try reveal(app, AccessibilityID.settingsDiagnostics).tap()
        try audit(app, AccessibilityID.diagnosticsScreen)
        back(app)

        let mesh = try reveal(app, AccessibilityID.settingsMesh)
        let running = mesh.label
        mesh.tap()
        let turned = app.buttons.matching(NSPredicate(format: "label != %@ AND identifier == %@", running, AccessibilityID.settingsMesh))
        try appear(turned.firstMatch, "Start, once stopped")
        back(app)
        try audit(app, AccessibilityID.chatListStatus)
        app.terminate()
    }

    private func walkRadioStates() throws {
        var lines: Set<String> = []
        for state in ["off", "unauthorized", "unsupported"] {
            let app = launch("-demoRadio", state)
            try audit(app, AccessibilityID.chatListStatus)
            lines.insert(try appear(app.descendants(matching: .any)[AccessibilityID.chatListStatus].staticTexts.firstMatch, state).label)
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

    @discardableResult
    private func appear(_ app: XCUIApplication, _ identifier: String) throws -> XCUIElement {
        try appear(app.descendants(matching: .any)[identifier].firstMatch, identifier)
    }

    @discardableResult
    private func appear(_ element: XCUIElement, _ what: String) throws -> XCUIElement {
        guard element.waitForExistence(timeout: Self.appears) else {
            throw Missing(what: what)
        }
        return element
    }

    /// A control that may sit below the fold, as most do at the largest sizes: swiped into view before it is tapped.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ identifier: String) throws -> XCUIElement {
        try reveal(app, app.descendants(matching: .any)[identifier].firstMatch, identifier)
    }

    @discardableResult
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, _ what: String) throws -> XCUIElement {
        try appear(app.windows.firstMatch, "the window")
        // Down the screen first, then back up it: the control may be either side of where the screen was left.
        for _ in 0..<Self.swipes where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        for _ in 0..<Self.swipes where !(element.exists && element.isHittable) {
            app.swipeDown()
        }
        return try appear(element, what)
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
        try appear(app, identifier)
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

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }
}

// swiftlint:enable prefer_nimble
