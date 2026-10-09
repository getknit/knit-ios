import Testing

@testable import KnitMesh

/// The window's rules one report at a time, and the paced fallback's arithmetic (knit-next ADRs 2026-10.5buf and
/// 2026-10.8jwn). Ported from knit-next's `FeedWindowTest` and `CodedPhyPolicyTest`, their bounds unchanged; the Coded
/// cases, the PHY step and the resume are Android's alone (ADR 2026-10.xwjc says why). ``FeedWindowSimTests`` runs the
/// window on a simulated link.
@Suite struct FeedWindowTests {
    /// A windowed feed's paced fallback at the 4 KiB/s base, in the pace's 8 KiB chunks.
    private let basePace = FilePace(budget: 4096, feeding: 1, maxChunkBytes: 16_384)

    private func fresh() -> FeedWindow {
        var window = FeedWindow(maxChunkBytes: 16_384)
        window.start(now: 0)
        return window
    }

    // MARK: The window's rules

    @Test func beforeTheFirstReportOnlyTheStartingWindowGoes() {
        var window = fresh()
        window.wrote(4096, now: 0)
        #expect(window.waitMilliseconds == 0)
        window.wrote(4096, now: 0)
        #expect(window.waitMilliseconds == FeedWindow.reportWaitMilliseconds, "the starting window is full: wait for a report")
        #expect(!window.pacing(now: FeedWindow.noReportMilliseconds - 1))
        #expect(window.pacing(now: FeedWindow.noReportMilliseconds), "a receiver silent this long gets the pace")
    }

    @Test func theWritersOwnSleepCountsTowardTheSilenceOnlyWhenNothingWasOwed() {
        var window = fresh()
        window.wrote(8192, now: 0)
        window.slept(10_000, now: 10_100)
        #expect(window.pacing(now: 10_100), "a window out: the receiver owes a report, so its silence counts")
        window.report(held: 8192, milliseconds: 500, now: 13_200)
        window.slept(10_000, now: 23_300)
        #expect(!window.pacing(now: 23_300), "nothing out: nothing was owed, so the sleep does not count")
        #expect(window.pacing(now: 23_200 + FeedWindow.noReportMilliseconds))
    }

    @Test func aReceiverThatReportsEveryTwoSecondsIsPacedForTheRestOfTheStream() {
        var window = fresh()
        for _ in 0..<6 { window.wrote(2048, now: 0) }
        window.report(held: 4096, milliseconds: 2000, now: 2100)
        window.report(held: 8192, milliseconds: 4000, now: 4100)
        #expect(!window.pacing(now: 4100))
        window.report(held: 12_288, milliseconds: 6000, now: 6100)
        #expect(window.pacing(now: 6100), "two two-second gaps of several chunks: paced")
        window.report(held: 12_288, milliseconds: 6100, now: 6200)
        #expect(window.pacing(now: 6200), "for the rest of the stream")
        window.start(now: 7000)
        #expect(!window.pacing(now: 7000), "a new stream asks again")
    }

    /// Two seconds apart, two chunks a report: taken for a two-second reporter at 6.1 s.
    private func latched() -> FeedWindow {
        var window = fresh()
        for _ in 0..<6 { window.wrote(2048, now: 0) }
        window.report(held: 4096, milliseconds: 2000, now: 2100)
        window.report(held: 8192, milliseconds: 4000, now: 4100)
        window.report(held: 12_288, milliseconds: 6000, now: 6100)
        return window
    }

    @Test func aDozingReceiverWokenMidFileGetsItsWindowBack() {
        // The D2 run of 2026-10-08: a dozing P9 was taken for a two-second reporter; woken, it reports each small paced
        // chunk inside the gap, and three in a row give the window back.
        var window = latched()
        #expect(window.pacing(now: 6100))
        #expect(window.pacedChunkBytes(basePace) == FeedWindow.minChunkBytes, "paced in the smallest chunks")
        for index in 0..<4 { window.wrote(2048, now: 6200 + Int64(index) * 500) }
        window.report(held: 14_336, milliseconds: 6500, now: 6600)
        window.report(held: 16_384, milliseconds: 7000, now: 7100)
        #expect(window.pacing(now: 7100), "two on time are not yet three")
        window.report(held: 18_432, milliseconds: 7500, now: 7600)
        #expect(!window.pacing(now: 7600), "three chunks answered on time: windowed again")
        #expect(window.pacedChunkBytes(basePace) == 8192, "and its chunks are the pace's own again")
    }

