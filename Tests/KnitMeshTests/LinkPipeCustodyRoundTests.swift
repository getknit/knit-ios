import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A capped reply round played on both sides (ADR 2026-10.f5zs): engines and link managers joined by a ``LinkPipe``, the
/// far side's digests and floods its own. The oracles are the frames that crossed the pipe and the two custodies.
@Suite struct LinkPipeCustodyRoundTests {
    /// The bytes of the large profile, past a round's whole budget.
    private static let largeProfileBytes = 300 * 1024

    /// A frame as custody keeps it.
    private static func carried(_ frame: TestFrame) -> CarriedFrame {
        CarriedFrame(envelope: frame.envelope, sig: frame.wire.sig, signed: frame.wire.signed)
    }

    /// `peer`'s profile with a status `statusBytes` long, published at `publishedAt`.
    private static func profile(of peer: TestPeer, publishedAt: Int64, statusBytes: Int = 0) throws -> TestFrame {
        let content = ProfileContent(
            name: "Peer",
            status: String(repeating: "s", count: statusBytes),
            avatarHash: nil,
            pubKey: peer.keys.bundle.encoded,
            deviceTag: nil,
            protoVersion: WireProtocol.version,
            capabilities: 0xFFF,
            prekey: nil,
            version: nil
        )
        let envelope = RelayEnvelope(
            type: .profile,
            id: FrameId.profileId(sender: peer.nodeId.string, publishedAt: publishedAt),
            senderId: peer.nodeId.string,
            sentAt: publishedAt,
            payload: content.encoded
        )
        return try peer.signed(envelope)
    }

    /// Fills `holder`'s custody with 999 frames beside its own profile, the oldest received first: 400 group frames in two
    /// groups the newcomer is not in, one DM from each of 200 senders whose key only the pin store keeps, 396 DMs from
    /// three senders whose profiles custody holds, and those three profiles, then a profile of 300 KiB.
    private static func fillFull(_ holder: PipeNode, wall: Int64) throws {
        let recipient = TestPeer(seed: 999)
        let custody = holder.stores.custody
        let groupSenders = (0..<4).map { TestPeer(seed: 600 + $0) }
        for index in 0..<400 {
            let sender = groupSenders[index % 4]
            let members = (index < 200 ? groupSenders.prefix(2) : groupSenders.suffix(2)).map(\.nodeId.string) + [recipient.nodeId.string]
            let group = GroupInfo(id: index < 200 ? "ga" : "gb", members: members, createdBy: sender.nodeId.string)
            // Older than anything else, so the global cap takes these first.
            let envelope = RelayEnvelope(
                type: .chat,
                id: frameIdOf("group-\(index)"),
                senderId: sender.nodeId.string,
                sentAt: wall - 100_000 + Int64(index),
                group: group,
                payload: ChatContent(body: "g").encoded
            )
            #expect(custody.store(carried(try sender.signed(envelope)), origin: .relayed, now: wall))
        }
        for index in 0..<200 {
            let sender = TestPeer(seed: 1000 + index)
            let key = try profile(of: sender, publishedAt: wall - 1000)
            holder.stores.peers.recordProfileFrame(key.wire, of: sender.nodeId, sentAt: wall - 1000)
            let dm = try sender.directMessage("k", to: recipient, id: frameIdOf("keyless-\(index)"), sentAt: wall - 1000)
            #expect(custody.store(carried(dm), origin: .relayed, now: wall))
        }
        let keyed = (0..<3).map { TestPeer(seed: 700 + $0) }
        for index in 0..<396 {
            let dm = try keyed[index % 3].directMessage("d", to: recipient, id: frameIdOf("keyed-\(index)"), sentAt: wall - 1000)
            #expect(custody.store(carried(dm), origin: .relayed, now: wall))
        }
        for sender in keyed {
            #expect(custody.store(carried(try profile(of: sender, publishedAt: wall - 1000)), origin: .relayed, now: wall))
        }
        let large = try profile(of: TestPeer(seed: 800), publishedAt: wall - 1000, statusBytes: largeProfileBytes)
        #expect(custody.store(carried(large), origin: .relayed, now: wall))
    }

