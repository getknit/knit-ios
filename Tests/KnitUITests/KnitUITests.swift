// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

/// Every MVP screen in the Simulator, each through `performAccessibilityAudit` (MVP item 12), on `-seedDemo`'s seeded
/// stores and a radio that goes nowhere. XcodeGen builds this target from `App/project.yml`, with
/// `AccessibilityID.swift` compiled in beside it, so the identifiers have one source; SwiftPM never sees it.
///
/// Each walk runs at the default text size, and again, all in one test, at the largest accessibility size, and again in
/// dark mode (ADR 2026-10.5waw), where a screenshot of every screen is kept for a person to look over. What the audit may
/// skip, and why, is ``AuditPolicy``.
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
    /// Whether the walk runs in dark mode.
    private var dark = false

    func testOnboardingWalksWelcomeTermsNameAndPermissions() throws {
        try walkOnboarding()
    }

    func testTheChatListAndTheRoomTakeAPost() throws {
        try walkRoom()
    }

    /// The radio's boundary waits behind the status line's info button, which opens it in a sheet.
    func testTheStatusLineShowsTheBoundaryOnRequest() throws {
        try walkBoundary()
    }

    func testADirectThreadLeadsToTheProfileAndItsEncryption() throws {
        try walkDirect()
    }

    func testARequestOpensAndIsAccepted() throws {
        try walkRequests()
    }

    func testAGroupThreadLeadsToItsInfoAndItsEncryption() throws {
        try walkGroup()
    }

    /// The profile's own code and its scanner, in every state the Simulator can show (ADR 2026-10.65xx).
    func testAProfileShowsItsCodeAndScansInEveryState() throws {
        try walkScan()
    }

    /// Our photo in the profile, the cropper, and someone's photo full screen, on the scene whose people wear photos.
    func testTheProfilePhotoCropsAndAPeersPhotoOpensFullScreen() throws {
        try walkPhotos()
    }

    /// A photo in the room opens full screen, and one picked with Add photo is held and sent (ADR 2026-10.6cas).
    func testAPhotoInAChatOpensFullScreenAndOneIsSent() throws {
        try walkChatPhotos()
    }

    func testNewMessageOpensADirectThreadForOnePerson() throws {
        try walkNewMessage()
    }

    func testNewMessageStartsAGroupForTwo() throws {
        try walkNewGroup()
    }

    /// A notification tapped while Knit is in the background opens its thread.
    func testATappedNotificationOpensItsThread() throws {
        try walkNotification()
    }

    func testSettingsReachEveryPageAndStopTheMesh() throws {
        try walkSettings()
    }

    /// Someone else's explicit photo hides behind a tap and their face behind their initial, an explicit pick is refused in
    /// Nearby and for our profile and taken in a DM, and Content filtering off shows everything (ADR 2026-10.rpmq, ADR
    /// 2026-10.spcy).
    func testTheContentFilterHidesAsksAndTurnsOff() throws {
        try walkContentFilter()
    }

    /// Blocked people lead to a profile whose Unblock acts at once and whose Block asks first (ADR 2026-10.5wgg).
    func testTheBlockedPeopleLeadToAProfileThatUnblocksAndBlocksAgain() throws {
        try walkBlocked()
    }

    /// A stranger's thread offers Block under Accept, which asks first; Unblock then brings the request back.
    func testARequestsBlockAsksFirstAndUnblockBringsItBack() throws {
        try walkRequestBlock()
    }

    /// Bluetooth off, not allowed and unsupported each have their own line (MVP item 10).
    func testEachRadioStateHasItsOwnStatusLine() throws {
        try walkRadioStates()
    }

    /// Every walk again at the largest accessibility size: the audit's Dynamic Type check, which the default walks skip,
    /// is this.
    func testEveryScreenAtTheLargestTextSize() throws {
        size = .largest
        try walkEveryScreen()
    }

    /// Every walk again in dark mode, at the default size: `Palette`'s dark values, which `SwatchContrastTests` measures on
    /// paper, measured on screen.
    func testEveryScreenInDarkMode() throws {
        dark = true
        try walkEveryScreen()
    }

    // MARK: Walks

    /// Every walk but the notification's, whose banner is the system's.
    private func walkEveryScreen() throws {
        try walkOnboarding()
        try walkRoom()
        try walkBoundary()
        try walkDirect()
        try walkRequests()
        try walkGroup()
        try walkNewMessage()
        try walkNewGroup()
        try walkScan()
        try walkPhotos()
        try walkThreadPhotosAndScrolling()
        try walkSettings()
        try walkContentFilter()
        try walkBlocked()
        try walkRequestBlock()
        try walkMessageMenus()
        try walkRadioStates()
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

    private func walkBoundary() throws {
        let app = launch()
        try app.reveal(AccessibilityID.chatListStatusAbout).tap()
        try audit(app, AccessibilityID.chatListBoundary)
        app.terminate()
    }

    private func walkDirect() throws {
        let app = launch()
        try openDirect(in: app)
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

    private func walkGroup() throws {
        let app = launch()
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.chatRow("g-")))
        try app.reveal(group.firstMatch, "a group").tap()
        try audit(app, AccessibilityID.chatThread)

        try app.appear(AccessibilityID.chatEncryption).tap()
        settle(try app.buttons["Done"].appear("the encryption sheet"))
        audit(app, screen: "the group's encryption sheet")
        app.buttons["Done"].tap()

        try app.appear(AccessibilityID.chatGroupInfo).tap()
        try audit(app, AccessibilityID.groupInfoScreen)
        try app.reveal(AccessibilityID.groupRename).tap()
        settle(try app.textFields.firstMatch.appear("the rename sheet"))
        audit(app, screen: "the rename sheet")
        app.buttons["Cancel"].tap()
        // Leave sits below the fold at the largest sizes, where the list has not built it yet.
        try app.reveal(AccessibilityID.groupLeave)
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
}

