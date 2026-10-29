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
///
/// A lab made with `crossings` also models each link layer's ``LinkCrossings``: a frame goes over a link at most once per
/// window, either way, and a digest reply leaves out what the link already carried, as ``LinkManager`` has it. Without it
/// every write is carried, which the older labs pin.
final class EngineLab {
    /// A node and the link-level state the lab keeps for it.
    private final class Node {
        var fixture: EngineFixture
        var framesRead = 0
        var digestsRead = 0
        /// Its link layer's memo of what crossed each link, by neighbour: read only in a lab that models crossings.
        var crossings = LinkCrossings<NodeId>()
        /// The neighbours each write, by its index in the transport's log, did not go to, its frame having crossed that link
        /// already: decided as the engine wrote it.
        var skipped: [Int: Set<NodeId>] = [:]
        /// Each write the gate let onto a link, by its index in the transport's log and the neighbour: what the link wrote.
        var passed: [(index: Int, peer: NodeId)] = []

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
    private let modelsCrossings: Bool
    /// One frame a link carried: from node `from` to node `to`, its id.
    struct Carriage {
        let from: Int
        let to: Int
        let id: String
    }

    /// Every frame a link carried, in order.
    private(set) var carriedFrames: [Carriage] = []

    /// A lab over `fixtures`, none of them linked yet, modelling each link's crossings memo when `crossings` says so.
    init(_ fixtures: [EngineFixture], crossings: Bool = false) {
        nodes = fixtures.map(Node.init)
        modelsCrossings = crossings
        for node in nodes {
            watchCrossings(node)
        }
    }

    /// Has `node`'s transport answer `hasCrossed` from its memo, in a lab that models crossings.
    private func watchCrossings(_ node: Node) {
        guard modelsCrossings else {
            return
        }
        node.fixture.transport.crossings = { [weak node] key, peer in
            guard let node else {
                return false
            }
            return node.crossings.hasCrossed(link: peer, key: key, now: node.fixture.clock.monotonicMilliseconds())
        }
        // One write per link per frame, either way, decided as the engine writes, on its clock, before any hold
        // (``LinkManager/send(_:to:)``); the far end stamps it in when it arrives (``deliver(_:_:)``).
        node.fixture.transport.onWrite = { [weak node] written in
            guard let node, let key = FrameKey.ofSigned(written.wire) else {
                return
            }
            let index = node.fixture.transport.written.count - 1
            let now = node.fixture.clock.monotonicMilliseconds()
            for peer in written.to.map({ [$0] }) ?? node.fixture.transport.neighbors.map(\.nodeId) {
                if node.crossings.firstCrossing(link: peer, key: key, now: now) {
                    node.passed.append((index: index, peer: peer))
                } else {
                    node.skipped[index, default: []].insert(peer)
                }
            }
        }
    }

    /// How many times node `from`'s link to node `to` wrote frame `id`, counting from the `since`th entry of its transport's
    /// log: the engine's writes the crossings gate let through, as the radio's `LinkManager.send` writes them (a lab that
    /// models crossings only). A write the gate dropped, such as a router relay of a frame that already crossed, is not one.
    func delivered(of id: String, from: Int, to: Int, since: Int) -> Int {
        let node = nodes[from]
        let peer = nodes[to].fixture.me.nodeId
        let written = node.fixture.transport.written
        return node.passed.filter { pass in
            pass.index >= since && pass.peer == peer && ExactKey(written[pass.index].envelope.id) == ExactKey(id)
        }.count
    }

    /// Forgets what crossed the link between `first` and `second`, as a link going down or coming up anew does.
    private func forgetCrossings(_ first: Int, _ second: Int) {
        nodes[first].crossings.forget(link: nodes[second].fixture.me.nodeId)
        nodes[second].crossings.forget(link: nodes[first].fixture.me.nodeId)
    }

    /// Node `index`'s engine and stores.
    subscript(_ index: Int) -> EngineFixture {
        nodes[index].fixture
    }

