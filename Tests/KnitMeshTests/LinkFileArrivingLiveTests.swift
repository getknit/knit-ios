import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// Whether a file streaming in is moving (`isFileArrivingLive(from:)`, the `custody-carry-policy` contract, revision 16,
/// §2): only a file that is moving comes first, so a stream with no header or chunk for the blob plane's stall span
/// (``FeedMeter/stallMilliseconds``, 15 s) lets custody's other tiers go, and holds them again once it moves.
@Suite struct LinkFileArrivingLiveTests {
    private let channel = ChannelID(120)
    private let stall = FeedMeter.stallMilliseconds

    private func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }
    }

    private func header(_ file: [UInt8]) -> [UInt8] {
        let header = FileHeader(kind: .attachment, key: BlobHash(of: file).string, mime: "image/jpeg", size: file.count)
        return LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []
    }

    private func chunk(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        LinkRecord(.fileChunk, payload: Array(bytes)).encoded ?? []
    }

    /// A rig linked to `LinkRig.low`, a 4 KiB file it wants begun on the link: its header in.
    private func arriving() -> (rig: LinkRig, file: [UInt8]) {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(4096)
        let hash = BlobHash(of: file)
        rig.links.acceptFiles([hash], resumable: [hash])
        _ = rig.handle(.received(channel, header(file)))
        return (rig, file)
    }

    @Test func nothingArrivingIsNotLive() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        #expect(!rig.links.isFileArrivingLive(from: LinkRig.low))
        #expect(!rig.links.isFileArrivingLive(from: LinkRig.middle), "unlinked")
    }

    @Test func aHeaderWithNoChunkYetCountsAsProgress() {
        let (rig, _) = arriving()
        #expect(rig.links.isFileArrivingLive(from: LinkRig.low))
        rig.clock.advance(stall - 1)
        #expect(rig.links.isFileArrivingLive(from: LinkRig.low), "inside the span from its header")
        rig.clock.advance(1)
        #expect(!rig.links.isFileArrivingLive(from: LinkRig.low), "the span from its header ran out")
        #expect(rig.links.isFileArriving(from: LinkRig.low), "still arriving, only stalled")
    }

    @Test func chunksInsideTheSpanKeepItLiveAndTheNextAfterAStallRevivesIt() {
        let (rig, file) = arriving()
        rig.clock.advance(stall - 1000)
        _ = rig.handle(.received(channel, chunk(file[0..<1024])))
        rig.clock.advance(stall - 1000)
        #expect(rig.links.isFileArrivingLive(from: LinkRig.low), "the chunk moved it")
        _ = rig.handle(.received(channel, chunk(file[1024..<2048])))
        rig.clock.advance(stall)
        #expect(!rig.links.isFileArrivingLive(from: LinkRig.low), "15 s with no chunk")
        _ = rig.handle(.received(channel, chunk(file[2048..<3072])))
        #expect(rig.links.isFileArrivingLive(from: LinkRig.low), "live again on the next chunk")
    }

    @Test func aFileAtItsEndIsNotLive() {
        let (rig, file) = arriving()
        _ = rig.handle(.received(channel, chunk(file[...])))
        _ = rig.handle(.received(channel, LinkRecord(.fileEnd).encoded ?? []))
        #expect(!rig.links.isFileArriving(from: LinkRig.low))
        #expect(!rig.links.isFileArrivingLive(from: LinkRig.low))
    }

    @Test func aStreamCutByItsLinkGoingDownIsNotLive() {
        let (rig, file) = arriving()
        _ = rig.handle(.received(channel, chunk(file[0..<1024])))
        _ = rig.handle(.closed(channel))
        #expect(!rig.links.isFileArrivingLive(from: LinkRig.low))
        #expect(rig.links.arrivalClocks[channel] == nil, "its clock went with the link")
    }

    @Test func aNewHeaderStartsTheSpanAgain() {
        let (rig, _) = arriving()
        rig.clock.advance(stall)
        #expect(!rig.links.isFileArrivingLive(from: LinkRig.low))
        let next = (0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 3) }
        _ = rig.handle(.received(channel, header(next)))
        #expect(rig.links.isFileArrivingLive(from: LinkRig.low), "a header is progress, and cuts the stalled one off")
    }

    @Test func aTransportWithNoStreamClockAnswersWhetherAFileIsArriving() {
        let transport = RecordingTransport()
        #expect(!transport.isFileArrivingLive(from: LinkRig.low))
        transport.arrivingFrom.insert(LinkRig.low)
        #expect(transport.isFileArrivingLive(from: LinkRig.low))
    }
}
