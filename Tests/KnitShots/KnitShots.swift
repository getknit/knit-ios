import XCTest

/// The store's screenshots: each screen the listing shows, on `-demoScene marketing`, kept as an attachment named
/// `<light|dark>_<shot>` that `scripts/check.sh shots` exports as a PNG of that name. Only the KnitShots scheme runs it, in
/// a Simulator of its own whose status bar and appearance the gate sets: it runs the suite once per appearance and says
/// which in `KNIT_SHOT_MODE`. It checks nothing a walk in `KnitUITests` does not; a screen that never appears throws
/// ``Missing``, which ends that shot.
///
/// The shot names follow knit-next's `screenshots.sh` where the screen is the same one, so a caption can be shared.
@MainActor
final class KnitShots: XCTestCase {
    /// How often, and how many times, a moving element's frame is read until it holds still.
    private static let frameInterval: TimeInterval = 0.25
    private static let frameReads = 20
    /// How long a still screen gets before its shot, for the scroll indicator a thread flashes as it opens to fade.
    private static let still: TimeInterval = 1.5

    /// The appearance the gate set, `light` or `dark`, for the shots' names: `KNIT_SHOT_MODE`, which it passes as
    /// `TEST_RUNNER_KNIT_SHOT_MODE`. The gate sets it with `simctl ui`: in "Knit shots", `XCUIDevice.appearance` changed
    /// what the Simulator reported and nothing it drew (iOS 27.0, 2026-10-07; ADR 2026-10.5u39).
    private static var mode: String {
        ProcessInfo.processInfo.environment["KNIT_SHOT_MODE"] ?? "light"
    }

    func testOnboarding() throws {
        try shoot("onboarding", "-demoOnboarding") { app in
            try app.appear(AccessibilityID.onboardingWelcome)
        }
    }

    func testChatList() throws {
        try shoot("chatlist") { app in
            try app.appear(AccessibilityID.chatListStatus)
        }
    }

    /// The room, with Dani's photo by the fire drawn rather than waiting.
    func testNearby() throws {
        try shoot("chat-nearby") { app in
            try app.reveal(AccessibilityID.chatRow("nearby")).tap()
            let thread = try app.appear(AccessibilityID.chatThread)
            _ = app.element(AccessibilityID.chatAttachmentWaiting).waitForNonExistence(timeout: Walking.appears)
            return thread
        }
    }

    /// Dani's DM, whose key is verified, so its header carries the shield.
    func testVerifiedDirect() throws {
        try shoot("dm-verified") { app in
            try open(Self.dani, in: app)
            return try app.appear(AccessibilityID.chatVerified)
        }
    }

    func testDirect() throws {
        try shoot("dm-sam") { app in
            try open(Self.sam, in: app)
            return try app.appear(AccessibilityID.chatThread)
        }
    }

    /// The encryption sheet over Dani's DM.
    func testEncryption() throws {
        try shoot("encryption") { app in
            try open(Self.dani, in: app)
            try app.appear(AccessibilityID.chatVerified).tap()
            return try app.buttons["Done"].appear("the encryption sheet")
        }
    }

    /// Dani's profile: verified, open to chat, and wearing a photo.
    func testProfileDetails() throws {
        try shoot("profile-details") { app in
            try open(Self.dani, in: app)
            try app.appear(AccessibilityID.chatProfile).tap()
            return try app.appear(AccessibilityID.profileDetailsScreen)
        }
    }

    func testGroup() throws {
        try shoot("chat-group") { app in
            try openGroup(in: app)
            return try app.appear(AccessibilityID.chatThread)
        }
    }

    func testGroupDetails() throws {
        try shoot("group-details") { app in
            try openGroup(in: app)
            try app.appear(AccessibilityID.chatGroupInfo).tap()
            return try app.appear(AccessibilityID.groupInfoScreen)
        }
    }

    /// River's request, waiting in its own inbox.
    func testRequests() throws {
        try shoot("requests") { app in
            try app.reveal(AccessibilityID.chatListRequests).tap()
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "request_row_"))
            return try row.firstMatch.appear("a request")
        }
    }

    func testNewMessage() throws {
        try shoot("new-message") { app in
            try app.appear(AccessibilityID.chatListNewMessage).tap()
            return try app.appear(AccessibilityID.newMessageScreen)
        }
    }

    func testSettings() throws {
        try shoot("settings") { app in
            try app.appear(AccessibilityID.chatListSettings).tap()
            return try app.appear(AccessibilityID.settingsScreen)
        }
    }

    /// Our own profile, from Settings.
    func testProfile() throws {
        try shoot("profile") { app in
            try app.appear(AccessibilityID.chatListSettings).tap()
            try app.reveal(AccessibilityID.settingsProfileRow).tap()
            return try app.appear(AccessibilityID.profileScreen)
        }
    }
}

// MARK: Shooting

extension KnitShots {
    /// The marketing scene's people whose DMs are shot, as their chat rows name them.
    private static let dani = "Dani Cho"
    private static let sam = "Sam Rivera"

    /// Launches the marketing scene with `arguments`, goes where `reach` takes it, and keeps the whole screen, status bar
    /// included, once the element `reach` returns holds still.
    private func shoot(_ name: String, _ arguments: String..., reach: (XCUIApplication) throws -> XCUIElement) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-demoScene", "marketing"] + arguments
        app.launch()
        settle(try reach(app))
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "a still screen")], timeout: Self.still)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(Self.mode)_\(name)"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }

    /// Opens the DM whose row carries `name`: neither the room's row nor a group's.
    private func open(_ name: String, in app: XCUIApplication) throws {
        let row = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier != %@ AND NOT identifier BEGINSWITH %@ AND label CONTAINS %@",
                "contact_",
                AccessibilityID.chatRow("nearby"),
                AccessibilityID.chatRow("g-"),
                name
            )
        )
        try app.reveal(row.firstMatch, "\(name)'s thread").tap()
    }

    /// Opens the scene's one group, Summit crew.
    private func openGroup(in app: XCUIApplication) throws {
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.chatRow("g-")))
        try app.reveal(group.firstMatch, "a group").tap()
    }

    /// Waits for `element` to stop moving, as `KnitUITests` does before an audit: a screen shot mid-slide is half of two.
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
}
