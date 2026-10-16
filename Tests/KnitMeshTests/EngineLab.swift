import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// Engines of this port on links a test makes and breaks: knit-next's `MeshLab` (`MeshLab.kt`) in miniature, with no
/// radio. What one engine writes reaches every node it is linked to, frame by frame, as a link would carry it: a flood to
/// each, a frame addressed to one only to that one, a digest to the neighbour it names. A test may hold the frames of one
/// direction of a link and release them in an order of its choosing, dropping or repeating some; digests still cross, as
/// the lab's holds let them, so a held side's custody still answers the other's digest into its hold. A frame written to
/// a node that is not linked is lost, as on the air; our own frames and the ones we carry come back by custody's back-fill
/// at the next link-up, which is how the lab's merges work. Each node keeps its own clock, moved together.
final class EngineLab {
    /// A node and the link-level state the lab keeps for it.
    private final class Node {
        var fixture: EngineFixture
        var framesRead = 0
        var digestsRead = 0

        init(_ fixture: EngineFixture) {
            self.fixture = fixture
        }
    }

    /// What a link carries.
    enum Carried {
        /// A frame, as written.
        case frame(Written)
        /// A custody digest: the ids the sender holds.
        case digest([String])

        /// The frame's id, or `nil` for a digest.
        var id: String? {
            guard case .frame(let written) = self else {
                return nil
            }
            return written.envelope.id
        }
    }

    /// One direction of a link, by node index.
    private struct Direction: Hashable {
        let from: Int
        let to: Int
    }

    private var nodes: [Node]
    private var links: Set<Direction> = []
    private var holds: Set<Direction> = []
    private var held: [Direction: [Carried]] = [:]

    /// A lab over `fixtures`, none of them linked yet.
    init(_ fixtures: [EngineFixture]) {
        nodes = fixtures.map(Node.init)
    }

    /// Node `index`'s engine and stores.
    subscript(_ index: Int) -> EngineFixture {
        nodes[index].fixture
    }

    /// Links `first` and `second`, as each one's link layer reports the link up to its engine, and carries what follows.
    func link(_ first: Int, _ second: Int, holding: [(from: Int, to: Int)] = []) {
        links.insert(Direction(from: first, to: second))
        links.insert(Direction(from: second, to: first))
        for direction in holding {
            hold(from: direction.from, to: direction.to)
        }
        nodes[first].fixture.link(nodes[second].fixture.me)
        nodes[second].fixture.link(nodes[first].fixture.me)
        carry()
    }

    /// Takes the link between `first` and `second` down. What either held for the other is lost with it.
    func unlink(_ first: Int, _ second: Int) {
        carry()
        for direction in [Direction(from: first, to: second), Direction(from: second, to: first)] {
            links.remove(direction)
            holds.remove(direction)
            held[direction] = nil
        }
        nodes[first].fixture.unlink(nodes[second].fixture.me)
        nodes[second].fixture.unlink(nodes[first].fixture.me)
    }

    /// Holds the frames `from` sends `to` until ``release(from:to:order:)``.
    func hold(from: Int, to: Int) {
        holds.insert(Direction(from: from, to: to))
    }

    /// Hands over what `from` held for `to`, in the order `order` gives it, which may also drop or repeat items, and
    /// carries both ways from then on.
    func release(from: Int, to: Int, order: ([Carried]) -> [Carried] = \.self) {
        carry()
        let direction = Direction(from: from, to: to)
        holds.remove(direction)
        let items = held.removeValue(forKey: direction) ?? []
        for item in order(items) {
            deliver(item, direction)
        }
        carry()
    }

    /// Moves every clock on by `milliseconds`, fires what fell due, and carries what that wrote.
    func advance(_ milliseconds: Int64) {
        for node in nodes {
            node.fixture.advance(milliseconds)
        }
        carry()
    }

    /// Puts `fixture` in node `index`'s place, as a reinstall or a restart would: a new engine, nothing of the old one's
    /// still in flight, and no link until the test makes one.
    func replace(_ index: Int, with fixture: EngineFixture) {
        for other in nodes.indices where links.contains(Direction(from: index, to: other)) {
            unlink(index, other)
        }
        nodes[index] = Node(fixture)
    }

    /// Carries everything written since the last call, both ways, until no node writes anything more.
    func carry() {
        for _ in 0..<Self.maxRounds {
            var moved = false
            for index in nodes.indices {
                moved = drain(index) || moved
            }
            guard moved else {
                return
            }
        }
        Issue.record("the lab never went quiet")
    }

    private static let maxRounds = 64

    /// Routes what node `index` wrote since it was last read, and answers whether there was any.
    private func drain(_ index: Int) -> Bool {
        let node = nodes[index]
        let transport = node.fixture.transport
        let frames = transport.written.dropFirst(min(node.framesRead, transport.written.count))
        let digests = transport.digests.dropFirst(min(node.digestsRead, transport.digests.count))
        node.framesRead = transport.written.count
        node.digestsRead = transport.digests.count
        for written in frames {
            let targets = written.to.map { peer in nodes.indices.filter { nodes[$0].fixture.me.nodeId == peer } } ?? Array(nodes.indices)
            for target in targets where target != index {
                route(.frame(written), Direction(from: index, to: target))
            }
        }
        for digest in digests {
            for target in nodes.indices where nodes[target].fixture.me.nodeId == digest.to {
                route(.digest(digest.ids), Direction(from: index, to: target))
            }
        }
        return !frames.isEmpty || !digests.isEmpty
    }

