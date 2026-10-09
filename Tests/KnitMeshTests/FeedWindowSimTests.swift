import Testing

@testable import KnitMesh

/// A feed clocked by its receiver's reports keeps about a quarter second of the drain queued past the round trip, on any
/// link speed, and finds a faster link by itself (knit-next ADR 2026-10.5buf). The simulated link cases of knit-next's
/// `FeedWindowTest`, their bounds unchanged, on ``FeedWindowSim``.
@Suite struct FeedWindowSimTests {
    @Test func aSteadyDrainIsFoundAndTheQueueStaysNearHalfASecondOfIt() {
        let sim = FeedWindowSim(drain: 20_000)
        sim.run(until: 5000)
        sim.measure(from: 5000)
        let heldAt5 = sim.held
        sim.run(until: 15_000)
        #expect(abs(sim.window.rate - 20_000) <= 2000, "the rate is the drain: \(sim.window.rate)")
        let throughput = (sim.held - heldAt5) / 10
        #expect(throughput >= 19_000, "the air is kept busy: \(throughput) B/s of 20000")
        #expect(sim.maxQueueMilliseconds <= 1000, "a frame behind the file waits under a second: \(sim.maxQueueMilliseconds) ms")
    }

    @Test func aDarkSenderThatWritesOnlyWhenAReportWakesItStillKeepsTheAirBusy() {
        // Device rep 2026-10-07 P9→P8, both dark: a window refilled once a report capped the feed at window ÷ gap.
        let sim = FeedWindowSim(drain: 12_000, asleep: true)
        sim.run(until: 8000)
        let heldAt8 = sim.held
        sim.measure(from: 8000)
        sim.run(until: 20_000)
        let throughput = (sim.held - heldAt8) / 12
        #expect(throughput >= 10_800, "the air is kept busy: \(throughput) B/s of 12000")
        #expect(sim.maxQueueMilliseconds <= 1500, "a frame waits under about a second and a half: \(sim.maxQueueMilliseconds) ms")
    }

    @Test func aLongRoundTripIsCoveredByGrowingTheWindowNotByTheRateAlone() {
        // A dark pair at a 255 ms interval, reports a second in coming back.
        let sim = FeedWindowSim(drain: 6000, lag: 900, asleep: true)
        sim.run(until: 10_000)
        let heldAt10 = sim.held
        sim.run(until: 30_000)
        let throughput = (sim.held - heldAt10) / 20
        // Less the round trip's probe every ten seconds: a round at one chunk, about 12% at this round trip.
        #expect(throughput >= 5000, "the air is kept busy: \(throughput) B/s of 6000")
    }

    @Test func aRoundTripThatRisesMidFileIsFollowedUp() {
        // The link's interval stepped from 15 ms to 255 ms mid-file, and the reports' way back with it.
        let sim = FeedWindowSim(drain: 10_000, lag: 50, asleep: true)
        sim.run(until: 6000)
        sim.lag = 900
        sim.run(until: 12_000)
        let heldAt12 = sim.held
        sim.measure(from: 12_000)
        sim.run(until: 30_000)
        let throughput = sim.throughput(since: 12_000, heldThen: heldAt12)
        #expect(throughput >= 8000, "the air is kept busy, less the probe's dip: \(throughput) B/s of 10000")
        #expect(sim.maxQueueMilliseconds <= 1500, "and the queue stays short: \(sim.maxQueueMilliseconds) ms")
    }

    @Test(arguments: [10_000, 20_000, 6000] as [Int64])
    func aLitSenderToAReceiverWhoseReportsComeBackSlowlyGetsTheLink(drain: Int64) {
        // Device sweep 4: a window covering only the gap between reports got half the link.
        let sim = FeedWindowSim(drain: drain, lag: 900)
        sim.run(until: 10_000)
        let heldAt10 = sim.held
        sim.measure(from: 10_000)
        sim.run(until: 40_000)
        let throughput = sim.throughput(since: 10_000, heldThen: heldAt10)
        #expect(throughput >= drain * 85 / 100, "\(drain) B/s, 900 ms back: \(throughput) B/s")
        #expect(sim.maxQueueMilliseconds <= 2000, "\(drain) B/s: the queue stays short (\(sim.maxQueueMilliseconds) ms)")
    }

    @Test func aDipMidFileCostsOnlyTheDip() {
        let sim = FeedWindowSim(drain: 6000, lag: 900, asleep: true)
        sim.run(until: 10_000)
        sim.drain = 3000
        sim.run(until: 12_000)
        sim.drain = 6000
        sim.run(until: 20_000)
        let heldAt20 = sim.held
        sim.run(until: 40_000)
        let throughput = sim.throughput(since: 20_000, heldThen: heldAt20)
        #expect(throughput >= 5400, "back to the drain after the dip: \(throughput) B/s of 6000")
    }

    @Test func aSlowLinkKeepsItsQueueShortWhereAFixedPaceWouldFillIt() {
        // 8jwn's slowest measured 1M drain.
        let sim = FeedWindowSim(drain: 4800)
        sim.run(until: 5000)
        sim.measure(from: 5000)
        sim.run(until: 20_000)
        #expect(sim.maxQueueMilliseconds <= 2500, "the queue stays within a couple of seconds: \(sim.maxQueueMilliseconds) ms")
        #expect(sim.window.rate >= 4300, "and the air stays busy")
    }

    @Test func aFastLinkIsFoundFromTheSmallStartingWindow() {
        // The A/B's T8 cell drained a 341 KB photo in about 12 s; a fixed 4 KiB/s base took 111 s.
        let sim = FeedWindowSim(drain: 40_000)
        sim.run(until: 4000)
        #expect(sim.window.rate >= 36_000, "found within four seconds: \(sim.window.rate)")
        sim.measure(from: 4000)
        sim.run(until: 12_000)
        #expect(sim.held >= 341_000, "341 KB crosses in about 9 s")
        #expect(sim.maxQueueMilliseconds <= 1000, "still within a second: \(sim.maxQueueMilliseconds) ms")
    }

    @Test func aDrainThatFallsIsFollowedWithinAFewReports() {
        let sim = FeedWindowSim(drain: 25_000)
        sim.run(until: 8000)
        // A second link starts feeding: what was queued for the faster drain drains, and the window follows it down.
        sim.drain = 6000
        sim.run(until: 13_000)
        sim.measure(from: 13_000)
        sim.run(until: 22_000)
        #expect(sim.window.rate <= 7000, "followed down: \(sim.window.rate)")
        #expect(sim.maxQueueMilliseconds <= 2000, "its queue back within the slower drain's floor: \(sim.maxQueueMilliseconds) ms")
    }

    @Test func aLateReturnLeansSlowNeverFast() {
        // A report queued behind the receiver's own file: its lag overstates the queue, so the feed holds back.
        let sim = FeedWindowSim(drain: 20_000, lag: 900)
        sim.run(until: 5000)
        sim.measure(from: 5000)
        sim.run(until: 15_000)
        #expect(sim.maxQueueMilliseconds <= 2000, "about a second and a half: \(sim.maxQueueMilliseconds) ms")
        #expect(sim.window.rate >= 15_000, "and still most of the drain")
    }
}
