import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A capped reply round played on both sides (ADR 2026-10.f5zs): engines and link managers joined by a ``LinkPipe``, the
/// far side's digests and floods its own. The oracles are the frames that crossed the pipe and the two custodies.
@Suite struct LinkPipeCustodyRoundTests {
    /// The bytes of the large profile's status: as large as custody's byte cap lets a frame be (knit-next #227), a quarter of
    /// a round's budget. A frame past the whole budget is over the cap, which both engines here refuse.
    private static let largeProfileBytes = 60_000

    /// Custody's limits on both phones that hold the large profile: production's, with the profile cap (ADR 2026-10.r88m)
    /// lifted to the byte cap, so the large profile still stands for a frame near the byte cap.
    private static let limits = CustodyLimits(maxProfileSignedBytes: CustodyLimits().maxSignedBytes)

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

    /// Fills `holder`'s custody with 1000 frames beside its own profile, the oldest received first: 400 group frames in two
    /// groups the newcomer is not in, whose four senders' keys only the pin store keeps, one DM from each of 200 senders whose
    /// key only the pin store keeps, 396 DMs from three senders whose profiles custody holds, and those three profiles, then
    /// a profile near custody's byte cap.
    private static func fillFull(_ holder: PipeNode, wall: Int64) throws {
        try #require(wall == EngineFixture.start, "the shared fill is built at the lab's start")
        let fill = try fullFill.get()
        let large = try #require(fill.frames.last).signed.count
        #expect(large > CustodyLimits().maxSignedBytes - 2048 && large <= CustodyLimits().maxSignedBytes)
        for key in fill.keys {
            holder.stores.peers.recordProfileFrame(key.profile.wire, of: key.of, sentAt: key.profile.envelope.sentAt)
        }
        for frame in fill.frames {
            #expect(holder.stores.custody.store(frame, origin: .relayed, now: wall).held)
        }
    }

    /// The frames `holder` would serve a newcomer: every live one, the group frames it is not in included (knit-next ADR
    /// 2026-10.hr9f).
    private static func owed(by holder: PipeNode, wall: Int64) -> Set<String> {
        Set(holder.stores.custody.liveIds(now: wall))
    }

    /// `custodiesAgree` read again only once a frame has crossed `pipe` since it last answered `false`, which it answers
    /// meanwhile. Within a run both custodies move only as frames cross (no frame here comes near its TTL), and reading
    /// two thousand live ids at each of a lab's hundreds of steps was most of these tests' time under the thread sanitizer,
    /// beside the actor suites' time limits. A stale answer is only ever `false`, so this can delay the loop's end, never
    /// end it early.
    private static func onceFramesCross(_ pipe: LinkPipe, _ custodiesAgree: @escaping () -> Bool) -> () -> Bool {
        var read = -1
        return {
            guard pipe.frames.count != read else {
                return false
            }
            read = pipe.frames.count
            return custodiesAgree()
        }
    }

    /// How many of `from`'s digests `node`'s engine answered or held: each is one round.
    private static func digests(at node: PipeNode, from peer: PipeNode) -> Int {
        node.log.all.filter { $0.contains("mesh digest from \(peer.nodeId):") }.count
    }