    @Test func aDozingReceiverWorkingThroughItsBacklogDoesNotWinTheWindowBack() {
        var window = latched()
        // Paced: 2 KiB every half second, so a report under a quarter second after the last is a burst.
        _ = window.pacedChunkBytes(basePace)
        for _ in 0..<4 { window.wrote(2048, now: 6200) }
        window.report(held: 14_336, milliseconds: 8000, now: 8100)
        window.report(held: 16_384, milliseconds: 8005, now: 8100)
        window.report(held: 18_432, milliseconds: 8010, now: 8100)
        window.report(held: 20_480, milliseconds: 8015, now: 8100)
        #expect(window.pacing(now: 8100), "a backlog read at once: still paced")
    }

    @Test func theWindowsChunksStillOutWhenTheFeedIsPacedAreNoAnswer() {
        var window = fresh()
        for _ in 0..<10 { window.wrote(2048, now: 0) }
        window.report(held: 4096, milliseconds: 2000, now: 2100)
        window.report(held: 8192, milliseconds: 4000, now: 4100)
        window.report(held: 12_288, milliseconds: 6000, now: 6100)
        #expect(window.pacing(now: 6100))
        window.report(held: 14_336, milliseconds: 6001, now: 6100)
        window.report(held: 16_384, milliseconds: 6002, now: 6100)
        window.report(held: 18_432, milliseconds: 6003, now: 6100)
        window.report(held: 20_480, milliseconds: 6004, now: 6100)
        #expect(window.pacing(now: 6100), "the window's own chunks, read at once: still paced")
    }

    @Test func aReportThatProvesNoNewChunkIsNotOnTime() {
        var window = latched()
        window.report(held: 12_288, milliseconds: 6500, now: 6600)
        window.report(held: 12_288, milliseconds: 7000, now: 7100)
        window.report(held: 12_288, milliseconds: 7500, now: 7600)
        #expect(window.pacing(now: 7600), "three reports holding nothing new: still paced")
    }

    @Test func aTwoSecondReporterStaysPacedInSmallChunks() {
        var window = fresh()
        var held: Int64 = 0
        for index in Int64(1)...10 {
            for _ in 0..<4 { window.wrote(2048, now: index * 2000 - 1500) }
            held += 4 * 2048
            window.report(held: held, milliseconds: index * 2000, now: index * 2000 + 100)
        }
        #expect(window.pacing(now: 20_100), "still paced after ten reports")
    }

    @Test func anOnTimeRunBrokenByALateReportStartsOver() {
        var window = latched()
        for _ in 0..<6 { window.wrote(2048, now: 6200) }
        window.report(held: 14_336, milliseconds: 6500, now: 6600)
        window.report(held: 16_384, milliseconds: 7000, now: 7100)
        // A late catch-up of two chunks.
        window.report(held: 20_480, milliseconds: 9000, now: 9100)
        window.report(held: 22_528, milliseconds: 9500, now: 9600)
        window.report(held: 24_576, milliseconds: 10_000, now: 10_100)
        #expect(window.pacing(now: 10_100), "the run counts again from the late one")
    }

    @Test func aWindowedReceiverOnASlowLinkIsNotTakenForATwoSecondReporter() {
        var window = fresh()
        for _ in 0..<4 { window.wrote(2048, now: 0) }
        window.report(held: 2048, milliseconds: 2000, now: 2100)
        window.report(held: 4096, milliseconds: 4000, now: 4100)
        window.report(held: 6144, milliseconds: 6000, now: 6100)
        window.report(held: 8192, milliseconds: 8000, now: 8100)
        #expect(!window.pacing(now: 8100), "one chunk a report: a windowed receiver")
    }

    @Test func theRoundTripIsTheLinksAndOutlivesTheStream() {
        // A file fed in full leaves its tail in the radio's buffer, and the next stream's first chunk waits behind it:
        // taken fresh each stream, the estimate grew with every file sent back to back.
        var window = fresh()
        window.wrote(4096, now: 0)
        window.report(held: 4096, milliseconds: 400, now: 400)
        #expect(window.roundTripMilliseconds == 400)
        window.start(now: 1000)
        window.wrote(4096, now: 1000)
        // Behind the last file's tail.
        window.report(held: 4096, milliseconds: 1000, now: 2200)
        #expect(window.roundTripMilliseconds == 400, "the link's round trip, not the queue the last file left")
    }

