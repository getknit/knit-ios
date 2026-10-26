public import KnitStore

/// Where a voice note's sound is decoded: AudioToolbox in the app, a stand-in in tests. Its runs give the waveform, and
/// a container's stated length times audio that has no ADTS headers to count, such as a file someone picked on Android
/// (`VoiceAudio.containerDurationMs`).
public protocol VoiceDecoder: Sendable {
    /// The decoded sound of `bytes`, one run per decoder output, or `nil` when they don't decode.
    func runs(of bytes: [UInt8]) -> [VoicePeaks.Chunk]?
    /// How long the first audio track in `bytes` says it plays, in milliseconds, or `nil` when it says nothing.
    func containerMilliseconds(of bytes: [UInt8]) -> Int?
}

extension VoiceDecoder {
    /// What `bytes` say about themselves (`VoiceAudio.describe`): the length from their ADTS headers, or else from their
    /// container, and the waveform over that length. Either half may be missing, as on Android.
    public func describe(_ bytes: [UInt8]) -> VoiceDescription {
        let length = VoiceAudio.durationMs(adts: bytes) ?? containerMilliseconds(of: bytes)
        let peaks = length.flatMap { length in runs(of: bytes).flatMap { VoicePeaks.bars($0, totalMilliseconds: length) } }
        return VoiceDescription(durationMs: length, peaks: peaks)
    }
}

/// What a build that has voice notes hands the session: the microphone, its permission, the one player and the
/// decoder. Voice notes are a debug build's alone until the maintainer approves them for the store, since no model on
/// the phone screens speech and App Review holds Knit to rule 1.2 (ADR 2026-10.tydq). A release build hands none, and
/// then the composer has no mic, a voice message keeps the tile that says this build can't play it, and nothing is
/// described: the build behaves as it did before voice notes.
@preconcurrency
@MainActor
public struct VoiceNotes {
    /// Where a note is recorded.
    public let capture: any VoiceCapture
    /// Whether the microphone may be used.
    public let access: any MicrophoneAccess
    /// The app's one player.
    public let playback: VoicePlayback
    /// Where a note's sound is decoded.
    public let decoder: any VoiceDecoder
    /// The monotonic clock, in milliseconds, that times a recording.
    public let now: () -> Int64

    /// Voice notes recorded by `capture` once `access` allows, played by `playback`, decoded by `decoder`, timed by `now`.
    public init(
        capture: any VoiceCapture, access: any MicrophoneAccess, playback: VoicePlayback, decoder: any VoiceDecoder,
        now: @escaping () -> Int64
    ) {
        self.capture = capture
        self.access = access
        self.playback = playback
        self.decoder = decoder
        self.now = now
    }

    /// A recorder for one thread's composer.
    public func recorder() -> VoiceRecorder {
        VoiceRecorder(capture: capture, access: access, decoder: decoder, now: now)
    }
}
