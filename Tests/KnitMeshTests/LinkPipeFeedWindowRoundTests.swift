import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A reply round behind a file feed whose whole window waits unread on the link (ADR 2026-10.f5zs, rule 4), played on
/// both sides through a ``LinkPipe`` whose holder's air is slow. ``LinkPipeCustodyRoundTests`` holds a feed's one queued
/// chunk; this one lets the feed's window grow to its largest first.
@Suite struct LinkPipeFeedWindowRoundTests {
    /// A frame as custody keeps it.
    private static func carried(_ frame: TestFrame) -> CarriedFrame {
        CarriedFrame(envelope: frame.envelope, sig: frame.wire.sig, signed: frame.wire.signed)
    }

    /// How many digests from `peer` `node` has read, each logged as it is.
    private static func digests(at node: PipeNode, from peer: PipeNode) -> Int {
        node.log.all.filter { $0.contains("mesh digest from \(peer.nodeId):") }.count
    }

    @Test func aLinkWithAWholeFeedWindowUnreadStillGetsItsRoundOnArrival() throws {
        // A real feed over a link whose air takes 800 ms, each record reported written as it leaves the radio, so the
        // window grows to its whole 64 KiB (`FeedWindow.maxWindowBytes`); then the newcomer stops reading. A feed queues
        // at most its window, still under the line, so the round goes behind it at once rather than waiting.
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let holder = lab.node(1)
        let newcomer = lab.node(2)
        let picture: [UInt8] = (0..<1_000_000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) }
        let hash = BlobHash(of: picture)
        holder.hold(picture)
        newcomer.stores.conversations.accept(holder.nodeId.string)
        newcomer.stores.messages.save(
            MessageRecord(
                id: frameIdOf("dm-picture"),
                senderId: holder.nodeId,
                recipientId: newcomer.nodeId,
                conversationId: holder.nodeId.string,
                body: "",
                sentAt: EngineFixture.start,
                attachment: MessageAttachment(hash: hash)
            ))
        let pipe = lab.link(holder, newcomer, holding: holder)
        pipe.delay = (holder, 800)
        pipe.holding = nil
        let channel = try #require(pipe.channel(of: holder))
        let window = Int(FeedWindow.maxWindowBytes)
        let grown = lab.run(step: 100, limit: 30_000) {
            holder.links.isFileInFlight(hash, to: newcomer.nodeId) && pipe.undelivered(from: holder) >= window
        }
        #expect(grown, "the window grew to its whole: \(pipe.undelivered(from: holder)) bytes under way")
        pipe.unread = holder
        let author = TestPeer(seed: 700)
        holder.stores.custody.store(Self.carried(try author.profile(publishedAt: wall - 1000)), origin: .relayed, now: wall)
        for index in 0..<10 {
            let dm = try author.directMessage("d", to: TestPeer(seed: 999), id: frameIdOf("dm-\(index)"), sentAt: wall - 1000)
            holder.stores.custody.store(Self.carried(dm), origin: .relayed, now: wall)
        }
        let queued = pipe.undelivered(from: holder)
        #expect(queued >= window && queued < HeldDigests.lineBytes, "\(queued) bytes unread")
        holder.radio.setLevel(OutboxLevel(queuedBytes: queued), on: channel)
        let digest = LinkJSON.digestPayload(ids: newcomer.stores.custody.liveIds(now: wall))
        let answered = Self.digests(at: holder, from: newcomer)
        pipe.inject(LinkRecord(.digest, payload: digest), from: newcomer)
        #expect(Self.digests(at: holder, from: newcomer) == answered + 1)
        #expect(!holder.log.all.contains { $0.contains("waits") }, "answered on arrival, not held for a look")
        holder.radio.setLevel(OutboxLevel(), on: channel)
        pipe.unread = nil
        pipe.delay = nil
        #expect(lab.run(step: 100, limit: 30_000) { pipe.frames.contains { $0.from == holder.nodeId && $0.id == frameIdOf("dm-0") } })
        #expect(Self.digests(at: holder, from: newcomer) == answered + 1, "no other digest bought the round")
        #expect(lab.run { newcomer.stores.blobs.contains(hash) })
    }
}