    @Test func aChunkBehindItsWindowIsNotReadAsALinkThatSlowed() {
        var window = fresh()
        window.wrote(2048, now: 0)
        // A fast file: round trip 60 ms.
        window.report(held: 2048, milliseconds: 60, now: 60)
        window.start(now: 1000)
        window.wrote(2048, now: 1000)
        window.wrote(2048, now: 1000)
        // 5 KB/s.
        window.report(held: 2048, milliseconds: 400, now: 1400)
        let rate = window.rate
        // The second, 900 ms after its write: its 2 KiB ahead at 5 KB/s.
        window.report(held: 4096, milliseconds: 900, now: 1900)
        #expect(window.rate == rate, "the larger sample stands: no slowdown")
    }

    @Test func aSampleClampedToTheCeilingDoesNotRefreshTheEstimatesAge() {
        var window = fresh()
        window.wrote(4096, now: 0)
        // 5 s: stored as the 3 s ceiling.
        window.report(held: 4096, milliseconds: 5000, now: 5000)
        #expect(window.roundTripMilliseconds == FeedWindow.maxRoundTripMilliseconds)
        window.wrote(4096, now: 5000)
        // 10.1 s: also the ceiling, and no smaller than the 5 s.
        window.report(held: 8192, milliseconds: 15_100, now: 15_100)
        #expect(window.probingRoundTrip, "its age ran from the first: the probe is due")
    }

    @Test func aProbeTakesTheRoundTripOfAChunkSentUnderItsOneChunkWindow() {
        var window = fresh()
        window.wrote(4096, now: 0)
        window.report(held: 4096, milliseconds: 400, now: 400)
        window.wrote(8192, now: 400)
        // Nothing smaller for ten seconds: probe.
        window.report(held: 6144, milliseconds: 11_000, now: 11_000)
        #expect(window.probingRoundTrip)
        #expect(window.target == Int64(FeedWindow.minChunkBytes) + 1, "room for one smallest chunk")
        #expect(window.waitMilliseconds == FeedWindow.reportWaitMilliseconds, "6 KiB still out: wait")
        window.report(held: 12_288, milliseconds: 11_400, now: 11_400)
        #expect(window.waitMilliseconds == 0)
        window.wrote(2048, now: 11_400)
        window.report(held: 14_336, milliseconds: 12_100, now: 12_100)
        #expect(!window.probingRoundTrip, "its round trip ends the probe")
        #expect(window.roundTripMilliseconds == 700, "and is the trip, though larger than the old one")
    }

    @Test func aReportOfMoreThanWasWrittenOrFasterThanTheCeilingProvesNoMore() {
        var window = fresh()
        window.wrote(65_536, now: 0)
        window.report(held: 10_000_000, milliseconds: 500, now: 600)
        #expect(window.queued == 0, "held to what was written")
        #expect(window.rate == FeedWindow.ceilingBytesPerSecond, "and the rate to the ceiling")
        #expect(window.roundTripMilliseconds == 600, "the round trip, write to report")
        #expect(window.target == 65_536 * (600 + FeedWindow.queueMilliseconds) / 1000, "the rate over the round trip and the queue")
    }

    @Test func aBurstReadBackToBackMovesTheQueueButTakesNoSample() {
        var window = fresh()
        window.wrote(24_576, now: 0)
        // 8 KiB/s.
        window.report(held: 8192, milliseconds: 1000, now: 1000)
        window.report(held: 16_384, milliseconds: 1003, now: 1005)
        #expect(window.rate == 8192, "not 2.7 MB/s")
        #expect(window.queued == 8192, "but the queue knows what landed")
        // Measured from the last sample: 12 KiB over 500 ms.
        window.report(held: 20_480, milliseconds: 1500, now: 1500)
        #expect(window.rate == 24_576)
    }

    @Test func anOlderReportMovesNothing() {
        var window = fresh()
        window.wrote(16_384, now: 0)
        window.report(held: 8192, milliseconds: 1000, now: 1000)
        let rate = window.rate
        // Reordered.
        window.report(held: 4096, milliseconds: 500, now: 1100)
        #expect(window.rate == rate)
        #expect(window.queued == 8192)
    }

    @Test func withNoReportNothingFreesTheWindowWhateverTheClock() {
        var window = fresh()
        window.wrote(8192, now: 0)
        window.report(held: 4096, milliseconds: 500, now: 500)
        window.wrote(32_768, now: 500)
        #expect(window.queued == 36_864)
        #expect(window.waitMilliseconds == FeedWindow.reportWaitMilliseconds)
    }

