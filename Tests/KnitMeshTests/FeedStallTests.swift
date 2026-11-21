import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// A feed's stall read apart from its deadline (`FeedMeter.isStalled`, `LinkManager.isFileFeedStalled`; the
/// `custody-carry-policy` contract, revision 18, §2): only a file that is moving comes first, and one that still moves
/// keeps coming first past the blob plane's deadline for it. The read moves nothing in the meter, so custody's looks
/// every 100 ms leave the blob plane's `live` as it was.
@Suite struct FeedStallTests {
    private let key = BlobHash(of: Array("k".utf8))
    private let stall = FeedMeter.stallMilliseconds
    private let channel = ChannelID(130)

    /// A meter measured at 100 kB/s from its first report at 9 999 ms, which set its deadline 41 250 ms on, as
    /// ``FeedMeterTests``' third case has it.
    private func measured() -> (meter: FeedMeter, deadline: Int64) {
        var meter = FeedMeter(minSample: 0)
        meter.start(key, now: 0)
        meter.sized(offset: 1000, length: 1_000_000)
        meter.paced(200_000)
        _ = meter.report(key, held: 101_000, milliseconds: 1000, now: 9999)
        _ = meter.reading(left: 0, wroteAt: 9999, pace: 200_000, settled: true, now: 9999)
        return (meter, 9999 + 11_250 + FeedMeter.deadlineSlackMilliseconds)
    }

    // MARK: The meter

    @Test func aFeedPastItsDeadlineThatStillMovesIsNotStalled() {
        var (meter, deadline) = measured()
        let now = deadline + 1
        _ = meter.report(key, held: 950_000, milliseconds: 7000, now: now)
        #expect(!meter.reading(left: 0, wroteAt: now, pace: 200_000, settled: true, now: now).live, "past the deadline")
        #expect(!meter.isStalled(wroteAt: now, now: now), "but it moved")
    }

    @Test func aFeedStallsAfterTheStallTimeWithNoProgressAndRecoversWhenItMoves() {
        var (meter, _) = measured()
        #expect(!meter.isStalled(wroteAt: 9999, now: 9999 + stall), "the whole stall time, not past it")
        #expect(meter.isStalled(wroteAt: 9999, now: 9999 + stall + 1))
        let later = 9999 + stall + 5000
        _ = meter.report(key, held: 300_000, milliseconds: 9000, now: later)
        #expect(!meter.isStalled(wroteAt: later, now: later), "progress resumed")
        #expect(meter.isStalled(wroteAt: later, now: later + stall + 1), "and stalls again once it stops")
    }

    @Test func aReportThatHoldsNoMoreIsNoProgress() {
        var (meter, _) = measured()
        let later = 9999 + stall
        _ = meter.report(key, held: 101_000, milliseconds: 9000, now: later)
        #expect(meter.isStalled(wroteAt: later, now: later + 1), "the same bytes held, counted from the last advance")
    }

    @Test func beforeAnyReportTheStallCountsFromTheLastWrite() {
        var meter = FeedMeter(minSample: 0)
        meter.start(key, now: 0)
        meter.sized(offset: 0, length: 1 << 20)
        #expect(!meter.isStalled(wroteAt: 0, now: stall))
        #expect(meter.isStalled(wroteAt: 0, now: stall + 1))
        #expect(!meter.isStalled(wroteAt: stall, now: stall + 1), "a write went through")
    }

    @Test func theStallAgreesWithLiveInsideTheDeadline() {
        var (meter, _) = measured()
        for now in [9999 + stall - 1, 9999 + stall, 9999 + stall + 1] {
            let live = meter.reading(left: 0, wroteAt: 9999, pace: 200_000, settled: true, now: now).live
            #expect(live == !meter.isStalled(wroteAt: 9999, now: now), "at \(now)")
        }
    }

    // MARK: The link