// MARK: Launching and auditing

// Out of the class, where SwiftLint asks every member to be private, so the walks in other files can launch and audit.
extension KnitUITests {
    /// Opens the first direct thread in the chat list: Sam's, whose key the demo pinned.
    func openDirect(in app: XCUIApplication) throws {
        let direct = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier != %@ AND NOT identifier BEGINSWITH %@",
                "contact_",
                AccessibilityID.chatRow("nearby"),
                AccessibilityID.chatRow("g-")
            )
        )
        try app.reveal(direct.firstMatch, "a direct thread").tap()
    }

    func launch(_ arguments: String...) -> XCUIApplication {
        launch(arguments)
    }

    func launch(_ arguments: [String]) -> XCUIApplication {
        // An audit finding fails the test and the walk goes on, so one run lists every screen's; a screen that never
        // appears throws ``Missing`` instead.
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo"] + arguments + size.arguments
        // Set on every launch, so a dark walk that stopped short leaves no later walk dark.
        XCUIDevice.shared.appearance = dark ? .dark : .light
        app.launch()
        return app
    }

    /// Waits for `element` to stop moving. A sheet audited mid-slide is measured against the dimmed screen behind it;
    /// XCUITest has no event for the end of an animation, so this reads the frame until two reads agree.
    func settle(_ element: XCUIElement) {
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
    func audit(_ app: XCUIApplication, _ identifier: String) throws {
        try app.appear(identifier)
        audit(app, screen: identifier)
    }

    /// Audits what is on screen, and fails once with every issue found and the element it is about. The largest-size
    /// walk keeps a screenshot of every screen; a failing one keeps its own at either size.
    func audit(_ app: XCUIApplication, screen: String) {
        // A thread scrolls to its newest message as it opens, which at the largest sizes outlasts its appearing.
        if let last = app.scrollViews.firstMatch.staticTexts.allElementsBoundByIndex.last {
            settle(last)
        }
        var issues: [String] = []
        var shots: [XCTAttachment] = []
        let label = "\(screen) (\(size)\(dark ? ", dark" : ""))"
        let bars = app.navigationBars.allElementsBoundByIndex.map(\.frame)
        let window = app.windows.firstMatch.frame
        do {
            try app.performAccessibilityAudit(for: .all.subtracting(.dynamicType)) { issue in
                if AuditPolicy.exempt(issue, in: app, bars: bars, window: window) {
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
        if !issues.isEmpty || size == .largest || dark {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = label
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssert(issues.isEmpty, "\(label), \(issues.count) issues:\n" + issues.joined(separator: "\n"))
    }
}

// MARK: Codes

// The verify code's walk, apart from the rest for the same reason as New message's.
extension KnitUITests {
    /// The profile's code, audited, then its scanner in each state the Simulator can show: it has no scanner, and
    /// `-demoCamera` stands in for a refused camera and for one that fails to start. Cancel says nothing.
    private func walkScan() throws {
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
                shot.name = "the profile's code (\(size))"
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
