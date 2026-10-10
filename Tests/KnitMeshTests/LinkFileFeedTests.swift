import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// A link's feeds as a holder reads them (`BluetoothMeshTransport.fileFeed` and `expectedFileRate`, `FramedLink.feed`,
/// knit-next ADR 2026-10.nsr7): the copy streaming now and its ETA, nothing for a copy queued behind another, the rate
/// a file would get, and the poke when a reading moves.
@Suite struct LinkFileFeedTests {
    private let channel = ChannelID(100)
    private let other = ChannelID(101)
    private let reporting: Capabilities = 0x2FFF
    private let budget = LinkManager.Configuration().filePaceBudgetBytesPerSecond

    private func bytes(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }
    }

    private func outbound(_ file: [UInt8]) -> OutboundFile {
        OutboundFile(kind: .attachment, hash: BlobHash(of: file), mime: "image/jpeg", size: file.count) { offset, count in
            Array(file[offset..<min(file.count, offset + count)])
        }
    }

    @Test func aStreamingCopyIsReadAtItsPaceUntilAReportMeasuresIt() throws {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        let file = bytes(40 * 1024)
        _ = rig.links.sendFile(outbound(file), to: LinkRig.low)
        // The starting window's two chunks went at the paced share: the window has no rate yet.
        let reading = try #require(rig.links.fileFeed(of: BlobHash(of: file), to: LinkRig.low))
        #expect(
            reading == FeedReading(etaMilliseconds: 32 * 1024 * 1000 / budget, live: true, recheckMilliseconds: FeedMeter.stallMilliseconds)
        )
        #expect(rig.links.takeFeedsChanged(), "its pace settled at the second chunk")
        #expect(!rig.links.takeFeedsChanged(), "one poke says it all")
        #expect(rig.links.fileFeed(of: BlobHash(of: file), to: LinkRig.middle) == nil, "no link")
        #expect(rig.links.fileFeed(of: BlobHash(of: bytes(10)), to: LinkRig.low) == nil, "not on the link")
        rig.clock.advance(FeedMeter.stallMilliseconds + 1)
        #expect(rig.links.fileFeed(of: BlobHash(of: file), to: LinkRig.low)?.live == false, "no write and no report: stalled")
    }

    @Test func aCopyQueuedBehindAnotherFileIsNotFedYet() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        let first = bytes(40 * 1024)
        let second = bytes(1024, seed: 2)
        _ = rig.links.sendFile(outbound(first), to: LinkRig.low)
        _ = rig.links.sendFile(outbound(second), to: LinkRig.low)
        #expect(rig.links.fileFeed(of: BlobHash(of: first), to: LinkRig.low) != nil)
        #expect(rig.links.fileFeed(of: BlobHash(of: second), to: LinkRig.low) == nil)
        #expect(rig.links.isFileInFlight(BlobHash(of: second), to: LinkRig.low), "though it is on its way")
    }

    @Test func aStreamThatEndsOrDiesWithItsLinkPokesTheHolder() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        let small = bytes(1024)
        _ = rig.links.sendFile(outbound(small), to: LinkRig.low)
        #expect(rig.links.fileFeed(of: BlobHash(of: small), to: LinkRig.low) == nil, "fed in full")
        #expect(rig.links.takeFeedsChanged())
        _ = rig.links.sendFile(outbound(bytes(40 * 1024)), to: LinkRig.low)
        _ = rig.links.takeFeedsChanged()
        _ = rig.handle(.closed(channel))
        #expect(rig.links.takeFeedsChanged(), "a copy cut off holds nobody")
    }

    @Test func aLinkWhoseLastStreamWasMeasuredExpectsItsDrainSharedWithTheOtherWindowedFeeds() throws {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        _ = rig.accept(LinkRig.middle, on: other, capabilities: reporting)
        // Big enough for the window's rate to reach its ceiling and hold: a rate that keeps moving rebases the meter.
        let file = bytes(1024 * 1024)
        _ = rig.links.sendFile(outbound(file), to: LinkRig.low)
        var milliseconds: Int64 = 0
        for _ in 0..<400 where rig.links.fileFeed(of: BlobHash(of: file), to: LinkRig.low) != nil {
            let held = rig.radio.records(on: channel).filter { $0.tag == .fileChunk }.reduce(0) { $0 + $1.payload.count }
            milliseconds += 500
            _ = rig.advance(500)
            rig.links.fileProgressReported(from: LinkRig.low, hash: BlobHash(of: file), held: Int64(held), milliseconds: milliseconds)
        }
        let drained = try #require(rig.links.feeds[channel]?.meter.lastRate)
        #expect(drained > 0)
        #expect(rig.links.expectedFileRate(to: LinkRig.low) == drained)
        _ = rig.links.sendFile(outbound(bytes(160 * 1024, seed: 9)), to: LinkRig.middle)
        #expect(rig.links.expectedFileRate(to: LinkRig.low) == drained / 2, "split with the windowed feed going")
    }

    @Test func aFileWouldGoAtThePacedShareBesideThePacedFeedsUntilALinkHasDrained() {
        let rig = LinkRig(local: LinkRig.high)
        #expect(rig.links.expectedFileRate(to: LinkRig.low) == 0, "no link")
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        _ = rig.accept(LinkRig.middle, on: other, capabilities: 0xFFF)
        #expect(rig.links.expectedFileRate(to: LinkRig.low) == budget, "the whole budget, feeding nothing")
        _ = rig.links.sendFile(outbound(bytes(40 * 1024)), to: LinkRig.middle)
        #expect(rig.links.expectedFileRate(to: LinkRig.low) == budget / 2, "split with the paced feed")
        #expect(rig.links.expectedFileRate(to: LinkRig.middle) == budget, "a link feeding already does not count itself twice")
        // A windowed feed with no rate yet is read at the paced share beside the paced feed.
        let file = bytes(40 * 1024, seed: 3)
        _ = rig.links.sendFile(outbound(file), to: LinkRig.low)
        let reading = rig.links.fileFeed(of: BlobHash(of: file), to: LinkRig.low)
        #expect(reading?.etaMilliseconds == 32 * 1024 * 1000 / (budget / 2))
    }
}