    /// Links `first` and `second`, as each one's link layer reports the link up to its engine, and carries what follows.
    /// Each side's HELLO claims `capabilities`: the blob labs add ``Capabilities/blobHave``, without which nobody queries a
    /// holder and nobody answers NONE.
    func link(_ first: Int, _ second: Int, holding: [(from: Int, to: Int)] = [], capabilities: Capabilities = .local) {
        links.insert(Direction(from: first, to: second))
        links.insert(Direction(from: second, to: first))
        forgetCrossings(first, second)
        for direction in holding {
            hold(from: direction.from, to: direction.to)
        }
        nodes[first].fixture.link(nodes[second].fixture.me, capabilities: capabilities)
        nodes[second].fixture.link(nodes[first].fixture.me, capabilities: capabilities)
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
        forgetCrossings(first, second)
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
        watchCrossings(nodes[index])
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
        let first = min(node.framesRead, transport.written.count)
        let frames = transport.written.dropFirst(first)
        let digests = transport.digests.dropFirst(min(node.digestsRead, transport.digests.count))
        node.framesRead = transport.written.count
        node.digestsRead = transport.digests.count
        for (position, written) in frames.enumerated() {
            let skipped = node.skipped.removeValue(forKey: first + position) ?? []
            let targets = written.to.map { peer in nodes.indices.filter { nodes[$0].fixture.me.nodeId == peer } } ?? Array(nodes.indices)
            for target in targets where target != index && !skipped.contains(nodes[target].fixture.me.nodeId) {
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
            if modelsCrossings, let key = FrameKey.ofSigned(written.wire) {
                let to = nodes[direction.to]
                to.crossings.arrived(link: sender, key: key, now: to.fixture.clock.monotonicMilliseconds())
            }
            carriedFrames.append(Carriage(from: direction.from, to: direction.to, id: written.envelope.id))
            receiver.receiveAdmitted(InboundFrame(wire: written.wire, envelope: written.envelope, from: sender))
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
    /// and node `from` wrote node `to` two seals of each id in `resealed`, the original and one re-seal. `to`'s receipt for
    /// each is sealed (phase P5d) and purges nothing, ours included (ADR 2026-09.p6nb, amended), so each id is held once on
    /// each side until its day ends. Custody keeps the first bytes stored under an id (`ForwardSync.kt:75`): `from` its
    /// original, taken in its send unit, and `to` whichever of the two seals reached it first, never a third. The digests
    /// compare ids alone, so the two agree either way.
    func expectCustodyAgrees(
        _ first: Int, _ second: Int, resealed ids: [String], from: Int, to: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let mine = Set(liveIds(first))
        #expect(!mine.isEmpty && mine == Set(liveIds(second)), "the same ids in both custodies", sourceLocation: sourceLocation)
        for id in ids {
            let sealed = chats(from: from, to: to, id: id).map(\.wire.signed)
            let held = [from, to].map { self[$0].stores.custody.frame(id, now: self[$0].clock.wallMilliseconds())?.signed }
            #expect(held[0] != nil && held[0] == sealed.first, "\(id): \(from) holds its original", sourceLocation: sourceLocation)
            #expect(held[1].map(sealed.contains) == true, "\(id): \(to) holds one of its seals", sourceLocation: sourceLocation)
            #expect(seals(from: from, to: to, id: id) == 2, "\(id): the original and one re-seal", sourceLocation: sourceLocation)
        }
    }

    /// The same check across `nodes` when nothing was re-sealed: every custody holds the same ids, and each id in `ids`,
    /// which node `from` sealed to node `to` once, is held in each of them as that one seal's bytes.
    func expectCustodyAgrees(
        _ nodes: [Int], sealedOnce ids: [String], from: Int, to: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let held = nodes.map { Set(liveIds($0)) }
        let agree = held.allSatisfy { $0 == held[0] }
        #expect(!held[0].isEmpty && agree, "the same ids in every custody", sourceLocation: sourceLocation)
        for id in ids {
            let sealed = Set(chats(from: from, to: to, id: id).map(\.wire.signed))
            #expect(sealed.count == 1, "\(id): sealed once", sourceLocation: sourceLocation)
            for node in nodes {
                let bytes = self[node].stores.custody.frame(id, now: self[node].clock.wallMilliseconds())?.signed
                #expect(bytes.map(sealed.contains) == true, "\(id): node \(node) holds its one seal", sourceLocation: sourceLocation)
            }
        }
    }
}