    /// A rig streaming a 256 KiB file to `LinkRig.low` at the 4 KiB/s pace, with one report from the receiver at the
    /// start: 4 KiB held. The stall counts from the receiver's last advance once it has reported.
    private func streaming() -> (rig: LinkRig, hash: BlobHash) {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = (0..<262_144).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let hash = BlobHash(of: file)
        let outbound = OutboundFile(kind: .attachment, hash: hash, mime: "image/jpeg", size: file.count) { offset, count in
            Array(file[offset..<min(file.count, offset + count)])
        }
        _ = rig.links.sendFile(outbound, to: LinkRig.low)
        rig.links.fileProgressReported(from: LinkRig.low, hash: hash, held: 4096, milliseconds: 1000)
        return (rig, hash)
    }

    /// Runs the rig's timers for `milliseconds`, 100 at a time, as the `Mesh` actor's would: the feed keeps writing.
    private func run(_ rig: LinkRig, _ milliseconds: Int64, each look: (() -> Void)? = nil) {
        for _ in 0..<(milliseconds / 100) {
            _ = rig.advance(100)
            look?()
        }
    }

    @Test func aLinksFeedStallsWhenItsReceiverStopsMovingAndMovesAgainOnItsNextReport() {
        let (rig, hash) = streaming()
        #expect(!rig.links.isFileFeedStalled(hash, to: LinkRig.low))
        run(rig, stall)
        #expect(!rig.links.isFileFeedStalled(hash, to: LinkRig.low), "the whole stall time, not past it")
        run(rig, 100)
        #expect(rig.links.isFileFeedStalled(hash, to: LinkRig.low), "no report moved for the stall time, writes or not")
        rig.links.fileProgressReported(from: LinkRig.low, hash: hash, held: 8192, milliseconds: 16_000)
        #expect(!rig.links.isFileFeedStalled(hash, to: LinkRig.low), "its next report moved it")
    }

    @Test func aCopyNotStreamingOrNotLinkedIsNotStalled() {
        let (rig, hash) = streaming()
        rig.clock.advance(stall + 1)
        #expect(!rig.links.isFileFeedStalled(BlobHash(of: [1, 2, 3]), to: LinkRig.low), "not this copy")
        #expect(!rig.links.isFileFeedStalled(hash, to: LinkRig.middle), "unlinked")
        _ = rig.handle(.closed(channel))
        #expect(!rig.links.isFileFeedStalled(hash, to: LinkRig.low), "its link went")
    }

    @Test func readingTheStallLeavesTheFeedsReadingAsItWas() throws {
        // A second report 3 s after the first, past the meter's 2 s sample floor, measures a rate, so the deadline is due
        // and set at the next reading. Read through the meter, the looked rig's would be set 100 ms on and the untouched
        // one's at its first read 40 s on, and the two readings' recheck would differ by that.
        let (looked, hash) = streaming()
        let (untouched, _) = streaming()
        for rig in [looked, untouched] {
            run(rig, 3000)
            rig.links.fileProgressReported(from: LinkRig.low, hash: hash, held: 16_384, milliseconds: 4000)
        }
        run(looked, 40_000) { _ = looked.links.isFileFeedStalled(hash, to: LinkRig.low) }
        run(untouched, 40_000)
        let seen = try #require(looked.links.fileFeed(of: hash, to: LinkRig.low))
        #expect(seen.measured, "a rate, so a deadline")
        #expect(seen.recheckMilliseconds != nil, "the deadline is set at this read, in both")
        #expect(seen == untouched.links.fileFeed(of: hash, to: LinkRig.low), "the same live, ETA and recheck, deadline and all")
    }

    @Test func aTransportWithNoStallOfItsOwnReadsLiveTurnedOver() {
        let transport = RecordingTransport()
        #expect(!transport.isFileFeedStalled(key, to: LinkRig.low), "nothing fed")
        transport.feeds = [FedCopy(key, LinkRig.low, FeedReading(etaMilliseconds: 1000, live: true))]
        #expect(!transport.isFileFeedStalled(key, to: LinkRig.low))
        transport.feeds = [FedCopy(key, LinkRig.low, FeedReading(etaMilliseconds: 1000, live: false))]
        #expect(transport.isFileFeedStalled(key, to: LinkRig.low))
    }
}