    @Test func aQueuedChunksRoundTripCanOnlyLowerTheEstimate() {
        var window = fresh()
        window.wrote(4096, now: 0)
        // 10 KB/s, round trip 400 ms.
        window.report(held: 4096, milliseconds: 400, now: 400)
        #expect(window.roundTripMilliseconds == 400)
        // Well past the rate over the round trip: a queue stands ahead of the next chunk.
        window.wrote(16_384, now: 400)
        window.wrote(2048, now: 400)
        window.report(held: 22_528, milliseconds: 2400, now: 2400)
        #expect(window.roundTripMilliseconds == 400, "a queued chunk's 2 s is not the air's round trip")
    }

    @Test func chunksCarryAQuarterSecondOfTheRateWithinTheirBounds() {
        var window = fresh()
        #expect(window.chunkBytes == FeedWindow.initialChunkBytes)
        window.wrote(8192, now: 0)
        // 4 KB/s.
        window.report(held: 2000, milliseconds: 500, now: 500)
        #expect(window.chunkBytes == FeedWindow.minChunkBytes)
        window.wrote(32_768, now: 500)
        // 77 KB/s, held to the 64 KiB/s ceiling.
        window.report(held: 40_960, milliseconds: 1000, now: 1000)
        #expect(window.chunkBytes == 16 * 1024)
    }

    @Test func oneLowSampleCannotHoldASilentReceiverUnpacedForLong() {
        // A link that nearly stalled for a moment can leave one sample of 100 B/s as the whole filter: three of its
        // chunks' time would be a minute, with a receiver whose reports stopped.
        var window = fresh()
        for _ in 0..<8 { window.wrote(2048, now: 0) }
        window.report(held: 100, milliseconds: 1000, now: 1000)
        #expect(window.rate == 100)
        #expect(window.pacing(now: 1000 + 3 * FeedWindow.maxChunkCrossingMilliseconds), "paced within three of the longest crossing")
    }

    @Test func at1mDrainsTheSilenceAndTheTwoSecondGapAreTheConstants() {
        var window = fresh()
        for _ in 0..<8 { window.wrote(2048, now: 0) }
        // 2 KB/s: three 2 KiB chunks are 3 s.
        window.report(held: 2048, milliseconds: 1000, now: 1100)
        #expect(window.pacing(now: 1100 + FeedWindow.noReportMilliseconds))
    }
}

/// The paced fallback's arithmetic (knit-next ADR 2026-10.8jwn, `CodedPhyPolicyTest`): one budget split among the links
/// feeding at the pace, in chunks of two seconds of a share.
@Suite struct FilePaceTests {
    private let basePace = FilePace(budget: 4096, feeding: 1, maxChunkBytes: 16_384)

    @Test func aLinkAloneIsFedFourKibPerSecondInEightKibChunks() {
        #expect(basePace == FilePace(budget: 4096, feeding: 1, maxChunkBytes: 16_384))
        #expect(basePace.bytesPerSecond == 4096 && basePace.chunkBytes == 8192)
        #expect(basePace.spacing(for: 8192) == 2000)
    }

    @Test func theBudgetIsSplitAmongTheLinksFeedingInChunksOfTwoSecondsOfAShare() {
        let two = FilePace(budget: 4096, feeding: 2, maxChunkBytes: 16_384)
        #expect(two.bytesPerSecond == 2048 && two.chunkBytes == 4096)
        let four = FilePace(budget: 4096, feeding: 4, maxChunkBytes: 16_384)
        #expect(four.bytesPerSecond == 1024 && four.chunkBytes == 2048, "never under the smallest chunk")
        let large = FilePace(budget: 28_672, feeding: 1, maxChunkBytes: 16_384)
        #expect(large.chunkBytes == 16_384, "never over a record")
        #expect(FilePace(budget: 4096, feeding: 0, maxChunkBytes: 16_384) == basePace, "a count under one is the link alone")
    }

    @Test func anUnboundedPaceStaysUnboundedInWholeChunks() {
        let unbounded = FilePace(budget: 0, feeding: 3, maxChunkBytes: 16_384)
        #expect(unbounded.bytesPerSecond == 0 && unbounded.chunkBytes == 16_384)
        #expect(unbounded.spacing(for: 16_384) == 0)
    }
}