    private func route(_ item: Carried, _ direction: Direction) {
        guard links.contains(direction) else {
            return
        }
        if holds.contains(direction), item.id != nil {
            held[direction, default: []].append(item)
        } else {
            deliver(item, direction)
        }
    }

    private func deliver(_ item: Carried, _ direction: Direction) {
        let sender = nodes[direction.from].fixture.me.nodeId
        let receiver = nodes[direction.to].fixture.engine
        switch item {
        case .frame(let written):
            receiver.receive(InboundFrame(wire: written.wire, envelope: written.envelope, from: sender))
        case .digest(let ids):
            receiver.receiveDigest(ids, from: sender)
        }
    }
}

extension EngineLab {
    /// The ordinary messages node `index` holds in its DM thread with node `peer`, as `id: body`, by id.
    func thread(_ index: Int, with peer: Int) -> [String] {
        let other = self[peer].me.nodeId.string
        return self[index].stores.messages.messages(in: other).filter { $0.kind == .message }.map { "\($0.id): \($0.body)" }.sorted()
    }

    /// The lab's session oracle (`sessionsAgree`, `MeshLab.kt:551-558`): both sides hold a confirmed session on the same root,
    /// from the same era, with opposite roles. A pair where either side holds none has nothing to disagree about.
    func sessionsAgree(_ first: Int, _ second: Int) -> Bool {
        guard let one = self[first].ratchetRecords(of: self[second].me).session,
            let other = self[second].ratchetRecords(of: self[first].me).session
        else {
            return true
        }
        return one.confirmed && other.confirmed && one.root == other.root && one.establishedAt == other.establishedAt
            && one.weAreInitiator != other.weAreInitiator
    }

    /// Whether node `first` and node `second` each hold a session with the other.
    func bothHoldSessions(_ first: Int, _ second: Int) -> Bool {
        self[first].ratchetRecords(of: self[second].me).session != nil && self[second].ratchetRecords(of: self[first].me).session != nil
    }

    /// The lab's convergence check (`assertConverged`): the two DM threads hold the same messages, at least `atLeast` of them,
    /// and the sessions agree.
    func expectConverged(_ first: Int, _ second: Int, atLeast: Int, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        let mine = thread(first, with: second)
        let theirs = thread(second, with: first)
        #expect(mine == theirs, "\(comment): the threads differ", sourceLocation: sourceLocation)
        #expect(mine.count >= atLeast, "\(comment): \(mine.count) messages, \(atLeast) wanted", sourceLocation: sourceLocation)
        #expect(bothHoldSessions(first, second), "\(comment): a session on both sides", sourceLocation: sourceLocation)
        #expect(sessionsAgree(first, second), "\(comment): \(describe(first, second))", sourceLocation: sourceLocation)
    }

    /// Both sides' sessions, for a failure's message.
    func describe(_ first: Int, _ second: Int) -> String {
        [(first, second), (second, first)].map { mine, theirs in
            guard let held = self[mine].ratchetRecords(of: self[theirs].me).session else {
                return "\(mine): no session"
            }
            let root = BlobHash(of: held.root).string.prefix(8)
            return "\(mine): root=\(root) era=\(held.establishedAt) confirmed=\(held.confirmed) initiator=\(held.weAreInitiator)"
        }.joined(separator: " / ")
    }

    /// The DM frames node `from` wrote to node `to` under `id`, re-seals and back-fills included, in the order written.
    func chats(from: Int, to: Int, id: String) -> [Written] {
        let peer = ExactKey(self[to].me.nodeId.string)
        return self[from].transport.written(.chat).filter { written in
            ExactKey(written.envelope.id) == ExactKey(id) && written.envelope.recipientId.map(ExactKey.init) == peer
        }
    }

    /// The distinct seals of `id` node `from` wrote to node `to`: a back-fill re-serves custody's bytes, a re-seal makes
    /// new ones.
    func seals(from: Int, to: Int, id: String) -> Int {
        Set(chats(from: from, to: to, id: id).map(\.wire.signed)).count
    }

    /// The ids node `index`'s custody holds live, at its own clock.
    func liveIds(_ index: Int) -> [String] {
        self[index].stores.custody.liveIds(now: self[index].clock.wallMilliseconds())
    }

    /// The blobs review's custody check after a re-seal, once the exchange has settled: both custodies hold the same ids,
    /// and node `from` wrote node `to` two seals of each id in `resealed`, the original and one re-seal. Our receipts are
    /// cleartext until P5c, so `to`'s receipt for each purged it from both custodies and tombstoned it (`CustodySync`'s
    /// purge, `ForwardSync.onAck`): neither holds it, where P5c's sealed receipt, which purges nothing, would leave it held
    /// once on each side.
    func expectCustodyAgrees(
        _ first: Int, _ second: Int, resealed ids: [String], from: Int, to: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let mine = Set(liveIds(first))
        #expect(!mine.isEmpty && mine == Set(liveIds(second)), "the same ids in both custodies", sourceLocation: sourceLocation)
        for id in ids {
            let held = [first, second].filter { self[$0].stores.custody.contains(id) }
            #expect(held.isEmpty, "\(id): purged on both sides by its receipt, held by \(held)", sourceLocation: sourceLocation)
            #expect(seals(from: from, to: to, id: id) == 2, "\(id): the original and one re-seal", sourceLocation: sourceLocation)
        }
    }
}
