import KnitMesh
public import Observation

/// Whether Knit may use the microphone.
public enum MicrophoneAuthorization: Sendable, Equatable {
    /// Not asked yet.
    case notDetermined
    /// Allowed.
    case allowed
    /// Refused or restricted: only the Settings app can change it.
    case denied
}

/// Where the recorder reaches the microphone's permission: AVFAudio in the app, a stand-in in tests and `-seedDemo`, the
/// same arrangement as ``CameraAccess``.
public protocol MicrophoneAccess: Sendable {
    /// The current answer, read on the press that needs it.
    var authorization: MicrophoneAuthorization { get }
    /// Asks, when not asked yet, and answers the result.
    func request() async -> MicrophoneAuthorization
}

/// Where a voice note is recorded: the microphone through AVFoundation in the app, a canned clip under `-demoVoice`,
/// a stand-in in tests. It records AAC-LC in ADTS into memory, as Android's `VoiceRecorder` does, so the note never
/// reaches the disk as plaintext (knit-next ADR 034).
@preconcurrency
@MainActor
public protocol VoiceCapture: AnyObject {
    /// Starts recording, or answers false when the microphone is busy or nothing would record.
    func start() -> Bool
    /// How loud the input is now, from 0 to 1, for the recording dot. It is never stored.
    var level: Double { get }
    /// Stops and hands over what was recorded, as ADTS. When the encoder failed on the way, it is whatever reached
    /// memory, which may be nothing: the recorder judges the bytes, not the stop (`VoiceRecorder.stop`).
    func stop() -> [UInt8]
    /// Stops and throws the recording away.
    func cancel()
}

/// A voice note the composer holds until Send, as ``StagedPhoto`` holds a photo: the bytes as they leave this phone,
/// and their length, which the preview shows.
public struct StagedVoice: Sendable, Equatable {
    /// The note, AAC-LC in ADTS.
    public var bytes: [UInt8]
    /// How long it plays, in milliseconds, from its headers.
    public var durationMilliseconds: Int
    /// Its waveform, once read (``VoicePeaks``).
    public var peaks: [UInt8]?
}

/// Why the composer holds no voice note after a press.
public enum VoiceFailure: Sendable, Equatable {
    /// The press or the recording was under ``VoiceRecorder/shortest``: "Hold the button to record".
    case tooShort
    /// The microphone was busy, or what it recorded doesn't play.
    case unrecorded
    /// The microphone is refused, and only Settings can allow it.
    case microphoneOff
}

/// The composer's recorder: hold to talk, slide up to lock, slide back to cancel, and a recording kept for Send
/// (`ChatViewModel`'s voice half and `MicButton`, knit-next ADR 034). The thread drives it: a press, the gesture's
/// changes, a release, and a tick every ``tickMilliseconds`` while it records.
@preconcurrency
@MainActor
@Observable
public final class VoiceRecorder {
    /// The shortest press or recording kept (`MIN_VOICE_MS`, `ChatViewModel.kt:3239`).
    nonisolated public static let shortest = 700
    /// The longest recording. At it the recording stops and is kept, not thrown away (`MAX_DURATION_MS`,
    /// `VoiceRecorder.kt:255`, and `ChatViewModel.kt:2894-2899`).
    nonisolated public static let longest = 300_000
    /// How often the thread ticks a recording, for its clock and its dot (`VOICE_TICK_MS`).
    nonisolated public static let tickMilliseconds = 60

    /// What the recorder is doing.
    public enum Phase: Sendable, Equatable {
        /// Nothing: the mic waits for a press.
        case idle
        /// Recording, held by the finger, or locked so the finger is free (`VoiceRecordingBar`).
        case recording(locked: Bool)
    }

    @ObservationIgnored private let capture: any VoiceCapture
    @ObservationIgnored private let access: any MicrophoneAccess
    @ObservationIgnored private let now: () -> Int64
    @ObservationIgnored private var startedAt: Int64 = 0

    /// What it is doing now.
    public private(set) var phase = Phase.idle
    /// How long the recording has run, in milliseconds, as of the last tick.
    public private(set) var elapsedMilliseconds = 0
    /// How loud the input was at the last tick, from 0 to 1.
    public private(set) var level = 0.0
    /// The note the composer holds.
    public internal(set) var staged: StagedVoice?
    /// Why the last press kept nothing, which the screen says until it is dismissed.
    public var failure: VoiceFailure?

