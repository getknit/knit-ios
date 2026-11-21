import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Rounds behind a real file feed, played on both sides through a ``LinkPipe`` (ADR 2026-10.f5zs, rule 4, and the
/// `custody-carry-policy` contract, §2): a file's window never holds a round, and a file comes first, so while it is on the
/// link a round carries only what is addressed to the peer, and the rest goes once the file has.
@Suite struct LinkPipeFeedWindowRoundTests {
    /// A frame as custody keeps it.
    private static func carried(_ frame: TestFrame) -> CarriedFrame {
        CarriedFrame(envelope: frame.envelope, sig: frame.wire.sig, signed: frame.wire.signed)
    }

    /// How many digests from `peer` `node` has read, each logged as it is.
    private static func digests(at node: PipeNode, from peer: PipeNode) -> Int {
        node.log.all.filter { $0.contains("mesh digest from \(peer.nodeId):") }.count
    }

    /// A lab, its two nodes and their pipe, and the photo's hash.
    private struct Setup {
        let lab: PipeLab
        let holder: PipeNode
        let newcomer: PipeNode
        let pipe: LinkPipe
        let hash: BlobHash
    }

    /// A holder serving a 1 MB photo a newcomer wants, linked to it with the holder's air held, and the photo's hash.
    private static func servingAPhoto() -> Setup {
        let lab = PipeLab()
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
        return Setup(lab: lab, holder: holder, newcomer: newcomer, pipe: pipe, hash: hash)
    }

    /// Frames the holder's custody takes once the link is up, which only the next digest serves: ten DMs for others, and
    /// one for the newcomer, its mail.
    private static func stock(_ holder: PipeNode, for newcomer: PipeNode, wall: Int64) throws -> (others: Set<String>, mail: String) {
        let author = TestPeer(seed: 700)
        holder.stores.custody.store(carried(try author.profile(publishedAt: wall - 1000)), origin: .relayed, now: wall)
        let others = try (0..<10).map { index in
            try author.directMessage("d", to: TestPeer(seed: 999), id: frameIdOf("dm-\(index)"), sentAt: wall - 1000)
        }
        let mail = try author.directMessage("for you", to: newcomer.peer, id: frameIdOf("dm-newcomer"), sentAt: wall - 1000)
        for dm in others + [mail] {
            holder.stores.custody.store(carried(dm), origin: .relayed, now: wall)
        }
        return (Set(others.map(\.envelope.id)), mail.envelope.id)
    }

    /// Airs the holder's writes at 32 KiB/s and checks that, while the file is on the link, the newcomer's mail crosses and
    /// nothing else of custody's does, and that the rest crosses once the file has, with no other digest.
    private static func expectMailFirst(
        _ setup: Setup, others: Set<String>, mail: String, answered: Int
    ) {
        let (lab, holder, newcomer, pipe, hash) = (setup.lab, setup.holder, setup.newcomer, setup.pipe, setup.hash)
        pipe.bytesPerSecond = 32_768
        var duringFile: [LinkPipe.Frame] = []
        let ended = lab.run(step: 100, limit: 60_000) {
            guard holder.links.isFileInFlight(hash, to: newcomer.nodeId) else {
                return true
            }
            duringFile = pipe.frames.filter { $0.from == holder.nodeId }
            return false
        }
        #expect(ended)
        #expect(duringFile.contains { $0.id == mail }, "the newcomer's mail crossed during the file")
        #expect(!duringFile.contains { others.contains($0.id) }, "nothing else from custody did")
        #expect(lab.run(step: 100, limit: 5000) { others.isSubset(of: Set(pipe.frames.map(\.id))) }, "the rest once it had")
        #expect(digests(at: holder, from: newcomer) == answered + 1, "no other digest bought the round")
        #expect(lab.run { newcomer.stores.blobs.contains(hash) })
    }

    @Test func aLinkWithAWholeFeedWindowUnreadAnswersThePeersMailOnArrivalAndTheRestAfterTheFile() throws {
        // A real feed over a link whose air takes 800 ms, each record reported written as it leaves the radio, so the
        // window grows to its whole 64 KiB (`FeedWindow.maxWindowBytes`); then the newcomer stops reading. What holds a round
        // is frames unwritten, never a file's window, so the digest is answered on arrival.
        let setup = Self.servingAPhoto()
        let (lab, holder, newcomer, pipe, hash) = (setup.lab, setup.holder, setup.newcomer, setup.pipe, setup.hash)
        let wall = lab.clock.wallMilliseconds()
        pipe.delay = (holder, 800)
        pipe.holding = nil
        let window = Int(FeedWindow.maxWindowBytes)
        let grown = lab.run(step: 100, limit: 30_000) {
            holder.links.isFileInFlight(hash, to: newcomer.nodeId) && pipe.undelivered(from: holder) >= window
        }
        #expect(grown, "the window grew to its whole: \(pipe.undelivered(from: holder)) bytes under way")
        pipe.unread = holder
        let (others, mail) = try Self.stock(holder, for: newcomer, wall: wall)
        // The window is on the air, every FILE record written and reported so: the radio's queue holds none of it, and what the
        // rounds compare (`queuedFrameBytes(to:)`) is the frames the link has not written, here none.
        #expect(pipe.undelivered(from: holder) >= window)
        #expect(holder.links.queuedFrameBytes(to: newcomer.nodeId) < CustodySync.roundBytes)
        let digest = LinkJSON.digestPayload(ids: newcomer.stores.custody.liveIds(now: wall))
        let answered = Self.digests(at: holder, from: newcomer)
        pipe.inject(LinkRecord(.digest, payload: digest), from: newcomer)
        #expect(Self.digests(at: holder, from: newcomer) == answered + 1)
        #expect(!holder.log.all.contains { $0.contains("waits") }, "answered on arrival, not held behind the file's window")
        pipe.unread = nil
        pipe.delay = nil
        Self.expectMailFirst(setup, others: others, mail: mail, answered: answered)
    }

    @Test func aLinkStreamingAPhotoServesThePeersMailFirstAndTheRestAfterTheFile() throws {
        // The photo's feed under way while the holder's air is held, then aired.
        let setup = Self.servingAPhoto()
        let (lab, holder, newcomer, pipe, hash) = (setup.lab, setup.holder, setup.newcomer, setup.pipe, setup.hash)
        let wall = lab.clock.wallMilliseconds()
        let streaming = lab.run(step: 100, limit: 30_000) { holder.links.isFileInFlight(hash, to: newcomer.nodeId) }
        #expect(streaming, "the feed is under way: \(pipe.asks.count) asks, \(pipe.undelivered(from: holder)) bytes")
        let (others, mail) = try Self.stock(holder, for: newcomer, wall: wall)
        let digest = LinkJSON.digestPayload(ids: newcomer.stores.custody.liveIds(now: wall))
        let answered = Self.digests(at: holder, from: newcomer)
        pipe.inject(LinkRecord(.digest, payload: digest), from: newcomer)
        #expect(Self.digests(at: holder, from: newcomer) == answered + 1)
        pipe.holding = nil
        Self.expectMailFirst(setup, others: others, mail: mail, answered: answered)
    }
}
