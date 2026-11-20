import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Two full stores at the cap linked for fifty lab minutes, the twin of Android's lab scenario (the `custody-carry-policy`
/// contract, §5 to §7 and §9): over a ``LinkPipe``, whose link managers skip what crossed, for several seeded fills. What
/// must hold in every schedule:
/// - no frame crosses to the same peer twice inside one lapse, and every frame kept is a first crossing or a re-crossing
///   at least a lapse after its last;
/// - no later lapse sets more not-kept marks than the first did;
/// - each node's offers follow §7's ladder exactly: 60, 120, 240, 480, then 600 s, back to 60 s once custody kept any frame
///   from the other, whatever brought it. Android saw, in one schedule of twenty, gaps drop back to 60 s after a kept
///   frame; here half the seeds do, some through a first crossing of a row the other's keep had evicted.
@Suite struct LinkPipeCustodyFullStoresTests {
    private typealias Rig = LinkPipeCustodyCarryTests

    /// How long the two stay linked.
    private static let linked: Int64 = 50 * 60_000
    /// The lab's step. An offer and a keep in one step are told apart by the order a step runs in: its timers, the offer
    /// among them, then the pipe's pump, which delivers what custody keeps.
    private static let step: Int64 = 500
    /// §7's ladder, the gap after an offer that is the `n`th since the last draw.
    private static let ladder: [Int64] = [60_000, 120_000, 240_000, 480_000, 600_000]
    /// The fewest offers fifty minutes allow, the link-up digest's included: a first gap of at most 90 s, then the ladder with
    /// no draw, 120 to 600 s, all inside 3,000 s (90 + 120 + 240 + 480 + 600 + 600 + 600 = 2,730).
    private static let fewestOffers = 8

    /// One run: the two nodes, their pipe, each node's trace, and when the link came up.
    private struct Run {
        var nodes: [PipeNode]
        var pipe: LinkPipe
        var traces: [Trace]
        var start: Int64
        /// The wall clock at the end.
        var wall: Int64
    }

    /// What one node did over the run.
    ///
    /// Its keeps are read from the pipe and the store: a frame that crossed from the other in a step and that custody holds
    /// after the step though it did not before. The engine's own re-offer flag, sampled after each step, is no oracle for
    /// them: an offer clears it and a keep in the same step sets it again, so the sample reads true before and after and the
    /// keep goes unseen, as it did at 1,019 s in seeds 2 and 4.
    private struct Trace {
        /// When each of its digests to the other crossed.
        var digests: [Int64] = []
        /// Each frame it kept from the other.
        var keptFrames: [KeptFrame] = []
        /// Its not-kept marks so far, at each step.
        var marks: [(at: Int64, count: Int)] = []
    }

    /// A frame kept from the other node.
    private struct KeptFrame {
        /// The step it was kept in, after that step's offer, if one went.
        var at: Int64
        var id: String
        /// When it last crossed to this node before, if it had.
        var crossedBefore: Int64?
    }

    @Test(arguments: UInt64(1)...6)
    func twoFullStoresLinkedForFiftyMinutesHoldTheLapseTheMarksAndTheBackOff(seed: UInt64) throws {
        let run = try Self.run(seed: seed)
        let report = Self.report(run.traces, start: run.start)
        // (a) No frame crosses to the same peer twice inside one lapse, the link's duplicate skip and the memo together.
        for node in run.nodes {
            var last: [String: Int64] = [:]
            for frame in run.pipe.frames where frame.from == node.nodeId {
                if let before = last[frame.id] {
                    #expect(frame.at - before >= CarryLedger.notKeptLapseMilliseconds, "\(frame.id) again after \(frame.at - before) ms")
                }
                last[frame.id] = frame.at
            }
        }
        let wall = run.wall
        for (index, trace) in run.traces.enumerated() {
            let label = "node \(index): \(report)"
            #expect(run.nodes[index].stores.custody.liveIds(now: wall).count == 60, "still full at the end; \(label)")
            // (b) The first lapse marks some, and no later lapse sets more.
            let windows = Self.marksByLapse(trace.marks, start: run.start)
            #expect(windows[0] > 0, "\(label)")
            #expect(windows.dropFirst().allSatisfy { $0 <= windows[0] }, "marks by lapse \(windows); \(label)")
            // (a) seen from the keep side: a first crossing, or a re-crossing a lapse at least after the last.
            for kept in trace.keptFrames {
                let since = kept.crossedBefore.map { kept.at - $0 }
                #expect(since.map { $0 >= CarryLedger.notKeptLapseMilliseconds } ?? true, "\(kept.id) kept \(since ?? 0) ms on; \(label)")
            }
            Self.expectLadder(trace, end: run.start + Self.linked, label: label)
        }
    }