    /// A recorder over `capture`, asking `access` for the microphone, timed by `now`: the monotonic clock, in
    /// milliseconds.
    public init(capture: any VoiceCapture, access: any MicrophoneAccess, now: @escaping () -> Int64) {
        self.capture = capture
        self.access = access
        self.now = now
    }

    /// Whether it is recording.
    public var isRecording: Bool {
        phase != .idle
    }

    /// Whether the recording is locked, so the finger is free and the composer's trailing button stops it.
    public var isLocked: Bool {
        phase == .recording(locked: true)
    }

    /// A press on the mic: starts recording when the microphone is allowed. `locked` starts it locked, as VoiceOver's
    /// activation does (`MicButton`'s semantics `onClick`), since an accessibility service can't hold a press.
    ///
    /// A press that finds the permission not asked yet asks and records nothing: by the answer the finger has left, and
    /// a recording then would catch the wrong moment (`MicGate.runOrRequest`, ADR 034 §3). The next press records.
    public func press(locked: Bool = false) {
        guard phase == .idle else {
            return
        }
        switch access.authorization {
        case .notDetermined:
            let asking = access
            Task { @MainActor [weak self] in
                if await asking.request() == .denied {
                    self?.failure = .microphoneOff
                }
            }
        case .denied:
            failure = .microphoneOff
        case .allowed:
            guard capture.start() else {
                failure = .unrecorded
                return
            }
            startedAt = now()
            elapsedMilliseconds = 0
            level = 0
            failure = nil
            phase = .recording(locked: locked)
        }
    }

    /// The finger slid up past the lock: the recording carries on with the finger off.
    public func lock() {
        if phase == .recording(locked: false) {
            phase = .recording(locked: true)
        }
    }

    /// The finger lifted. An unlocked recording stops and is kept; a locked one carries on until ``stop()``.
    public func release() {
        if phase == .recording(locked: false) {
            finish(sayingWhyNot: true)
        }
    }

    /// The Stop button on a locked recording: it stops and is kept.
    public func stop() {
        if isRecording {
            finish(sayingWhyNot: true)
        }
    }

    /// Slid back to cancel, or the locked bar's cancel: the recording is thrown away.
    public func cancel() {
        guard isRecording else {
            return
        }
        capture.cancel()
        phase = .idle
    }

    /// Knit left the screen, or the thread closed. A recording stops and is kept if it is long enough, so it waits in the
    /// composer, and one too short is dropped without a word: nobody let go too soon. Android keeps recording until its
    /// screen closes, but Knit has no audio background mode (ADR 2026-09.khjj), so iOS would end it anyway.
    public func leave() {
        if isRecording {
            finish(sayingWhyNot: false)
        }
    }

    /// The thread's tick: the clock and the dot move, and the recording stops and is kept at ``longest``.
    public func tick() {
        guard isRecording else {
            return
        }
        elapsedMilliseconds = elapsed()
        level = min(max(capture.level, 0), 1)
        if elapsedMilliseconds >= Self.longest {
            finish(sayingWhyNot: true)
        }
    }

    /// The composer's Remove on the held note, or Send having sent it.
    public func removeStaged() {
        staged = nil
    }

    /// Stops the recording and keeps it, judging the press and then the bytes as Android does
    /// (`ChatViewModel.kt:2929-2947`): a press under ``shortest`` is cancelled, not stopped, since the encoder has made
    /// nothing yet; bytes that don't parse as ADTS are no recording; and one that plays under ``shortest`` is too short.
    private func finish(sayingWhyNot: Bool) {
        let ran = elapsed()
        phase = .idle
        guard ran >= Self.shortest else {
            capture.cancel()
            failure = sayingWhyNot ? .tooShort : nil
            return
        }
        let bytes = capture.stop()
        guard !bytes.isEmpty, bytes.count <= OutgoingPhoto.maxBytes, let length = VoiceAudio.durationMs(adts: bytes) else {
            failure = sayingWhyNot ? .unrecorded : nil
            return
        }
        guard length >= Self.shortest else {
            failure = sayingWhyNot ? .tooShort : nil
            return
        }
        staged = StagedVoice(bytes: bytes, durationMilliseconds: length)
    }

    /// Milliseconds since the recording started, never negative.
    private func elapsed() -> Int {
        Int(clamping: max(now() - startedAt, 0))
    }
}
