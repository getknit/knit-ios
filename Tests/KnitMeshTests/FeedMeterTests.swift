import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// A feed's ETA, stall and deadline, from the receiver's progress reports or, before them, the pace (knit-next ADR
/// 2026-10.nsr7): `FeedMeterTest` at `8dc60836`, case for case.
@Suite struct FeedMeterTests {
    private static let mib: Int64 = 1 << 20
    private let key = BlobHash(of: Array("k".utf8))
    private let next = BlobHash(of: Array("next".utf8))

    /// A meter with no sample floor, as the Kotlin's arithmetic cases have: they report a second or less apart.
    private func streaming(offset: Int64 = 0, length: Int64 = mib, minSample: Int64 = 0) -> FeedMeter {
        var meter = FeedMeter(minSample: minSample)
        meter.start(key, now: 0)
        meter.sized(offset: offset, length: length)
        return meter
    }

    @Test func beforeAnyReportTheEtaIsThePacesAndTheDeadlineWaitsOutTheFirstReport() {
        var meter = streaming()
        let early = meter.reading(left: Self.mib / 2, wroteAt: 0, pace: 4096, settled: true, now: 0)
        #expect(early.etaMilliseconds == 128_000, "half a MiB left at 4 KiB/s")
        #expect(!early.measured && early.live)
        // Settled, but a first report may still come: no deadline from the pace until the stall window has passed.
        var now = FeedMeter.stallMilliseconds
        _ = meter.reading(left: Self.mib / 2, wroteAt: now, pace: 4096, settled: true, now: now)
        now += 190_000
        let read1 = meter.reading(left: Self.mib / 2, wroteAt: now, pace: 4096, settled: true, now: now)
        #expect(read1.live, "inside the deadline")
        now += 1
        #expect(!meter.reading(left: Self.mib / 2, wroteAt: now, pace: 4096, settled: true, now: now).live, "past it")
    }

    @Test func aStreamWithNoReportYetStallsWhenItsWritesStop() {
        var meter = streaming()
        let read2 = meter.reading(left: Self.mib, wroteAt: 0, pace: 4096, settled: false, now: FeedMeter.stallMilliseconds)
        #expect(read2.live)
        let stalled = meter.reading(left: Self.mib, wroteAt: 0, pace: 4096, settled: false, now: FeedMeter.stallMilliseconds + 1)
        #expect(!stalled.live, "no write went through for the stall window")
    }

    @Test func reportsMeasureTheRateByTheReceiversClockAndSetTheDeadlineOnce() {
        var meter = streaming(offset: 1000, length: 1_000_000)
        meter.paced(200_000)
        let stale = meter.report(next, held: 500_000, milliseconds: 1000, now: 0)
        #expect(!stale, "another key's report is stale")
        // The report waited on the way back: the rate is still by the receiver's clock.
        var now: Int64 = 9999
        let ours = meter.report(key, held: 101_000, milliseconds: 1000, now: now)
        #expect(ours)
        let measured = meter.reading(left: 0, wroteAt: now, pace: 200_000, settled: true, now: now)
        #expect(measured.measured && measured.etaMilliseconds == 9000, "900 kB left at 100 kB/s")
        let read3 = meter.reading(left: 0, wroteAt: now, pace: 200_000, settled: true, now: now + 1000)
        #expect(read3.etaMilliseconds == 8000, "it drained since")
        // The deadline was set at the first measurement: 9 s × 5/4 + 30 s past 9 999.
        now = 9999 + 11_250 + FeedMeter.deadlineSlackMilliseconds
        _ = meter.report(key, held: 900_000, milliseconds: 6000, now: now)
        let read4 = meter.reading(left: 0, wroteAt: now, pace: 200_000, settled: true, now: now)
        #expect(read4.live)
        now += 1
        _ = meter.report(key, held: 950_000, milliseconds: 7000, now: now)
        #expect(!meter.reading(left: 0, wroteAt: now, pace: 200_000, settled: true, now: now).live, "past the deadline, moving or not")
        // Two reports after the pace was set, the third's window ran at one pace: 50 kB/s of 200 kB/s.
        meter.end()
        #expect(abs(meter.drainRatio - 0.25) < 1e-9, "it drained well under its pace: the link keeps the shortfall")
    }

    @Test func aDeadlineMovesBackWhenTheSendersOwnSplitCutsThePace() {
        var meter = streaming(length: 1_000_000)
        _ = meter.report(key, held: 100_000, milliseconds: 1000, now: 0)
        _ = meter.reading(left: 0, wroteAt: 0, pace: 100_000, settled: true, now: 0)
        _ = meter.report(key, held: 150_000, milliseconds: 31_000, now: 30_000)
        // A second feed started on another link: the pace halved, and the rest now takes 850 kB / 50 kB/s = 17 s at best.
        _ = meter.reading(left: 0, wroteAt: 30_000, pace: 50_000, settled: true, now: 30_000)
        let now = 30_000 + 17_000 * 5 / 4 + FeedMeter.deadlineSlackMilliseconds
        _ = meter.report(key, held: 500_000, milliseconds: 70_000, now: now)
        let read5 = meter.reading(left: 0, wroteAt: now, pace: 50_000, settled: true, now: now)
        #expect(read5.live, "the deadline moved back with the pace")
    }