    @Test func aNewcomerFacingAFullCustodyConvergesInCappedRounds() throws {
        // The newcomer is owed every frame, the group frames it is not in included (knit-next ADR 2026-10.hr9f), and it
        // custodies the 204 keys served ahead of them besides. Under the default row cap of 1000 its custody would overflow
        // and trim while the rounds run, and the holder's again once those keys came back to it: the cap's own convergence,
        // which `CustodyFairExchangeTests` pins. Room on both sides, with `Self.limits`'s profile cap, keeps it on the rounds.
        let roomy = CustodyLimits(maxFrames: 1300, maxProfileSignedBytes: CustodyLimits().maxSignedBytes)
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let holder = lab.node(1, custodyLimits: roomy)
        try Self.fillFull(holder, wall: wall)
        #expect(holder.stores.custody.liveIds(now: wall).count == 1001)
        let missing = Self.owed(by: holder, wall: wall).count
        let groups = Set((0..<400).map { frameIdOf("group-\($0)") })
        let newcomer = lab.node(2, custodyLimits: roomy)
        let pipe = lab.link(holder, newcomer)
        let caughtUp = Self.onceFramesCross(pipe) {
            let now = lab.clock.wallMilliseconds()
            return Self.owed(by: holder, wall: now).isSubset(of: newcomer.stores.custody.liveIds(now: now))
        }
        let converged = lab.run(step: 1000, limit: 900_000, until: caughtUp)
        #expect(converged)
        let rounds = Self.digests(at: holder, from: newcomer)
        let bound = (missing + CustodySync.roundFrames - 1) / CustodySync.roundFrames + 1
        #expect(rounds <= bound, "\(rounds) digests for \(missing) frames")
        // Every group frame it is not in crossed, as any frame it lacked does (knit-next ADR 2026-10.hr9f), and every round
        // stayed within its budget plus its one first pick.
        let served = pipe.frames.filter { $0.from == holder.nodeId }
        #expect(groups.isSubset(of: served.map(\.id)))
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
        let holder = lab.node(1, custodyLimits: Self.limits)
        try Self.fillFull(holder, wall: wall)
        let newcomer = lab.node(2, custodyLimits: Self.limits)
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

/// The default row cap binding on both sides while the rounds run (knit-next ADR 2026-10.hr9f).
extension LinkPipeCustodyRoundTests {
    @Test func aNonMemberNewcomerFacingAFullCustodyConvergesUnderTheDefaultCap() throws {
        // The common case since knit-next ADR 2026-10.hr9f: a newcomer outside every group meets a carrier at the default row
        // cap. It is owed every frame, group frames included, and custodies the 204 keys served ahead of them besides, so its
        // cap trims while the rounds run, and the holder's does again once those keys come back to it. The fair trim decides
        // the same on both sides (knit-next ADR 2026-10.7mqm), so the two agree once each frame a trim took has been offered
        // again past its crossing. Observed: 13 holder-side digests and no id served more than twice.
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let holder = lab.node(1, custodyLimits: Self.limits)
        try Self.fillFull(holder, wall: wall)
        let filled = Set(holder.stores.custody.liveIds(now: wall).map(ExactKey.init))
        #expect(filled.count == CustodyLimits().maxFrames)
        let newcomer = lab.node(2, custodyLimits: Self.limits)
        let pipe = lab.link(holder, newcomer)
        let agree = Self.onceFramesCross(pipe) {
            let now = lab.clock.wallMilliseconds()
            return Set(holder.stores.custody.liveIds(now: now)) == Set(newcomer.stores.custody.liveIds(now: now))
        }
        let converged = lab.run(step: 1000, limit: 3 * SeenSet.defaultWindowMilliseconds, until: agree)
        #expect(converged, "the same live ids on both nodes")
        // 13 observed, with two rounds' margin.
        let rounds = Self.digests(at: holder, from: newcomer)
        #expect(rounds <= 15, "\(rounds) digests")
        // A frame either trim took is offered again once its crossing lapses, and then kept: never a third time.
        var copies: [String: Int] = [:]
        for frame in pipe.frames where frame.from == holder.nodeId {
            copies[frame.id, default: 0] += 1
        }
        let repeated = copies.filter { $0.value > 2 }
        #expect(repeated.isEmpty, "\(repeated.count) ids served more than twice")
        // Each key served ahead, a profile from the pin store that custody did not hold, is custodied on both sides or
        // trimmed on both.
        let servedKeys = Set(
            pipe.frames.filter { $0.from == holder.nodeId && $0.type == .profile && !filled.contains(ExactKey($0.id)) }.map(\.id))
        #expect(!servedKeys.isEmpty, "keys went ahead of their senders' backlogs")
        let split = servedKeys.filter { holder.stores.custody.contains($0) != newcomer.stores.custody.contains($0) }
        #expect(split.isEmpty, "\(split.count) keys held on one side only")
    }
}

/// The full fill, built once (``fillFull(_:wall:)``).
extension LinkPipeCustodyRoundTests {
    /// What ``fillFull(_:wall:)`` writes into a holder: the keys its pin store keeps, then the frames its custody takes, in the
    /// order received.
    private struct FullFill: Sendable {
        var keys: [(profile: TestFrame, of: NodeId)] = []
        var frames: [CarriedFrame] = []
    }

    /// The full fill at the lab's start, built once and shared by every test that fills a holder. Sealing and signing a
    /// thousand frames under the thread sanitizer takes seconds of a test thread, while the actor suites' time limits run
    /// beside it, and the frames are the same each time: every lab's wall clock starts at ``EngineFixture/start``.
    private static let fullFill = Result { try buildFullFill(wall: EngineFixture.start) }

    /// The keys and frames ``fillFull(_:wall:)`` writes, at `wall`.
    private static func buildFullFill(wall: Int64) throws -> FullFill {
        var fill = FullFill()
        let recipient = TestPeer(seed: 999)
        let groupSenders = (0..<4).map { TestPeer(seed: 600 + $0) }
        for sender in groupSenders {
            // A carrier verified each frame it holds, so its pin store keeps the sender's key: the key ahead of a group's
            // backlog to a newcomer outside it (knit-next ADR 2026-10.hr9f).
            let key = try profile(of: sender, publishedAt: wall - 100_000)
            fill.keys.append((key, sender.nodeId))
        }
        for index in 0..<400 {
            // Each group's two senders are its members, and its id derives from its roster (knit-next ADR 2026-10.7mqm).
            let pair = index < 200 ? groupSenders.prefix(2) : groupSenders.suffix(2)
            let sender = pair[pair.startIndex + index % 2]
            let members = pair.map(\.nodeId.string) + [recipient.nodeId.string]
            let group = GroupInfo(id: GroupId.derive(members), members: members, createdBy: sender.nodeId.string)
            // Older than anything else held, and sealed, as a carrier takes a group's chat only sealed (`isCarriable`).
            let others = pair.filter { $0 != sender } + [recipient]
            let message = try sender.groupMessage(
                "g", in: group, to: others, id: frameIdOf("group-\(index)"), sentAt: wall - 100_000 + Int64(index))
            fill.frames.append(carried(message))
        }
        for index in 0..<200 {
            let sender = TestPeer(seed: 1000 + index)
            let key = try profile(of: sender, publishedAt: wall - 1000)
            fill.keys.append((key, sender.nodeId))
            let dm = try sender.directMessage("k", to: recipient, id: frameIdOf("keyless-\(index)"), sentAt: wall - 1000)
            fill.frames.append(carried(dm))
        }
        let keyed = (0..<3).map { TestPeer(seed: 700 + $0) }
        for index in 0..<396 {
            let dm = try keyed[index % 3].directMessage("d", to: recipient, id: frameIdOf("keyed-\(index)"), sentAt: wall - 1000)
            fill.frames.append(carried(dm))
        }
        for sender in keyed {
            fill.frames.append(carried(try profile(of: sender, publishedAt: wall - 1000)))
        }
        fill.frames.append(carried(try profile(of: TestPeer(seed: 800), publishedAt: wall - 1000, statusBytes: largeProfileBytes)))
        return fill
    }
}
