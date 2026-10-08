import Testing

@testable import KnitAppCore

/// When each frame of a moving photo shows (ADR 2026-10.6cas, amended): clamped delays, a play that wraps for good, and
/// the limits past which a photo stays still.
@Suite struct AnimationTimingTests {
    /// Three frames of 100, 200 and 300 milliseconds.
    private let steps = AnimationTiming(delays: [0.1, 0.2, 0.3], width: 480, height: 270)

    @Test func eachFrameStandsForItsDelayAndThePlayWraps() throws {
        let timing = try #require(steps)
        #expect(timing.frames == 3)
        let frames = [0, 99, 100, 299, 300, 599, 600, 700].map { timing.frame(at: .milliseconds($0)) }
        #expect(frames == [0, 0, 1, 1, 2, 2, 0, 1])
        #expect(timing.frame(at: .seconds(-1)) == 0, "a moment before the start shows the first frame")
    }

    @Test func theNextChangeIsTheNextFramesEdge() throws {
        let timing = try #require(steps)
        #expect(timing.change(after: .zero) == .milliseconds(100))
        #expect(timing.change(after: .milliseconds(100)) == .milliseconds(300))
        #expect(timing.change(after: .milliseconds(599)) == .milliseconds(600))
        #expect(timing.change(after: .milliseconds(650)) == .milliseconds(700))
    }

    /// A tick that comes late lands on the frame due then, not the one after the last shown.
    @Test func aLateTickSkipsFrames() throws {
        let timing = try #require(steps)
        #expect(timing.frame(at: .milliseconds(6350)) == 2)
        #expect(timing.frame(at: .milliseconds(6000)) == 0)
    }

    /// Android plays every photo for good, whatever loop count its file gives, so there is none to read.
    @Test func aPhotoPlaysForGood() throws {
        let timing = try #require(steps)
        #expect(timing.frame(at: .seconds(3600)) == 0)
        #expect(timing.change(after: .seconds(3600)) == .milliseconds(3_600_100))
    }

    /// Delays of 0 and 10 milliseconds play at 100, as browsers and Android play them; a hostile delay is held to a minute.
    @Test func tooShortAndNonsenseDelaysAreClamped() throws {
        let timing = try #require(
            AnimationTiming(delays: [0, 0.01, 0.02, -1, .nan, .infinity, 1e300], width: 1, height: 1))
        #expect(timing.delays == [100, 100, 20, 100, 100, 100, 60_000])
    }

    @Test func aStillOrAnOversizedPhotoDoesNotPlay() {
        #expect(AnimationTiming(delays: [0.1], width: 10, height: 10) == nil, "one frame is a still")
        #expect(AnimationTiming(delays: [], width: 10, height: 10) == nil)
        let tooMany = Array(repeating: 0.1, count: AnimationTiming.maxFrames + 1)
        #expect(AnimationTiming(delays: tooMany, width: 10, height: 10) == nil)
        #expect(AnimationTiming(delays: Array(tooMany.dropLast()), width: 10, height: 10) != nil)
        #expect(AnimationTiming(delays: [0.1, 0.1], width: 2048, height: 2049) == nil)
        #expect(AnimationTiming(delays: [0.1, 0.1], width: 2048, height: 2048) != nil)
        #expect(AnimationTiming(delays: [0.1, 0.1], width: .max, height: 2) == nil)
        #expect(AnimationTiming(delays: [0.1, 0.1], width: 0, height: 2) == nil)
    }
}
