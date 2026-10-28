import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Custody's fair global trim (knit-next ADR 2026-10.7mqm) across nodes: stores whose quotas bind together still converge
/// by exchanging what each lacks, and a Sybil flood leaves every honest frame on every node. First at the store level,
/// as Android's `ForwardRepositoryTest` plays it, then between two engines over a ``LinkPipe``, through this port's own
/// back-fill: capped rounds from ``CustodySync/missing(from:for:in:now:crossed:key:)``, with the link's crossings and the
/// router's seen window, which Android's store-level exchange has neither of (ADR 2026-10.f5zs).
@Suite struct CustodyFairExchangeTests {
    /// The bound on convergence: three of the router's seen windows. Android's design pass settled within about two.
    private static let bound = 3 * SeenSet.defaultWindowMilliseconds
    /// A digest round.
    private static let round: Int64 = 60_000
    /// The room, a group, a sender and the global cap all bind at once.
    private static let binding = CustodyLimits(maxFrames: 14, maxPerSender: 8, maxPerGroup: 6, maxRoomChat: 5)

    /// A carried chat from `sender`: a room post, a group's under `group`, or a DM to `peer`.
    private static func frame(
        _ id: String, sender: String, sentAt: Int64, recipient: String? = nil, group: GroupInfo? = nil
    ) -> CarriedFrame {
        let envelope = RelayEnvelope(
            type: .chat,
            id: id,
            senderId: sender,
            sentAt: sentAt,
            recipientId: recipient,
            group: group,
            payload: ChatContent(body: "").encoded
        )
        return CarriedFrame(envelope: envelope, sig: [], signed: envelope.encoded)
    }