    /// (c) The offers replayed against §7's ladder, a draw being any frame kept from the other.
    private static func expectLadder(_ trace: Trace, end: Int64, label: String) {
        let times = trace.digests
        let kept = trace.keptFrames.map(\.at)
        #expect(times.count >= fewestOffers, "\(times.count) offers; \(label)")
        guard times.count >= 2 else {
            return
        }
        // Kept in [from, to): after the offer at `from`, which ran first in its step, and before the one at `to`.
        func keptIn(_ from: Int64, _ to: Int64) -> Int64? {
            kept.first { $0 >= from && $0 < to }
        }
        #expect((30_000...90_000).contains(times[1] - times[0]), "first gap \(times[1] - times[0]) ms; \(label)")
        var sinceDraw = 0
        for gap in 1..<(times.count - 1) {
            let next = times[gap + 1] - times[gap]
            if keptIn(times[gap - 1], times[gap]) != nil {
                // The offer at `gap` judged a draw: the base.
                sinceDraw = 0
                #expect(abs(next - ladder[0]) <= 1000, "a draw before \(gap), then \(next) ms; \(label)")
            } else if let first = keptIn(times[gap], times[gap + 1]) {
                // A keep reset the interval at once, mid-wait: the next tick after it.
                sinceDraw += 1
                #expect(next <= first - times[gap] + ladder[0] + 1000, "a keep mid-wait, then \(next) ms; \(label)")
            } else {
                sinceDraw += 1
                let rung = ladder[min(sinceDraw, ladder.count - 1)]
                #expect(abs(next - rung) <= 1000, "offer \(gap), \(sinceDraw) since a draw: \(next) ms, not \(rung); \(label)")
            }
        }
        // With no keep after the last, and time for the whole ladder, the tail ends in 600 s gaps.
        let quiet = kept.last ?? times[0]
        if end - quiet > ladder.reduce(0, +) + ladder[ladder.count - 1] {
            let last = times[times.count - 1] - times[times.count - 2]
            #expect(abs(last - ladder[ladder.count - 1]) <= 1000, "the tail ends at \(last) ms; \(label)")
        }
    }

    /// One seeded run: two stores of 60 each filled from the same 100 frames, linked for fifty lab minutes, each node's
    /// trace read after every step, the link-up's own crossings included.
    private static func run(seed: UInt64) throws -> Run {
        let limits = CustodyLimits(maxFrames: 60)
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let nodes = [lab.node(1, custodyLimits: limits), lab.node(2, custodyLimits: limits)]
        for node in nodes {
            Rig.pin(Rig.senders, on: node)
        }
        let all = try Rig.dms(100, to: TestPeer(seed: 999), label: "full-\(seed)", sentAt: wall - 600_000, body: 100)
        var random = SeededGenerator(seed: seed)
        for node in nodes {
            Rig.seed(node, with: all.filter { _ in Int.random(in: 0..<10, using: &random) < 7 })
        }
        #expect(nodes.allSatisfy { $0.stores.custody.liveIds(now: wall).count == limits.maxFrames })
        Rig.settle(lab)
        var held = nodes.map { Set($0.stores.custody.liveIds(now: lab.clock.wallMilliseconds())) }
        let pipe = lab.link(nodes[0], nodes[1])
        let start = lab.clock.monotonicMilliseconds()
        var traces = [Trace(), Trace()]
        var crossings: [[String: Int64]] = [[:], [:]]
        var read = 0
        while true {
            let now = lab.clock.monotonicMilliseconds()
            let crossed = pipe.frames.dropFirst(read)
            read = pipe.frames.count
            for index in 0..<2 {
                let after = Set(nodes[index].stores.custody.liveIds(now: lab.clock.wallMilliseconds()))
                for frame in crossed where frame.to == nodes[index].nodeId {
                    if after.contains(frame.id), !held[index].contains(frame.id) {
                        traces[index].keptFrames.append(KeptFrame(at: now, id: frame.id, crossedBefore: crossings[index][frame.id]))
                    }
                    crossings[index][frame.id] = frame.at
                }
                held[index] = after
                traces[index].marks.append((now, nodes[index].engine.custodyRoundCounts.custodyNotKept))
            }
            guard now < start + linked else {
                break
            }
            lab.run(step: step, limit: step) { false }
        }
        for index in 0..<2 {
            traces[index].digests = pipe.digests.filter { $0.from == nodes[index].nodeId }.map(\.at)
        }
        return Run(nodes: nodes, pipe: pipe, traces: traces, start: start, wall: lab.clock.wallMilliseconds())
    }

    /// Each node's increments of `custodyNotKept` in each lapse from `start`, the first window first.
    private static func marksByLapse(_ marks: [(at: Int64, count: Int)], start: Int64) -> [Int] {
        var windows: [Int] = []
        var before = 0
        for (at, count) in marks {
            let window = Int((at - start) / CarryLedger.notKeptLapseMilliseconds)
            while windows.count <= window {
                windows.append(0)
            }
            windows[window] += count - before
            before = count
        }
        return windows
    }

    /// The timeline to hand back: each node's digest gaps in seconds, when it kept a frame from the other (`*` a first
    /// crossing), and its marks by lapse.
    private static func report(_ traces: [Trace], start: Int64) -> String {
        traces.enumerated().map { index, trace in
            let gaps = zip(trace.digests.dropFirst(), trace.digests).map { ($0 - $1) / 1000 }
            let kept = trace.keptFrames.map { "\(($0.at - start) / 1000)\($0.crossedBefore == nil ? "*" : "")" }
            return "node \(index) gaps \(gaps) kept at \(kept) marks by lapse \(marksByLapse(trace.marks, start: start))"
        }.joined(separator: "; ")
    }
}
