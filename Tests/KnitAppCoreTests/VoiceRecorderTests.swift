import KnitMesh
import KnitSync
import Testing

@testable import KnitAppCore

/// The composer's recorder (knit-next ADR 034): hold, lock, release and cancel; Android's 0.7 s floor on the press and
/// on the recording, its five-minute cap that keeps the note, bytes judged rather than the stop, the permission asked
/// without recording, and a recording kept when Knit leaves the screen.
@MainActor
@Suite struct VoiceRecorderTests {
    /// A microphone that records what the test hands it.
    @MainActor
    final class FakeCapture: VoiceCapture {
        var starts = true
        var level = 0.5
        var recorded: [UInt8] = VoiceAudioTests.adts(100, index: 8) // 6.4 s at 16 kHz
        private(set) var started = 0
        private(set) var stopped = 0
        private(set) var cancelled = 0

        func start() -> Bool {
            started += 1
            return starts
        }

        func stop() -> [UInt8] {
            stopped += 1
            return recorded
        }

        func cancel() {
            cancelled += 1
        }
    }

    /// A permission the test sets, which answers a request with `answer`, the way ``FakeCamera`` answers.
    final class FakeAccess: MicrophoneAccess {
        private struct State {
            var authorization: MicrophoneAuthorization
            var requests = 0
        }

        private let state: Lock<State>
        private let answer: MicrophoneAuthorization

        init(_ authorization: MicrophoneAuthorization, answer: MicrophoneAuthorization = .allowed) {
            state = Lock(State(authorization: authorization))
            self.answer = answer
        }

        /// How many times it was asked.
        var requests: Int { state.withLock { $0.requests } }

        var authorization: MicrophoneAuthorization { state.withLock { $0.authorization } }

        func request() -> MicrophoneAuthorization {
            state.withLock { state in
                state.requests += 1
                if state.authorization == .notDetermined {
                    state.authorization = answer
                }
                return state.authorization
            }
        }
    }

    /// The monotonic clock, in milliseconds, which each test moves.
    final class Clock {
        var now: Int64 = 1_000_000
    }

    let capture = FakeCapture()
    let clock = Clock()

    func recorder(_ access: FakeAccess = FakeAccess(.allowed)) -> VoiceRecorder {
        let time = clock
        return VoiceRecorder(capture: capture, access: access) { time.now }
    }

    @Test func aHeldPressRecordsAndAReleaseKeepsIt() throws {
        let voice = recorder()
        voice.press()
        #expect(voice.phase == .recording(locked: false))
        clock.now += 2500
        voice.tick()
        #expect(voice.elapsedMilliseconds == 2500)
        #expect(voice.level == 0.5)
        voice.release()
        #expect(voice.phase == .idle)
        let staged = try #require(voice.staged)
        #expect(staged.durationMilliseconds == 6400, "the length is the bytes', not the press's")
        #expect(staged.bytes == capture.recorded)
        #expect(voice.failure == nil)
    }

    @Test func aLockedRecordingOutlivesTheFingerUntilStop() throws {
        let voice = recorder()
        voice.press()
        voice.lock()
        #expect(voice.isLocked)
        clock.now += 3000
        voice.release()
        #expect(voice.isRecording, "the finger lifting leaves a locked recording running")
        voice.stop()
        #expect(voice.phase == .idle)
        _ = try #require(voice.staged)
    }

    /// VoiceOver's activation starts a locked recording, since an accessibility service can't hold a press.
    @Test func anAccessibleActivationStartsLocked() {
        let voice = recorder()
        voice.press(locked: true)
        #expect(voice.isLocked)
    }

    @Test func aCancelThrowsTheRecordingAway() {
        let voice = recorder()
        voice.press()
        clock.now += 5000
        voice.cancel()
        #expect(voice.phase == .idle)
        #expect(voice.staged == nil)
        #expect(capture.cancelled == 1 && capture.stopped == 0)
        #expect(voice.failure == nil)
    }

