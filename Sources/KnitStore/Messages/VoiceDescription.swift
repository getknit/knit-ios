/// What a voice note's bytes say about themselves, read on this phone (knit-next `VoiceAudio.Description`,
/// `VoiceAudio.kt:176-183` at `e63f15f4`): how long it plays, and the bars its waveform draws. Each phone reads it from
/// the note's own bytes, the sender from what it recorded and a recipient once the blob lands, so it never crosses the
/// wire (knit-next ADR 034), as ``PhotoDimensions`` never does.
///
/// Either half may be missing: Android's `describe` gives a duration without peaks when the decoder fails, and peaks
/// without a duration when the bytes carry no ADTS and no container length. It stores whatever it got, and skips only a
/// description with neither (``isEmpty``). A row is described once it has a duration (`MessageDao.voiceMetaWanted`), so
/// one with peaks alone is read again.
public struct VoiceDescription: Sendable, Equatable {
    /// How long it plays, in milliseconds (`voiceDurationMs`), or `nil` when its bytes did not say.
    public let durationMs: Int?
    /// The waveform's bar heights, 0 to 255 each (`voicePeaks`), normally 64 (`VoiceAudio.PEAK_COUNT`), or `nil` when
    /// its bytes could not be decoded. Android keeps them in base64 text; this port keeps the bytes. No length is
    /// enforced, so a newer build's count reads as it is.
    public let peaks: [UInt8]?

    /// Whether its bytes said nothing worth storing (`Description.isEmpty`).
    public var isEmpty: Bool { durationMs == nil && peaks == nil }

    /// A description. An empty waveform is no waveform: it reads back from the store as `nil`, so it is `nil` here too.
    public init(durationMs: Int? = nil, peaks: [UInt8]? = nil) {
        self.durationMs = durationMs
        self.peaks = peaks?.isEmpty == true ? nil : peaks
    }
}
