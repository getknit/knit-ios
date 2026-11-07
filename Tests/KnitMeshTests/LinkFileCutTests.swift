import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// Which teardowns keep a cut attachment's bytes for the next ask to resume from (knit-next ADR 2026-10.wtyc, knit-ios
/// #2). Android keeps on every `FramedLink.close()` (`FramedLink.kt:528-536`) and purges only at a start
/// (`MeshManager.kt:997-998`). So does every retire here, a radio going off included, but a stop keeps nothing, since
/// ``Mesh`` purges right after, and neither does a link that sent a bad record, whose bytes are suspect.
@Suite struct LinkFileCutTests {
    private let channel = ChannelID(100)
    private let photo = (0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) }
    private var hash: BlobHash { BlobHash(of: photo) }
    private var kept: String { "info partial \(hash.string.prefix(12)) kept 20000B" }

    /// A rig whose store logs into the rig's own log, so a test reads the keep and the links in one order.
    private func rig(local: NodeId = LinkRig.high) -> LinkRig {
        let log = RecordingLog()
        return LinkRig(local: local, log: log, partials: MemoryPartialBlobStore { line in log.log(.info, line) })
    }

    private func header(_ file: [UInt8]) -> [UInt8] {
        let header = FileHeader(kind: .attachment, key: BlobHash(of: file).string, mime: "image/jpeg", size: file.count)
        return LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []
    }

    private func chunk(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        LinkRecord(.fileChunk, payload: Array(bytes)).encoded ?? []
    }

    /// `peer`'s link on `id`, halfway through the photo.
    private func streaming(_ rig: LinkRig, from peer: NodeId = LinkRig.low, on id: ChannelID) {
        _ = rig.accept(peer, on: id)
        rig.links.acceptFiles([hash], resumable: [hash])
        _ = rig.handle(.received(id, header(photo) + chunk(photo[..<20_000])))
    }

    private func partialLines(_ rig: LinkRig) -> [String] {
        rig.log.all.filter { $0.hasPrefix("info partial ") }
    }

    @Test func aClosedLinkKeepsWhatCameOnceAndLeavesTheArrivals() {
        let rig = rig()
        streaming(rig, on: channel)
        #expect(rig.handle(.closed(channel)) == [.down(LinkRig.low)])
        #expect(rig.links.partials.length(hash) == 20_000)
        #expect(rig.links.arrivingFiles.isEmpty && !rig.links.arrivingFileKeys.contains(hash), "a kept prefix is never on its way")
        #expect(rig.handle(.closed(channel)).isEmpty, "a late close for a retired channel")
        #expect(partialLines(rig) == [kept])
    }

    @Test(arguments: [RadioState.off, .unauthorized, .unsupported])
    func aRadioThatGoesKeepsWhatCame(_ state: RadioState) {
        let rig = rig()
        streaming(rig, on: channel)
        #expect(rig.handle(.state(state)) == [.down(LinkRig.low)])
        #expect(rig.links.partials.length(hash) == 20_000, "the session goes on, and the ask follows the radio back")
    }

    @Test func aStopKeepsNothing() {
        let rig = rig()
        streaming(rig, on: channel)
        #expect(rig.links.stop() == [.down(LinkRig.low)])
        #expect(rig.links.partials.length(hash) == 0, "the mesh purges next")
        #expect(rig.links.arrivingFiles.isEmpty)
        #expect(partialLines(rig).isEmpty)
    }

    @Test func aBadRecordKeepsNothing() {
        let rig = rig()
        streaming(rig, on: channel)
        #expect(rig.handle(.received(channel, [10, 0, 0, 0, 0])) == [.down(LinkRig.low)])
        #expect(rig.log.all.contains { $0.hasPrefix("warning link \(channel) sent a bad record") })
        #expect(rig.links.partials.length(hash) == 0, "a mangled SDU may already be among the bytes")
        #expect(partialLines(rig).isEmpty)
    }

    @Test func aStaleLinksReplacementKeepsItsBytesBeforeTheNewLinkIsUp() throws {
        let rig = rig(local: LinkRig.low)
        let stale = ChannelID(102)
        let fresh = ChannelID(103)
        streaming(rig, from: LinkRig.middle, on: stale)
        _ = rig.advance(30_000)
        let events = rig.accept(LinkRig.middle, on: fresh)
        #expect(events.first == .down(LinkRig.middle), "the stale link goes first")
        #expect(rig.links.partials.length(hash) == 20_000)
        let lines = rig.log.all
        let keptAt = try #require(lines.firstIndex(of: kept))
        let upAt = try #require(lines.firstIndex(of: "info link up \(LinkRig.middle) on \(fresh)"))
        #expect(keptAt < upAt, "on disk before an ask can cross the new link")
    }

    @Test func aFailedDialOrATimeoutLeavesTheStoreAlone() throws {
        let rig = rig()
        let other = (0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 3) }
        rig.links.partials.keep(BlobHash(of: other), bytes: other, basedOn: nil, now: 1000)
        rig.sightToPromotion(LinkRig.low)
        let dialed = try #require(rig.radio.dials.last?.channel)
        _ = rig.handle(.dialFailed(dialed))
        _ = rig.handle(.accepted(ChannelID(200)))
        _ = rig.advance(15_000)
        #expect(rig.radio.closed.contains(dialed) && rig.radio.closed.contains(ChannelID(200)), "the HELLO timed out")
        #expect(rig.links.partials.length(BlobHash(of: other)) == 20_000)
        #expect(partialLines(rig).count == 1, "only the prefix the test kept")
    }

    /// When the resumable keys (our own wants) change around a stream past the store's floor (knit-ios #20).
    enum Resumable: CaseIterable, Sendable, CustomTestStringConvertible {
        /// Accepted, as an asker's echo, and never resumable.
        case never
        /// Resumable from its header to its cut.
        case throughout
        /// Resumable at its header, no longer by its cut: our want went, and an echo still wants it.
        case lostMidStream
        /// An echo's at its header, ours by its cut.
        case gainedMidStream

        var testDescription: String { "\(self)" }
        var atHeader: Bool {
            switch self {
            case .throughout, .lostMidStream:
                true
            case .never, .gainedMidStream:
                false
            }
        }
        var atCut: Bool {
            switch self {
            case .throughout, .gainedMidStream:
                true
            case .never, .lostMidStream:
                false
            }
        }
    }

    /// A cut keeps a prefix only of a key resumable as the link is cut, whatever it was at the header: an asker's cut
    /// streams never evict ours from the eight the store keeps (knit-ios #20, knit-next's fork review H2).
    @Test(arguments: Resumable.allCases)
    func aCutKeepsAPrefixOnlyOfAWantOfOursAsTheLinkGoes(_ resumable: Resumable) {
        let rig = rig()
        _ = rig.accept(LinkRig.low, on: channel)
        rig.links.acceptFiles([hash], resumable: resumable.atHeader ? [hash] : [])
        _ = rig.handle(.received(channel, header(photo) + chunk(photo[..<10_000])))
        rig.links.acceptFiles([hash], resumable: resumable.atCut ? [hash] : [])
        _ = rig.handle(.received(channel, chunk(photo[10_000..<20_000])))
        #expect(rig.handle(.closed(channel)) == [.down(LinkRig.low)])
        #expect(rig.links.partials.length(hash) == (resumable.atCut ? 20_000 : 0))
        #expect(partialLines(rig) == (resumable.atCut ? [kept] : []))
    }

    @Test func aStreamUnderTheFloorKeepsNothing() {
        let rig = rig()
        _ = rig.accept(LinkRig.low, on: channel)
        let small = Array(photo[..<10_000])
        rig.links.acceptFiles([BlobHash(of: small)], resumable: [BlobHash(of: small)])
        _ = rig.handle(.received(channel, header(small) + chunk(small[..<8000])))
        _ = rig.handle(.closed(channel))
        #expect(rig.links.partials.length(BlobHash(of: small)) == 0, "under the store's 16 KiB floor")
        #expect(partialLines(rig).isEmpty)
    }
}
