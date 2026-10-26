import KnitAppCore
import Testing

/// The demo's microphone under `-demoVoice` (ADR 2026-10.ue3y), which the UI walk records with since the Simulator has
/// none to speak into.
@MainActor
@Suite struct DemoVoiceCaptureTests {
    @Test func aPressRecordsTheClipWhileTheLevelRisesAndFalls() {
        let clip: [UInt8] = [0xFF, 0xF1, 0x50, 0x80, 0x01, 0x1F, 0xFC]
        let capture = DemoVoiceCapture(clip: clip)
        #expect(capture.level == 0, "silent until a press")
        #expect(capture.start())
        let levels = (0..<12).map { _ in capture.level }
        #expect(levels.allSatisfy { (0...1).contains($0) })
        #expect(levels.contains { $0 > 0.5 } && levels.contains { $0 < 0.5 }, "the dot moves as a voice would")
        #expect(capture.stop() == clip)
        #expect(capture.level == 0)
    }

    @Test func aCancelledRecordingFallsSilent() {
        let capture = DemoVoiceCapture(clip: [1, 2, 3])
        #expect(capture.start())
        _ = capture.level
        capture.cancel()
        #expect(capture.level == 0)
    }

    @Test func theDemoMicrophoneIsAllowedWithoutAPrompt() {
        let access = DemoMicrophone()
        #expect(access.authorization == .allowed)
        #expect(access.request() == .allowed)
    }
}