    @Test(arguments: [2, 3])
    func storesWhoseQuotasBindTogetherConvergeByExchangingWhatEachLacks(count: Int) {
        // Each round every store offers each other one its live frames, and a receiver takes only what its seen set admits,
        // so an id it saw inside the window comes again only once the window lapses. The arrival order decides what each
        // store holds first.
        for seed in UInt64(1)...6 {
            var random = SeededGenerator(seed: seed &* 101 &+ UInt64(count))
            var now: Int64 = 1_000_000
            let members = ["s0", "s1", "s2"]
            let group = GroupInfo(id: GroupId.derive(members), members: members, createdBy: "s0")
            let frames = (1...36).map { index -> CarriedFrame in
                let sender = "s\(Int.random(in: 0..<5, using: &random))"
                let sentAt = now - Int64.random(in: 1..<600_000, using: &random)
                let number = index < 10 ? "0\(index)" : "\(index)"
                switch Int.random(in: 0..<3, using: &random) {
                case 0:
                    return Self.frame("r\(number)", sender: sender, sentAt: sentAt)
                case 1:
                    return Self.frame("g\(number)", sender: members[Int.random(in: 0..<3, using: &random)], sentAt: sentAt, group: group)
                default:
                    return Self.frame("d\(number)", sender: sender, sentAt: sentAt, recipient: "peer")
                }
            }
            let stores = (0..<count).map { _ in MemoryCustodyStore(limits: Self.binding) }
            var seen = (0..<count).map { _ in SeenSet() }
            for (index, store) in stores.enumerated() {
                for carried in frames.filter({ _ in Int.random(in: 0..<10, using: &random) < 7 }).shuffled(using: &random) {
                    _ = seen[index].insert(carried.envelope.id, now: now)
                    store.store(carried, origin: .relayed, now: now)
                }
            }
            let start = now
            while Set(stores.map { Set($0.liveIds(now: now)) }).count > 1 {
                guard now - start <= Self.bound else {
                    Issue.record("seed \(seed), \(count) stores: not converged after \((now - start) / 60_000) min")
                    break
                }
                now += Self.round
                // Every offer is read before any is taken: the exchanges of one round cross on the air.
                let offers = stores.map { $0.liveFrames(now: now) }
                let heldBefore = stores.map { Set($0.liveIds(now: now).map(ExactKey.init)) }
                for (to, store) in stores.enumerated() {
                    for (from, offer) in offers.enumerated() where from != to {
                        for carried in offer where !heldBefore[to].contains(ExactKey(carried.envelope.id)) {
                            if seen[to].insert(carried.envelope.id, now: now) {
                                store.store(carried, origin: .relayed, now: now)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Two engines over a pipe

    /// The senders of the seeded frames, the recipient of their DMs, and the neighbour the seeds arrive from.
    private static let senders = (0..<5).map { TestPeer(seed: 500 + $0) }
    private static let recipient = TestPeer(seed: 999)
    private static let neighbour = TestPeer(seed: 900)

    /// Pins every key in `peers` on `node`, as a node that met them before would hold them.
    private static func pin(_ peers: [TestPeer], on node: PipeNode) {
        for peer in peers {
            node.stores.peers.upsert(
                PeerRecord(nodeId: peer.nodeId, name: "", status: "", publicKey: peer.keys.bundle.encoded, updatedAt: 1))
        }
    }

    /// Hands `node` each of `frames` as a neighbour's flood: through its router, so its seen window holds them, verified,
    /// and carried.
    private static func seed(_ node: PipeNode, with frames: [TestFrame]) {
        for frame in frames {
            node.engine.receive(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: neighbour.nodeId))
        }
    }

    /// Whether `nodes` hold the same live ids.
    private static func agree(_ nodes: [PipeNode], at now: Int64) -> Bool {
        Set(nodes.map { Set($0.stores.custody.liveIds(now: now)) }).count == 1
    }

    /// Thirty signed frames from the five senders: room posts, frames of a group the two phones are in, and DMs to a third
    /// party, each a few minutes old at most.
    private static func honestFrames(seed: UInt64, members phones: [TestPeer], wall: Int64) throws -> [TestFrame] {
        var random = SeededGenerator(seed: seed)
        let roster = Array(senders.prefix(3)) + phones
        let group = GroupInfo(
            id: GroupId.derive(roster.map(\.nodeId.string)), members: roster.map(\.nodeId.string), createdBy: senders[0].nodeId.string)
        return try (0..<30).map { index in
            let sentAt = wall - Int64.random(in: 1..<600_000, using: &random)
            let id = frameIdOf("seed\(seed)-\(index)")
            switch Int.random(in: 0..<3, using: &random) {
            case 0:
                let sender = senders[Int.random(in: 0..<5, using: &random)]
                return try sender.signed(
                    RelayEnvelope(
                        type: .chat, id: id, senderId: sender.nodeId.string, sentAt: sentAt, payload: ChatContent(body: "r").encoded))
            case 1:
                return try senders[Int.random(in: 0..<3, using: &random)].groupMessage("g", in: group, to: phones, id: id, sentAt: sentAt)
            default:
                return try senders[Int.random(in: 0..<5, using: &random)].directMessage("d", to: recipient, id: id, sentAt: sentAt)
            }
        }
    }

    @Test(arguments: UInt64(1)...3)
    func twoEnginesWhoseQuotasBindConvergeThroughTheirDigestRounds(seed: UInt64) throws {
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let first = lab.node(1, custodyLimits: Self.binding)
        let second = lab.node(2, custodyLimits: Self.binding)
        let phones = [first, second]
        for node in phones {
            Self.pin(Self.senders + [Self.recipient], on: node)
        }
        let frames = try Self.honestFrames(seed: seed, members: phones.map(\.peer), wall: wall)
        // Overlapping sets, in different orders.
        var random = SeededGenerator(seed: seed &+ 77)
        for node in phones {
            Self.seed(node, with: frames.filter { _ in Int.random(in: 0..<10, using: &random) < 7 }.shuffled(using: &random))
        }
        #expect(!Self.agree(phones, at: wall), "the test starts from two different custodies")
        lab.link(first, second)
        let converged = lab.run(step: 1000, limit: Self.bound) { Self.agree(phones, at: lab.clock.wallMilliseconds()) }
        #expect(converged, "seed \(seed): not converged within three windows")
        // Past the seen and crossing windows every frame either side lacks is offered again: the sets must stay equal.
        lab.run(step: 1000, limit: 11 * 60_000) { false }
        #expect(Self.agree(phones, at: lab.clock.wallMilliseconds()), "seed \(seed): apart again past the windows")
    }

    @Test func aSybilFloodAtTheWindowsEdgeLeavesEveryHonestFrameOnBothEngines() throws {
        // Five identities, eight DMs each, stamped just inside the future window: the newest frames of all. Under the old
        // global trim they took every honest frame on both phones; now they pay for the cap from their own buckets.
        let lab = PipeLab()
        let wall = lab.clock.wallMilliseconds()
        let limits = CustodyLimits(maxFrames: 30, maxPerSender: 8)
        let first = lab.node(1, custodyLimits: limits)
        let second = lab.node(2, custodyLimits: limits)
        let phones = [first, second]
        let sybils = (0..<5).map { TestPeer(seed: 700 + $0) }
        for node in phones {
            Self.pin(Self.senders + sybils + [Self.recipient], on: node)
        }
        let honest = try (0..<8).map { index in
            try Self.senders[index % 4].directMessage("h", to: Self.recipient, id: frameIdOf("honest-\(index)"), sentAt: wall - 60_000)
        }
        Self.seed(first, with: Array(honest.prefix(5)))
        Self.seed(second, with: Array(honest.suffix(3)))
        let edge = wall + WireProtocol.maxFutureSkewMilliseconds - 1
        let flood = try sybils.enumerated().flatMap { offset, sybil in
            try (0..<8).map { index in
                try sybil.directMessage("s", to: Self.recipient, id: frameIdOf("sybil-\(offset)-\(index)"), sentAt: edge - Int64(index))
            }
        }
        Self.seed(first, with: flood)
        lab.link(first, second)
        let honestIds = Set(honest.map(\.envelope.id))
        let converged = lab.run(step: 1000, limit: Self.bound) {
            let now = lab.clock.wallMilliseconds()
            return Self.agree(phones, at: now) && honestIds.isSubset(of: first.stores.custody.liveIds(now: now))
        }
        #expect(converged)
        let now = lab.clock.wallMilliseconds()
        for node in phones {
            let held = Set(node.stores.custody.liveIds(now: now))
            #expect(honestIds.isSubset(of: held), "missing \(honestIds.subtracting(held).count) honest frames")
            #expect(held.count == limits.maxFrames, "the flood still fills the cap")
        }
    }
}