    /// A press under 0.7 s is cancelled, not stopped: the encoder has made nothing yet.
    @Test func aShortPressIsCancelledAndSaysHoldTheButton() {
        let voice = recorder()
        voice.press()
        clock.now += 699
        voice.release()
        #expect(voice.staged == nil)
        #expect(voice.failure == .tooShort)
        #expect(capture.cancelled == 1 && capture.stopped == 0)
    }

    /// A press long enough whose bytes play under 0.7 s is too short too.
    @Test func aShortRecordingIsTooShort() {
        let voice = recorder()
        capture.recorded = VoiceAudioTests.adts(10, index: 8) // 640 ms
        voice.press()
        clock.now += 900
        voice.release()
        #expect(voice.staged == nil)
        #expect(voice.failure == .tooShort)
    }

    /// The bytes are judged, not the stop: bytes that don't parse, or none, are no recording.
    @Test func bytesThatDoNotPlayAreNoRecording() {
        let voice = recorder()
        for recorded in [[], Array("not audio".utf8), [UInt8](repeating: 0xFF, count: OutgoingPhoto.maxBytes + 1)] {
            capture.recorded = recorded
            voice.press()
            clock.now += 2000
            voice.release()
            #expect(voice.staged == nil)
            #expect(voice.failure == .unrecorded)
        }
    }

    @Test func aBusyMicrophoneSaysItCouldNotRecord() {
        let voice = recorder()
        capture.starts = false
        voice.press()
        #expect(voice.phase == .idle)
        #expect(voice.failure == .unrecorded)
    }

    /// At five minutes the recording stops and is kept, as Android stages it.
    @Test func theCapStopsAndKeepsTheRecording() throws {
        let voice = recorder()
        voice.press(locked: true)
        clock.now += Int64(VoiceRecorder.longest) - 1
        voice.tick()
        #expect(voice.isRecording)
        clock.now += 1
        voice.tick()
        #expect(voice.phase == .idle)
        _ = try #require(voice.staged)
    }

    /// A press that finds the permission not asked asks, and records nothing even when it is allowed: the finger has
    /// gone by then. The next press records.
    @Test func thePermissionIsAskedWithoutRecording() async {
        let access = FakeAccess(.notDetermined, answer: .allowed)
        let voice = recorder(access)
        voice.press()
        #expect(voice.phase == .idle)
        await waitFor { access.requests == 1 }
        #expect(capture.started == 0)
        #expect(voice.failure == nil)
        voice.press()
        #expect(voice.isRecording)
    }

    @Test func aRefusedMicrophoneSendsThemToSettings() async {
        let asked = FakeAccess(.notDetermined, answer: .denied)
        let first = recorder(asked)
        first.press()
        await waitFor { first.failure != nil }
        #expect(first.failure == .microphoneOff)

        let refused = recorder(FakeAccess(.denied))
        refused.press()
        #expect(refused.failure == .microphoneOff)
        #expect(capture.started == 0)
    }

    /// Leaving the screen keeps a recording long enough to keep, and drops a shorter one without a word.
    @Test func leavingTheScreenKeepsTheRecording() throws {
        let voice = recorder()
        voice.press()
        clock.now += 1500
        voice.leave()
        #expect(voice.phase == .idle)
        _ = try #require(voice.staged)

        voice.removeStaged()
        voice.press()
        clock.now += 300
        voice.leave()
        #expect(voice.staged == nil)
        #expect(voice.failure == nil, "nobody let go too soon")
    }

    /// A second press while recording, a lock while idle and a stop while idle change nothing.
    @Test func gesturesOutOfTurnDoNothing() {
        let voice = recorder()
        voice.lock()
        voice.stop()
        voice.release()
        voice.cancel()
        voice.tick()
        #expect(voice.phase == .idle)
        voice.press()
        voice.press()
        #expect(capture.started == 1)
    }

    /// Yields until `condition` holds, a few hundred times at most.
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            await Task.yield()
        }
    }
}
