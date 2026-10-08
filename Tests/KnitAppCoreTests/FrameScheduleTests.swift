import KnitAppCore
import Testing

/// A moving picture is sampled as Android's `WebpTranscode.sample` samples one (ADR 2026-10.8hmx): 15 times a second,
/// stretched past 200 frames, each sample its share of the clip's time; here repeated samples merge into one frame.
@Suite struct FrameScheduleTests {
    private func schedule(_ delays: [Double]) throws -> FrameSchedule {
        try #require(FrameSchedule(delays: delays))
    }

    private func total(_ schedule: FrameSchedule) -> Int {
        schedule.frames.map(\.milliseconds).reduce(0, +)
    }

    @Test func aSlowClipKeepsEveryFrameAtItsOwnTime() throws {
        // 10 frames a second: each 100 ms frame is sampled once or twice at 66 ms, and the repeats merge.
        let clip = try schedule([Double](repeating: 0.1, count: 10))
        #expect(clip.frames.map(\.source) == Array(0..<10))
        #expect(total(clip) == 1000)
        #expect(clip.frames.allSatisfy { (66...132).contains($0.milliseconds) })
    }

    @Test func aFastClipDropsToFifteenFramesASecond() throws {
        // 50 frames a second for two seconds: 100 frames in, about 30 out.
        let clip = try schedule([Double](repeating: 0.02, count: 100))
        #expect((30...31).contains(clip.frames.count))
        #expect(total(clip) == 2000)
        #expect(clip.frames.map(\.source) == clip.frames.map(\.source).sorted(), "frames stay in order")
    }

    @Test func aLongClipIsStretchedToKeepItsLength() throws {
        // 400 frames of 100 ms: at 15 a second that is 600 samples, so the interval stretches to keep 200 at most.
        let clip = try schedule([Double](repeating: 0.1, count: 400))
        #expect(clip.frames.count <= ChatAnimation.maxFrames)
        #expect(clip.frames.count > ChatAnimation.maxFrames / 2)
        #expect(total(clip) == 40_000)
    }

    @Test func aClipThatSaysNoTimePlaysAtTheStandIn() throws {
        // Zero delays play at 100 ms each, as every browser plays them.
        let clip = try schedule([0, 0, 0])
        #expect(clip.frames.map(\.source) == [0, 1, 2])
        #expect(total(clip) == 300)
    }

    @Test func aLongHeldFrameStaysOneFrame() throws {
        let clip = try schedule([5, 0.1])
        #expect(clip.frames.map(\.source) == [0, 1])
        #expect(clip.frames.map(\.milliseconds) == [5016, 84], "the sample that straddles the change shows the frame it starts in")
    }

    @Test func aStillOrAnEndlessClipHasNoSchedule() {
        #expect(FrameSchedule(delays: [0.1]) == nil)
        #expect(FrameSchedule(delays: []) == nil)
        #expect(FrameSchedule(delays: [Double](repeating: 0.1, count: ChatAnimation.maxSourceFrames + 1)) == nil)
    }
}
