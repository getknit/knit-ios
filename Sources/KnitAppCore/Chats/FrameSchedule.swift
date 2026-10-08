/// Which of a moving picture's frames go out, and for how long each shows, when it is sent as ``ChatAnimation`` says
/// (`WebpTranscode.sample` in knit-next). The clip is sampled every ``ChatAnimation/framesPerSecond``th of a second,
/// and more sparsely when that would pass ``ChatAnimation/maxFrames``, so a long clip keeps its length at a lower rate.
/// Each sample shows for its share of the clip's time, so the whole plays as long as the source did.
///
/// Android encodes every sample, so a 10-frame-a-second GIF sampled 15 times a second goes out with frames repeated.
/// Here samples of the same source frame merge into one frame shown for their sum: the same picture on screen at every
/// moment, for fewer decodes and fewer bytes.
public struct FrameSchedule: Sendable, Equatable {
    /// One frame that goes out.
    public struct Frame: Sendable, Equatable {
        /// The source frame it shows.
        public let source: Int
        /// How long it shows, in milliseconds.
        public let milliseconds: Int
    }

    /// Milliseconds in a second.
    private static let millisecondsPerSecond = 1000

    /// The frames that go out, in order.
    public let frames: [Frame]

    /// The schedule for a clip whose frames stay `delays` seconds each, clamped as they play
    /// (``AnimationTiming``); `nil` for a still, or a clip past ``ChatAnimation/maxSourceFrames``.
    public init?(delays: [Double]) {
        guard delays.count > 1, delays.count <= ChatAnimation.maxSourceFrames else {
            return nil
        }
        let shown = delays.map(AnimationTiming.clamped)
        let duration = shown.reduce(0, +)
        var interval = max(Self.millisecondsPerSecond / ChatAnimation.framesPerSecond, 1)
        if duration / interval + 1 > ChatAnimation.maxFrames {
            interval = duration / ChatAnimation.maxFrames + 1
        }
        var out: [Frame] = []
        var source = 0
        var sourceEnds = shown[0]
        var time = 0
        while time < duration {
            while time >= sourceEnds {
                source += 1
                sourceEnds += shown[source]
            }
            let share = min(time + interval, duration) - time
            if let last = out.last, last.source == source {
                out[out.count - 1] = Frame(source: source, milliseconds: last.milliseconds + share)
            } else {
                out.append(Frame(source: source, milliseconds: share))
            }
            time += interval
        }
        frames = out
    }
}