    @Test func timeTheWriterSleptThroughItsOwnPaceWaitIsNeitherAStallNorLate() {
        var meter = streaming(length: 100_000)
        _ = meter.report(key, held: 10_000, milliseconds: 1000, now: 0)
        _ = meter.reading(left: 0, wroteAt: 0, pace: 10_000, settled: true, now: 0)
        meter.pausing(2000, now: 0)
        // The app slept through the writer's 2 s pace wait.
        var now: Int64 = 60_000
        let read6 = meter.reading(left: 0, wroteAt: 0, pace: 10_000, settled: true, now: now)
        #expect(read6.live, "still asleep in its own wait")
        meter.resumed(now: now)
        let read7 = meter.reading(left: 0, wroteAt: 0, pace: 10_000, settled: true, now: now)
        #expect(read7.live, "woken, the sleep counts for neither")
        now += FeedMeter.stallMilliseconds - 2000
        let read8 = meter.reading(left: 0, wroteAt: 0, pace: 10_000, settled: true, now: now)
        #expect(read8.live)
        now += 1
        #expect(!meter.reading(left: 0, wroteAt: 0, pace: 10_000, settled: true, now: now).live, "15 s awake with no report moving")
    }

    @Test func aReceiverThatStopsReadingStallsWhileTheWriterPacesNormally() {
        var meter = streaming()
        _ = meter.report(key, held: 100_000, milliseconds: 1000, now: 0)
        // 2 s chunk cycles: almost all of each in the writer's own wait, none of it slept.
        var now: Int64 = 0
        for _ in 0..<8 {
            meter.pausing(1990, now: now)
            now += 1990
            meter.resumed(now: now)
            now += 10
        }
        #expect(!meter.reading(left: 0, wroteAt: now, pace: 4096, settled: true, now: now).live, "no report moved for 16 s")
    }

    @Test func aShortfallIsReadOnlyFromReportsAtOnePaceWithTheWriterAwake() {
        var meter = streaming(length: 10_000_000)
        meter.paced(10_000)
        var held: Int64 = 0
        var milliseconds: Int64 = 0
        var now: Int64 = 0
        func report(_ rate: Int64) {
            held += rate * 2
            milliseconds += 2000
            _ = meter.report(key, held: held, milliseconds: milliseconds, now: now)
        }
        for _ in 0..<4 {
            report(10_000)
        }
        // Another feed ended: the pace doubled, and the next reports' windows still carry the old one.
        meter.paced(20_000)
        report(12_000)
        report(15_000)
        meter.pausing(2000, now: now)
        now += 30_000
        // A sleep: the next two reports' windows hold it.
        meter.resumed(now: now)
        report(3000)
        report(19_000)
        report(20_000)
        meter.end()
        #expect(meter.drainRatio == 1, "no window read at one pace fell short")
    }

    @Test func aStreamIsJudgedByItsWritesUntilItsFirstReportThenByItsReports() {
        var meter = streaming()
        _ = meter.report(key, held: 100_000, milliseconds: 1000, now: 0)
        // A report, but nothing more held.
        _ = meter.report(key, held: 100_000, milliseconds: 3000, now: FeedMeter.stallMilliseconds)
        var now = FeedMeter.stallMilliseconds + 1
        #expect(!meter.reading(left: 0, wroteAt: now, pace: 4096, settled: true, now: now).live, "only the report counts")
        meter.end()
        // Queued behind the last one's tail, it cannot be reported yet: its writes count.
        meter.start(next, now: now)
        meter.sized(offset: 0, length: Self.mib)
        now += FeedMeter.stallMilliseconds + 1
        let read9 = meter.reading(left: Self.mib, wroteAt: now, pace: 4096, settled: false, now: now)
        #expect(read9.live, "still writing")
        let idle = now - FeedMeter.stallMilliseconds - 1
        #expect(!meter.reading(left: Self.mib, wroteAt: idle, pace: 4096, settled: false, now: now).live, "not writing either")
    }

    @Test func aRateMeasuredBeforeThePaceSettledYieldsToTheFasterPaceAndToANewPace() {
        var meter = streaming(length: 2_000_000)
        meter.paced(2000)
        _ = meter.report(key, held: 4000, milliseconds: 2000, now: 0)
        let read10 = meter.reading(left: 0, wroteAt: 0, pace: 20_000, settled: false, now: 0)
        #expect(read10.etaMilliseconds == 99_800, "unsettled: the pace")
        let read11 = meter.reading(left: 0, wroteAt: 0, pace: 2000, settled: true, now: 0)
        #expect(read11.etaMilliseconds == 998_000, "settled: the rate")
        meter.paced(20_000)
        let read12 = meter.reading(left: 0, wroteAt: 0, pace: 20_000, settled: true, now: 0)
        #expect(read12.etaMilliseconds == 99_800, "the new pace")
        // Its window spans the change: it only rebases.
        _ = meter.report(key, held: 34_000, milliseconds: 4000, now: 0)
        #expect(!meter.reading(left: 0, wroteAt: 0, pace: 20_000, settled: true, now: 0).measured)
        _ = meter.report(key, held: 74_000, milliseconds: 6000, now: 0)
        let read13 = meter.reading(left: 0, wroteAt: 0, pace: 20_000, settled: true, now: 0)
        #expect(read13.etaMilliseconds == 96_300)
    }

    @Test func aMeterSamplesAboutEveryTwoSecondsHoweverOftenTheReceiverReports() {
        // A windowed sender's receiver reports on every chunk, and a reader catching up a burst reports bytes ms apart.
        var meter = streaming(minSample: FeedMeter.minSampleMilliseconds)
        meter.paced(8192)
        _ = meter.report(key, held: 4096, milliseconds: 250, now: 0)
        _ = meter.report(key, held: 1_000_000, milliseconds: 253, now: 0)
        #expect(!meter.measured, "no sample yet")
        _ = meter.report(key, held: 1_016_384, milliseconds: FeedMeter.minSampleMilliseconds, now: 0)
        #expect(meter.measured)
        let eta = meter.reading(left: 0, wroteAt: 0, pace: 8192, settled: true, now: 0).etaMilliseconds
        #expect(eta == (Self.mib - 1_016_384) * 1000 / 508_192, "one sample over two seconds")
    }
}
