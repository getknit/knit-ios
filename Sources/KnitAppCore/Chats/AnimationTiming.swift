/// When each frame of a moving photo shows: a GIF, an animated WebP or an APNG (ADR 2026-10.6cas, amended). The app reads
/// the delays from the photo's bytes and asks this which frame stands at a moment, so a player that ticks late skips
/// frames rather than drifting. Android plays the same files with Coil's `AnimatedImageDecoder` (knit-next's
/// `KnitApplication.kt`), whose repeat count defaults to forever whatever the file says, so every photo plays for good
/// here too.
public struct AnimationTiming: Sendable, Equatable {
    /// The most frames a photo may have and still play. Android's GIFs play at 15 frames a second, and its stickers have
    /// at most 200 frames (`AttachmentStore.kt`).
    public static let maxFrames = 1000
    /// The most pixels a frame may have and still play, a 2048-pixel square: each frame is decoded as it is due, and
    /// Android sends no photo past 1280 pixels on its long side.
    public static let maxFramePixels = maxFrameSide * maxFrameSide
    private static let maxFrameSide = 2048
    /// A delay shorter than this plays at ``standInDelay``, as browsers and Android's decoder play it: many GIFs say 0
    /// or 10 milliseconds and mean "as fast as is sensible".
    static let shortestDelay = 20
    /// What a too-short delay plays at, in milliseconds.
    static let standInDelay = 100
    /// The longest a frame stays, in milliseconds, so a hostile file's delays cannot overflow the cycle.
    static let longestDelay = 60_000
    /// Milliseconds in a second.
    private static let millisecondsPerSecond = 1000.0
    /// Where elapsed time stops counting, in milliseconds: thousands of years, short of overflowing an `Int`.
    private static let elapsedCeiling = Double(Int32.max) * Double(longestDelay)

    /// How long each frame stays, in milliseconds, once clamped.
    let delays: [Int]
    /// How long one play takes, in milliseconds.
    let cycle: Int

    /// The timing of a photo of `delays.count` frames, each `width` by `height` pixels, whose frames stay `delays`
    /// seconds each; `nil` for a still, or for one past ``maxFrames`` or ``maxFramePixels``, which shows its first frame.
    public init?(delays: [Double], width: Int, height: Int) {
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        guard delays.count > 1, delays.count <= Self.maxFrames, width > 0, height > 0, !overflow, area <= Self.maxFramePixels
        else {
            return nil
        }
        self.delays = delays.map(Self.clamped)
        cycle = self.delays.reduce(0, +)
    }

    /// How many frames the photo has.
    public var frames: Int {
        delays.count
    }

    /// The frame that shows `elapsed` after the photo started.
    public func frame(at elapsed: Duration) -> Int {
        var into = Self.milliseconds(elapsed) % cycle
        for (index, delay) in delays.enumerated() {
            if into < delay {
                return index
            }
            into -= delay
        }
        return delays.count - 1
    }

    /// When, counted from the start like `elapsed`, the frame next changes after `elapsed`.
    public func change(after elapsed: Duration) -> Duration {
        let now = Self.milliseconds(elapsed)
        var edge = now - now % cycle
        for delay in delays {
            edge += delay
            if edge > now {
                return .milliseconds(edge)
            }
        }
        return .milliseconds(edge)
    }

    /// `seconds` in whole milliseconds, within ``shortestDelay`` and ``longestDelay``.
    static func clamped(_ seconds: Double) -> Int {
        let milliseconds = seconds * millisecondsPerSecond
        guard milliseconds.isFinite, milliseconds >= Double(shortestDelay) else {
            return standInDelay
        }
        return Int(min(milliseconds, Double(longestDelay)).rounded())
    }

    /// `duration` in whole milliseconds, within 0 and ``elapsedCeiling``.
    private static func milliseconds(_ duration: Duration) -> Int {
        Int(min(max(duration / .milliseconds(1), 0), elapsedCeiling).rounded(.down))
    }
}
