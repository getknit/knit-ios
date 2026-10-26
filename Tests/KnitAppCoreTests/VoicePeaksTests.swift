import Testing

@testable import KnitAppCore

/// A voice note's waveform from what its decoder read (knit-next ADR 034): Android's buckets, its scale with the
/// percentile and the silence floor, and the clock its bubble shows. Android's `VoiceAudioTest` cases for the scale, ported.
@Suite struct VoicePeaksTests {
    /// A knock several times louder than the speech fills one bar, and the speech fills the rest.
    @Test func oneTransientDoesNotFlattenTheSpeech() {
        var speech = [Int64](repeating: 1000, count: VoicePeaks.count)
        speech[0] = 20_000
        let scale = VoicePeaks.scale(for: speech)
        #expect(scale == 1000)
        #expect(1000 * 255 / scale > 120)
    }

    /// A dead room isn't drawn as a confident waveform of nothing: its one click shows, and the rest stays flat.
    @Test func silenceIsNotAmplified() {
        var silence = [Int64](repeating: 4, count: VoicePeaks.count)
        silence[3] = 900
        let scale = VoicePeaks.scale(for: silence)
        #expect(scale == 900)
        #expect(4 * 255 / scale < 30)
    }

    @Test func anOrdinaryEnvelopeReachesTheTop() throws {
        let envelope = (0..<VoicePeaks.count).map { Int64(3000 + ($0 % 8) * 500) }
        let scale = VoicePeaks.scale(for: envelope)
        let loudest = try #require(envelope.max())
        #expect(loudest * 255 / scale >= 240)
        #expect(VoicePeaks.scale(for: [Int64](repeating: 0, count: VoicePeaks.count)) == 1, "never below 1")
    }

    /// A whole run lands in the bar its start falls in, and the bar keeps its loudest sample, as Android buckets a
    /// decoder's output buffers.
    @Test func eachRunLandsInTheBarItStartsIn() throws {
        // 64 runs of 100 ms over a 6.4 s note: one a bar, each louder than the last.
        let runs = (0..<64).map { VoicePeaks.Chunk(startMicroseconds: Int64($0) * 100_000, loudest: Int64(400 + $0 * 100)) }
        let bars = try #require(VoicePeaks.bars(runs, totalMilliseconds: 6400))
        #expect(bars.count == VoicePeaks.count)
        // The 95th percentile is the 60th quietest, 6300, so the four loudest clip at the top.
        #expect(bars[0] == UInt8(400 * 255 / 6300))
        #expect(bars[59] == 255 && bars[63] == 255)
        #expect(bars == bars.sorted(), "louder runs make taller bars")
    }

    /// A short note's runs are longer than its bars, so a bar between two runs stays empty, on Android as here.
    @Test func aShortNoteLeavesBarsBetweenItsRuns() throws {
        // A 1 s note at 16 kHz: 16 runs of 64 ms over 64 bars of 15.6 ms.
        let runs = (0..<16).map { VoicePeaks.Chunk(startMicroseconds: Int64($0) * 64_000, loudest: 8000) }
        let bars = try #require(VoicePeaks.bars(runs, totalMilliseconds: 1000))
        #expect(bars.filter { $0 > 0 }.count == 16)
        #expect(bars[0] == 255 && bars[1] == 0 && bars[3] == 0 && bars[4] == 255, "the second run starts at 4.1 bars")
    }

    /// A run past the end, before the start, or louder than 16 bits can be stays inside the bars.
    @Test func aStrayRunStaysInRange() throws {
        let runs = [
            VoicePeaks.Chunk(startMicroseconds: -5, loudest: 1000),
            VoicePeaks.Chunk(startMicroseconds: 99_000_000, loudest: 1000),
            VoicePeaks.Chunk(startMicroseconds: 500_000, loudest: .max),
            VoicePeaks.Chunk(startMicroseconds: 600_000, loudest: -7),
        ]
        let bars = try #require(VoicePeaks.bars(runs, totalMilliseconds: 1000))
        #expect(bars.count == VoicePeaks.count)
        #expect(bars[0] > 0 && bars[63] > 0 && bars[32] == 255)
    }

    @Test func aNoteWithNoLengthOrNoSoundHasNoBars() {
        let run = VoicePeaks.Chunk(startMicroseconds: 0, loudest: 1000)
        #expect(VoicePeaks.bars([run], totalMilliseconds: nil) == nil)
        #expect(VoicePeaks.bars([run], totalMilliseconds: 0) == nil)
        #expect(VoicePeaks.bars([], totalMilliseconds: 1000) == nil)
        #expect(VoicePeaks.bars([run], totalMilliseconds: .max) == nil, "a length no bar arithmetic can hold")
    }

    /// Stored bars read back as fractions, 255 at full height; a note with none draws Android's flat bars.
    @Test func barsReadBackAsHeights() {
        let heights = VoicePeaks.heights([0, 64, 128, 255])
        #expect(heights.count == 4)
        #expect(heights[0] == 0 && heights[3] == 1)
        #expect(heights[2] > heights[1])
        #expect(VoicePeaks.heights(nil) == Array(repeating: 0.12, count: 64))
        #expect(VoicePeaks.heights([]) == Array(repeating: 0.12, count: 64))
    }

    /// `m:ss` rounded to the nearest second, as Android's `formatDuration` writes it.
    @Test func theClockRoundsToTheSecond() {
        #expect(VoicePeaks.clock(milliseconds: 0) == "0:00")
        #expect(VoicePeaks.clock(milliseconds: 499) == "0:00")
        #expect(VoicePeaks.clock(milliseconds: 500) == "0:01")
        #expect(VoicePeaks.clock(milliseconds: 42_400) == "0:42")
        #expect(VoicePeaks.clock(milliseconds: 299_600) == "5:00")
        #expect(VoicePeaks.clock(milliseconds: 4_500_000) == "75:00")
        #expect(VoicePeaks.clock(milliseconds: -1) == "0:00")
        #expect(!VoicePeaks.clock(milliseconds: .max).isEmpty)
    }
}
