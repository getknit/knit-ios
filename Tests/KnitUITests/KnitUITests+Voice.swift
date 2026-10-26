// XCUITest has no Swift Testing form, and Nimble is no dependency of ours: XCTest's own assertions are the only ones.
// swiftlint:disable prefer_nimble

import XCTest

// MARK: Voice notes

// The voice walk, apart from the rest only to keep the class under SwiftLint's body and file lengths.
extension KnitUITests {
    /// How long a held press lasts before it slides up to lock, and how far it slides, in seconds and points.
    private static let pressBeforeLock: TimeInterval = 0.6
    private static let slideToLock: CGFloat = -90
    /// How long a press the recorder keeps lasts: past its 0.7 s floor.
    private static let keptPress: TimeInterval = 1.5

    /// The voice scene's DM with Sam under `-demoVoice`, whose mic records the clip a debug build bundles, since the
    /// Simulator has no microphone to speak into (knit-next ADR 034):
    ///
    /// - Sam's note reads its length, which the session decoded from the clip as the thread loaded.
    /// - One note streams in under its ring, and one waits for a phone that has it.
    /// - A press slid up locks the recording. The bar records in the field's place until Stop keeps the note.
    /// - The kept note plays and pauses in the composer, and Send sends it into the thread.
    /// - A press held and let go keeps a note too, which Remove takes out, and a tap too short says how to record.
    ///
    /// The thread is audited with the notes on screen, while recording, and with a note held.
    func testVoiceNotesPlayAndTheMicRecordsOne() throws {
        try walkVoiceNotes()
    }

    /// The voice walk, which ``testVoiceNotesPlayAndTheMicRecordsOne()`` runs at the default size and the every-screen
    /// walks at the largest size and in dark mode.
    func walkVoiceNotes() throws {
        let app = launch("-demoScene", "voice", "-demoVoice")
        try openDirect(in: app)
        try app.appear(AccessibilityID.chatThread)
        wait(for: try app.reveal(AccessibilityID.chatVoice("voice-1")), until: "label CONTAINS 'Voice message, 0:07'")
        wait(for: try app.reveal(AccessibilityID.chatVoice("voice-3")), until: "label CONTAINS ' of '")
        wait(for: try app.reveal(AccessibilityID.chatVoice("voice-4")), until: "label CONTAINS 'Voice message appears'")
        audit(app, screen: AccessibilityID.chatThread)

        // Held, then slid up: the recording locks, and the finger lifts with it running.
        let mic = try app.appear(AccessibilityID.chatVoiceRecord)
        let start = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: Self.pressBeforeLock, thenDragTo: start.withOffset(CGVector(dx: 0, dy: Self.slideToLock)))
        try app.appear(AccessibilityID.chatVoiceRecording)
        try app.appear(AccessibilityID.chatVoiceCancel)
        XCTAssertFalse(app.element(AccessibilityID.chatVoiceRecord).exists, "a locked recording gives the mic up to Stop")
        audit(app, screen: AccessibilityID.chatThread)
        try app.appear(AccessibilityID.chatVoiceStop).tap()

        // The kept note plays from the composer, and pauses.
        try app.appear(AccessibilityID.chatVoiceStaged)
        let play = try app.appear(AccessibilityID.chatVoicePlay)
        play.tap()
        wait(for: play, until: "label == 'Pause voice message'")
        play.tap()
        wait(for: play, until: "label == 'Play voice message'")
        audit(app, screen: AccessibilityID.chatThread)
        try app.appear(AccessibilityID.chatSend).tap()
        XCTAssert(app.element(AccessibilityID.chatVoiceStaged).waitForNonExistence(timeout: Walking.appears), "Send kept the note")
        let sent = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@", "chat_voice_message_", "chat_voice_message_voice-")
            )
            .firstMatch
        // The mic records a clip of its own, four seconds long, so the thread's notes don't play with it.
        wait(for: try sent.appear("our voice note"), until: "label CONTAINS 'Voice message, 0:04'")

        // Held and let go: the note is kept, and Remove takes it out.
        try app.appear(AccessibilityID.chatVoiceRecord).press(forDuration: Self.keptPress)
        try app.appear(AccessibilityID.chatVoiceStaged)
        try app.appear(AccessibilityID.chatVoiceRemove).tap()
        XCTAssert(app.element(AccessibilityID.chatVoiceStaged).waitForNonExistence(timeout: Walking.appears), "Remove kept the note")

        // A tap is too short to keep, and says how to record.
        try app.appear(AccessibilityID.chatVoiceRecord).tap()
        try app.staticTexts["Hold the mic button to record"].appear("the too-short hint")
        app.terminate()
    }
}

// swiftlint:enable prefer_nimble