    /// The frames `holder` would serve a newcomer: every live one but the group frames it is not in.
    private static func owed(by holder: PipeNode, wall: Int64) -> Set<String> {
        let groups = Set(holder.stores.custody.liveIndex(now: wall).filter { $0.groupId != nil }.map(\.id))
        return Set(holder.stores.custody.liveIds(now: wall)).subtracting(groups)
    }

    /// How many of `from`'s digests `node`'s engine answered or held: each is one round.
    private static func digests(at node: PipeNode, from peer: PipeNode) -> Int {
        node.log.all.filter { $0.contains("mesh digest from \(peer.nodeId):") }.count
    }

    @Test func aNewcomerFacingAFullCustodyConvergesInCappedRounds() throws {
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let holder = lab.node(1)
        try Self.fillFull(holder, wall: wall)
        #expect(holder.stores.custody.liveIds(now: wall).count == 1000)
        let missing = Self.owed(by: holder, wall: wall).count
        let groups = Set((0..<400).map { frameIdOf("group-\($0)") })
        let newcomer = lab.node(2)
        let pipe = lab.link(holder, newcomer)
        let converged = lab.run(step: 1000, limit: 900_000) {
            let now = lab.clock.wallMilliseconds()
            return Self.owed(by: holder, wall: now).isSubset(of: newcomer.stores.custody.liveIds(now: now))
        }
        #expect(converged)
        let rounds = Self.digests(at: holder, from: newcomer)
        let bound = (missing + CustodySync.roundFrames - 1) / CustodySync.roundFrames + 1
        #expect(rounds <= bound, "\(rounds) digests for \(missing) frames")
        // No group frame it is not in ever crossed, and every round stayed within its budget plus its one first pick.
        let served = pipe.frames.filter { $0.from == holder.nodeId }
        #expect(!served.contains { groups.contains($0.id) })
        for at in Set(served.map(\.at)) {
            let round = served.filter { $0.at == at }
            let bytes = round.reduce(0) { $0 + $1.bytes }
            let largest = round.map(\.bytes).max() ?? 0
            #expect(bytes <= CustodySync.roundBytes + largest, "\(bytes) bytes at \(at)")
        }
        // Every frame crossed once: a slice served is not served again while its crossing lasts.
        let ids = served.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test func aFloodOfEmptyDigestsBuysTwoRoundsThenOneEveryThirtySeconds() throws {
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let holder = lab.node(1)
        try Self.fillFull(holder, wall: wall)
        let newcomer = lab.node(2)
        let pipe = lab.link(holder, newcomer)
        let empty = try #require(LinkRecord(.digest, payload: LinkJSON.digestPayload(ids: [])).encoded)
        for _ in 0..<90 {
            pipe.inject(LinkRecord(.digest, payload: Array(empty.dropFirst(LinkRecord.headerBytes))), from: newcomer)
            lab.run(step: 1000, limit: 1000) { false }
        }
        // The link-up digest and one injected take the burst; the rest earn one every 30 s, the 60 s re-offer's included.
        let rounds = Self.digests(at: holder, from: newcomer)
        #expect(rounds <= 2 + 90 / 30)
        #expect(rounds >= 2)
    }

    @Test func aLinkHoldingARoundGetsTheNextOnceItsQueueFalls() throws {
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let holder = lab.node(1)
        let author = TestPeer(seed: 700)
        holder.stores.custody.store(Self.carried(try Self.profile(of: author, publishedAt: wall - 1000)), origin: .relayed, now: wall)
        for index in 0..<10 {
            let dm = try author.directMessage("d", to: TestPeer(seed: 999), id: frameIdOf("dm-\(index)"), sentAt: wall - 1000)
            holder.stores.custody.store(Self.carried(dm), origin: .relayed, now: wall)
        }
        let newcomer = lab.node(2)
        // The holder's radio says its next channel still holds a round unwritten, as a back-fill being written would.
        holder.radio.setLevel(OutboxLevel(queuedBytes: HeldDigests.lineBytes), on: ChannelID(10))
        let pipe = lab.link(holder, newcomer)
        #expect(pipe.channel(of: holder) == ChannelID(10))
        lab.run(step: 1000, limit: 10_000) { false }
        #expect(!pipe.frames.contains { $0.from == holder.nodeId && $0.id == frameIdOf("dm-0") })
        holder.radio.setLevel(OutboxLevel(), on: ChannelID(10))
        let fell = lab.clock.monotonicMilliseconds()
        let served = lab.run(step: 100, limit: HeldDigests.recheckMilliseconds) {
            pipe.frames.contains { $0.from == holder.nodeId && $0.id == frameIdOf("dm-0") }
        }
        #expect(served)
        #expect(lab.clock.monotonicMilliseconds() - fell <= HeldDigests.recheckMilliseconds)
    }

    @Test func aLinkStreamingAPhotoStillGetsItsRound() throws {
        // A real feed, its records left unwritten on the holder's radio as on slow air: what it queues is its window, which
        // stays under the line, so the round goes behind it at once rather than waiting.
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let holder = lab.node(1)
        let newcomer = lab.node(2)
        let picture: [UInt8] = (0..<1_000_000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) }
        let hash = BlobHash(of: picture)
        holder.hold(picture)
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
        let channel = try #require(pipe.channel(of: holder))
        let streaming = lab.run(step: 100, limit: 30_000) { holder.links.isFileInFlight(hash, to: newcomer.nodeId) }
        #expect(streaming, "the feed is under way: \(pipe.asks.count) asks, \(pipe.undelivered(from: holder)) bytes")
        // The holder takes custody of frames the newcomer lacks once the link is up, so only the next digest's round
        // can serve them.
        let author = TestPeer(seed: 700)
        holder.stores.custody.store(Self.carried(try Self.profile(of: author, publishedAt: wall - 1000)), origin: .relayed, now: wall)
        for index in 0..<10 {
            let dm = try author.directMessage("d", to: TestPeer(seed: 999), id: frameIdOf("dm-\(index)"), sentAt: wall - 1000)
            holder.stores.custody.store(Self.carried(dm), origin: .relayed, now: wall)
        }
        let queued = pipe.undelivered(from: holder)
        #expect(queued > 0 && queued < HeldDigests.lineBytes, "\(queued) bytes queued")
        holder.radio.setLevel(OutboxLevel(queuedBytes: queued), on: channel)
        let digest = LinkJSON.digestPayload(ids: newcomer.stores.custody.liveIds(now: wall))
        let answered = Self.digests(at: holder, from: newcomer)
        pipe.inject(LinkRecord(.digest, payload: digest), from: newcomer)
        // Answered on arrival, not held for a look: the link manager writes the round behind the feed's chunk.
        #expect(Self.digests(at: holder, from: newcomer) == answered + 1)
        #expect(!holder.log.all.contains { $0.contains("waits") })
        holder.radio.setLevel(OutboxLevel(), on: channel)
        pipe.holding = nil
        let fed = lab.clock.monotonicMilliseconds()
        #expect(
            lab.run(step: 100, limit: HeldDigests.recheckMilliseconds) {
                pipe.frames.contains { $0.from == holder.nodeId && $0.id == frameIdOf("dm-0") }
            })
        #expect(lab.clock.monotonicMilliseconds() - fed < HeldDigests.recheckMilliseconds)
        #expect(Self.digests(at: holder, from: newcomer) == answered + 1, "no other digest bought the round")
        #expect(lab.run { newcomer.stores.blobs.contains(hash) })
        #expect(pipe.frames.contains { $0.from == holder.nodeId && $0.id == frameIdOf("dm-0") })
    }

    // MARK: A junk flood, then the digests (knit-ios #19)

    /// `count` decodable, signed DMs from a sender nobody pinned, with fresh canonical ids.
    private static func junk(_ count: Int, wall: Int64) throws -> [LinkRecord] {
        let forger = TestPeer(seed: 5000)
        let victim = TestPeer(seed: 5001)
        return try (0..<count).map { index in
            let frame = try forger.directMessage("j", to: victim, id: frameIdOf("junk-\(index)"), sentAt: wall)
            return LinkRecord(.frame, payload: frame.wire.encoded)
        }
    }

    /// Each custodied id that crossed from `from` on `pipe`, and how many times.
    private static func copies(on pipe: LinkPipe, from: PipeNode, of ids: [String]) -> [String: Int] {
        let wanted = Set(ids)
        return pipe.frames.filter { $0.from == from.nodeId && wanted.contains($0.id) }.reduce(into: [:]) { $0[$1.id, default: 0] += 1 }
    }

    @Test func aJunkFloodThenThreeDigestsCrossEachCustodiedFrameOnce() throws {
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let holder = lab.node(1)
        let author = TestPeer(seed: 700)
        holder.stores.custody.store(Self.carried(try Self.profile(of: author, publishedAt: wall - 1000)), origin: .relayed, now: wall)
        for index in 0..<50 {
            let dm = try author.directMessage("d", to: TestPeer(seed: 999), id: frameIdOf("dm-\(index)"), sentAt: wall - 1000)
            holder.stores.custody.store(Self.carried(dm), origin: .relayed, now: wall)
        }
        let far = lab.node(2)
        let pipe = lab.link(holder, far)
        for record in try Self.junk(1025, wall: wall) {
            pipe.inject(record, from: far)
        }
        lab.pump()
        // Three exchanges, 60 s apart, all inside the crossings' 10 minutes.
        lab.run(step: 1000, limit: 181_000) { false }
        let now = lab.clock.wallMilliseconds()
        let held = holder.stores.custody.liveIds(now: now)
        let copies = Self.copies(on: pipe, from: holder, of: held)
        let theirs = Self.copies(on: pipe, from: far, of: far.stores.custody.liveIds(now: now))
        #expect(copies.values.allSatisfy { $0 == 1 }, "\(copies.filter { $0.value != 1 })")
        #expect(theirs.values.allSatisfy { $0 == 1 }, "\(theirs.filter { $0.value != 1 })")
        #expect(Set(held) == Set(far.stores.custody.liveIds(now: now)))
        #expect(Self.digests(at: holder, from: far) >= 4, "the link-up digest and three more")
    }

    @Test func aJunkFloodDoesNotLetARefusedFrameCrossAgain() throws {
        // Frames the far side cannot verify are omitted from every digest it sends; what keeps them from crossing at each
        // exchange is the link's memo, which inbound junk can no longer flush (ADR 2026-10.f5zs, rule 2), and the round
        // now reads it.
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let holder = lab.node(1)
        let stranger = TestPeer(seed: 900)
        for index in 0..<10 {
            let dm = try stranger.directMessage("u", to: TestPeer(seed: 999), id: frameIdOf("unkeyed-\(index)"), sentAt: wall - 1000)
            holder.stores.custody.store(Self.carried(dm), origin: .relayed, now: wall)
        }
        let far = lab.node(2)
        let pipe = lab.link(holder, far)
        for record in try Self.junk(1025, wall: wall) {
            pipe.inject(record, from: far)
        }
        lab.pump()
        lab.run(step: 1000, limit: 181_000) { false }
        let ids = (0..<10).map { frameIdOf("unkeyed-\($0)") }
        let copies = Self.copies(on: pipe, from: holder, of: ids)
        #expect(copies.count == 10)
        #expect(copies.values.allSatisfy { $0 == 1 }, "\(copies)")
        #expect(far.stores.custody.liveIds(now: lab.clock.wallMilliseconds()).allSatisfy { !ids.contains($0) })
    }
}
