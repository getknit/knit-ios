/// A voice note's waveform: 64 bar heights, from 0 to 255, read from its decoded sound on each phone and kept on its
/// messages, never carried (knit-next ADR 034). Knit for Android's `VoiceAudio.peaks`, whose rules this ports, so the
/// same note draws the same shape on both. The decoding is the app's (`Sources/Knit/Voice/`); this takes what it read.
public enum VoicePeaks {
    /// Bars in a waveform (`VoiceAudio.PEAK_COUNT`).
    public static let count = 64

    /// The height a bar is drawn at, as a fraction, when a note has no waveform: Android's `FLAT_WAVEFORM`
    /// (`VoiceNote.kt:84`).
    public static let flatBar = 0.12

    /// The percentile a waveform is scaled to, so one knock or click doesn't flatten the speech around it
    /// (`NORMALISE_PERCENTILE`).
    static let percentile = 95

    /// A 16-bit magnitude below which the scale's percentile means a silent room rather than quiet speech, about 1% of
    /// full scale (`SILENCE_FLOOR`).
    static let silenceFloor: Int64 = 328

    /// The tallest bar.
    private static let fullBar: Int64 = 255

    /// Microseconds in a millisecond.
    private static let microsecondsPerMillisecond: Int64 = 1000

    /// The loudest a 16-bit sample can be either way from zero: `Int16.min`'s magnitude.
    private static let loudestSample = Int64(Int16.max) + 1

    /// Milliseconds in a second, and half of one, which rounds a clock to the nearest second.
    private static let millisecondsPerSecond = 1000
    private static let halfSecond = 500

    /// Seconds in a minute, and the first that takes a single digit after the colon.
    private static let secondsPerMinute = 60
    private static let tenSeconds = 10

    /// One run of decoded sound, as the decoder hands it over: when it starts, in microseconds from the note's start,
    /// and the loudest 16-bit sample in it, of any channel.
    public struct Chunk: Sendable, Equatable {
        /// When the run starts, in microseconds.
        public var startMicroseconds: Int64
        /// The loudest sample's magnitude, 0 to 32768.
        public var loudest: Int64

        /// A run starting at `startMicroseconds` whose loudest sample is `loudest` either way from zero.
        public init(startMicroseconds: Int64, loudest: Int64) {
            self.startMicroseconds = startMicroseconds
            self.loudest = loudest
        }
    }

    /// The bars for a note `totalMilliseconds` long whose decoded runs are `chunks`, or `nil` when the length is unknown
    /// or nothing decoded.
    ///
    /// As on Android, a whole run lands in the bar its start falls in, and the bar keeps the loudest sample it was handed
    /// (`VoiceAudio.kt:155-174`). The decoder's runs are an AAC frame each, 1024 samples, so a short note can leave a bar
    /// empty between two runs, on both phones alike.
    public static func bars(_ chunks: some Sequence<Chunk>, totalMilliseconds: Int?) -> [UInt8]? {
        // A run's start times the bar count must fit, and it is never past the note's end.
        guard let totalMilliseconds, totalMilliseconds > 0,
            !Int64(totalMilliseconds).multipliedReportingOverflow(by: microsecondsPerMillisecond * Int64(count)).overflow
        else {
            return nil
        }
        let total = Int64(totalMilliseconds) * microsecondsPerMillisecond
        var buckets = [Int64](repeating: 0, count: count)
        var heard = false
        for chunk in chunks {
            heard = true
            let start = min(max(chunk.startMicroseconds, 0), total)
            let bucket = min(Int(start * Int64(count) / total), count - 1)
            buckets[bucket] = max(buckets[bucket], min(max(chunk.loudest, 0), loudestSample))
        }
        guard heard else {
            return nil
        }
        let scale = scale(for: buckets)
        return buckets.map { UInt8(min($0 * fullBar / scale, fullBar)) }
    }

    /// What the bars divide by (`scaleFor`, `VoiceAudio.kt:232-237`): the 95th percentile, so a transient fills one bar
    /// and the speech the rest, unless that percentile is below ``silenceFloor``. A room that quiet is shown by its true
    /// peak, so the one click shows and the rest stays flat. Never below 1.
    static func scale(for buckets: [Int64]) -> Int64 {
        let sorted = buckets.sorted()
        guard let loudest = sorted.last else {
            return 1
        }
        let middle = sorted[(sorted.count - 1) * percentile / 100]
        return max(middle >= silenceFloor ? middle : loudest, 1)
    }

    /// The heights to draw, as fractions from 0 to 1: `bars` read back (`decodePeaks`), or ``count`` flat bars when a note
    /// has none.
    public static func heights(_ bars: [UInt8]?) -> [Double] {
        guard let bars, !bars.isEmpty else {
            return Array(repeating: flatBar, count: count)
        }
        return bars.map { Double($0) / Double(fullBar) }
    }

    /// A length as a voice bubble shows it, `m:ss` rounded to the nearest second, with no hours (`formatDuration`,
    /// `VoiceNote.kt:695-700`): 0:00, 0:42, 4:59, 75:00.
    public static func clock(milliseconds: Int) -> String {
        let seconds = (min(max(milliseconds, 0), Int.max - halfSecond) + halfSecond) / millisecondsPerSecond
        let past = seconds % secondsPerMinute
        return "\(seconds / secondsPerMinute):\(past < tenSeconds ? "0" : "")\(past)"
    }
}
