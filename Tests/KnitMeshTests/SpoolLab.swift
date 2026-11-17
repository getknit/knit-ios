import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// Engines of this port over one ``FakeSpool`` and, when a test links them, the radios of an ``EngineLab``: the P4a driver
/// (ADR 2026-11.adrq). Each node owns a ``SpoolPlane`` as ``Mesh`` does, and the lab ferries each relay's records between
/// the plane and its connection, hands the plane every custody revision change as ``Mesh/settle()`` does, and mines a
/// stamp the moment one is asked for. Every clock moves together; the spool's runs on the wall clock.
final class SpoolLab {
    /// The radios, and each node's engine and stores.
    let radio: EngineLab
    let spool: FakeSpool
    /// The relay every node dials.
    let relay = SpoolRelayHandle(number: 1)
    var planes: [SpoolPlane]
    /// The address the relay is added under.
    static let url = AcceptedSpoolURL("wss://lab.spool.test/spool/v1", allowCleartext: false)
    private var connections: [FakeSpool.Connection?]
    /// Each node's open token, and the dial its plane last asked for that the lab has not answered.
    private(set) var tokens: [SpoolConnectionToken?]
    private(set) var pendingDials: [SpoolConnectionToken?]
    private var revisions: [Int]
    /// Every record each node sent the spool, in order.
    private(set) var sent: [[SpoolRecord]]
    /// Every mining request each node's plane made.
    private(set) var mined: [[SpoolMiningRequest]]
    /// Whether a stamp is mined the moment it is asked for; otherwise it waits in ``pendingMining``.
    var minesAtOnce = true
    /// The searches asked for and not answered, and those the planes cancelled.
    private(set) var pendingMining: [SpoolMiningRequest] = []
    private(set) var cancelledMining: [SpoolMiningRequest] = []

    /// A lab over `fixtures`, none linked by radio and none connected to the spool yet; each plane carries the relay.
    init(_ fixtures: [EngineFixture], spool: FakeSpool? = nil) {
        radio = EngineLab(fixtures)
        self.spool = spool ?? FakeSpool(now: fixtures.first?.clock.wallMilliseconds() ?? 0)
        planes = fixtures.map { SpoolPlane(me: $0.me.nodeId) }
        connections = Array(repeating: nil, count: fixtures.count)
        tokens = Array(repeating: nil, count: fixtures.count)
        pendingDials = Array(repeating: nil, count: fixtures.count)
        revisions = fixtures.map(\.engine.custodyRevision)
        sent = Array(repeating: [], count: fixtures.count)
        mined = Array(repeating: [], count: fixtures.count)
        for index in fixtures.indices {
            Self.add(&planes[index], relay, engine: radio[index].engine)
        }
    }

    subscript(_ index: Int) -> EngineFixture {
        radio[index]
    }

    /// Adds the lab's relay to `plane`, paused: the lab dials only when a test connects.
    static func add(_ plane: inout SpoolPlane, _ relay: SpoolRelayHandle, engine: MeshEngine) {
        guard let url else {
            Issue.record("the lab's relay address is refused")
            return
        }
        _ = plane.add(relay, url: url, engine: engine)
    }

    /// Opens node `index`'s connection to the spool, and carries what follows: the plane is resumed, and the dial it asks
    /// for opens.
    func connect(_ index: Int) {
        let engine = radio[index].engine
        if pendingDials[index] == nil {
            planes[index].resume(engine: engine)
            collect(index)
        }
        guard let token = pendingDials[index] else {
            Issue.record("the plane asked for no dial")
            return
        }
        pendingDials[index] = nil
        connections[index] = spool.connect()
        tokens[index] = token
        _ = planes[index].opened(relay, token: token, engine: engine)
        pump()
    }

    /// A second open on node `index`'s token with no close between, as a new socket: the old session must give way.
    func reopen(_ index: Int) -> Bool {
        guard let token = tokens[index] else {
            return false
        }
        if let connection = connections[index] {
            spool.drop(connection)
        }
        connections[index] = spool.connect()
        let opened = planes[index].opened(relay, token: token, engine: radio[index].engine)
        pump()
        return opened
    }

    /// Closes node `index`'s connection, as a pause does: the session ends and the heal stays.
    func disconnect(_ index: Int) {
        if let connection = connections[index] {
            spool.drop(connection)
        }
        connections[index] = nil
        tokens[index] = nil
        pendingDials[index] = nil
        planes[index].pause(engine: radio[index].engine)
        collect(index)
        pump()
    }

    /// The socket under node `index`'s open token closed from the far side.
    func socketClosed(_ index: Int, _ end: SpoolSocketEnd = SpoolSocketEnd(.closed)) {
        guard let token = tokens[index] else {
            return
        }
        if let connection = connections[index] {
            spool.drop(connection)
        }
        connections[index] = nil
        tokens[index] = nil
        planes[index].socketClosed(relay, token: token, end, engine: radio[index].engine)
        collect(index)
        pump()
    }

    /// Takes node `index`'s socket actions that are not sends: a dial is held until a test connects, and a close of the open
    /// token drops the connection. Answers the sends.
    @discardableResult
    private func collect(_ index: Int) -> [[UInt8]] {
        var sends: [[UInt8]] = []
        for action in planes[index].takeActions() {
            switch action {
            case .dial(_, let token, _):
                pendingDials[index] = token
            case .send(_, let token, let bytes) where token == tokens[index]:
                sends.append(bytes)
            case .close(_, let token, _) where token == tokens[index]:
                if let connection = connections[index] {
                    spool.drop(connection)
                }
                connections[index] = nil
                tokens[index] = nil
            case .close(_, let token, _) where token == pendingDials[index]:
                pendingDials[index] = nil
            default:
                break
            }
        }
        return sends
    }

    /// Puts `fixture` in node `index`'s place with a fresh plane, as a restart or a reinstall does: the old connection is
    /// gone with the old process.
    func replace(_ index: Int, with fixture: EngineFixture) {
        if let connection = connections[index] {
            spool.drop(connection)
        }
        connections[index] = nil
        tokens[index] = nil
        pendingDials[index] = nil
        radio.replace(index, with: fixture)
        planes[index] = SpoolPlane(me: fixture.me.nodeId)
        Self.add(&planes[index], relay, engine: fixture.engine)
        revisions[index] = fixture.engine.custodyRevision
    }

    /// Moves every clock on by `milliseconds`, fires every engine's and plane's timers, and carries what that wrote.
    func advance(_ milliseconds: Int64) {
        radio.advance(milliseconds)
        spool.advance(to: radio[0].clock.wallMilliseconds())
        for index in planes.indices {
            planes[index].tick(engine: radio[index].engine)
        }
        pump()
    }

    /// Steps `count` times, `milliseconds` apart.
    func run(_ count: Int, every milliseconds: Int64 = ScopeHeal.healFloorMilliseconds) {
        for _ in 0..<count {
            advance(milliseconds)
        }
    }

    /// Carries the radios, the custody changes and the spool's records both ways until nothing moves.
    func pump() {
        for _ in 0..<Self.maxRounds {
            radio.carry()
            var moved = false
            for index in planes.indices {
                moved = settle(index) || moved
            }
            guard moved else {
                return
            }
        }
        Issue.record("the spool lab never went quiet")
    }

    private static let maxRounds = 256

    /// What ``Mesh/settle()`` does for the plane, then one exchange with the spool. Answers whether anything moved.
    private func settle(_ index: Int) -> Bool {
        let engine = radio[index].engine
        if engine.custodyRevision != revisions[index] {
            revisions[index] = engine.custodyRevision
            planes[index].custodyChanged()
        }
        planes[index].refreshTable(engine: engine)
        let asked = mine(index)
        guard let connection = connections[index] else {
            collect(index)
            return asked
        }
        return exchange(index, over: connection) || asked
    }

    /// Answers or holds what node `index`'s plane asked of its miner. Answers whether it asked anything.
    private func mine(_ index: Int) -> Bool {
        let engine = radio[index].engine
        var moved = false
        for request in planes[index].takeMining() {
            moved = true
            switch request {
            case .mine(let asked):
                mined[index].append(asked)
                guard minesAtOnce else {
                    pendingMining.append(asked)
                    continue
                }
                let counter = SpoolPow.mine(scopeId: asked.scope.bytes, day: asked.day, bits: asked.bits)
                planes[index].stampMined(asked, counter: counter, engine: engine)
            case .cancel(let cancelled):
                cancelledMining.append(cancelled)
                pendingMining.removeAll { $0 == cancelled }
            }
        }
        return moved
    }

    /// Carries node `index`'s records to the spool and the spool's back. Answers whether any moved.
    /// Every send completes at once, so the plane's one send in flight never holds the next.
    private func exchange(_ index: Int, over connection: FakeSpool.Connection) -> Bool {
        let engine = radio[index].engine
        var moved = false
        var sends = collect(index)
        while !sends.isEmpty, let token = tokens[index] {
            moved = true
            for bytes in sends {
                if let record = SpoolRecord(decoding: bytes) {
                    sent[index].append(record)
                }
                spool.receive(bytes, from: connection)
                planes[index].sent(relay, token: token, ok: true, engine: engine)
            }
            sends = collect(index)
        }
        guard connections[index] == connection, let token = tokens[index] else {
            return true
        }
        for outgoing in spool.take(connection) {
            moved = true
            switch outgoing {
            case .record(let bytes):
                _ = planes[index].receive(.binary(bytes), from: relay, token: token, engine: engine)
            case .close(let code):
                connections[index] = nil
                tokens[index] = nil
                planes[index].socketClosed(relay, token: token, SpoolSocketEnd(.closed, code: code), engine: engine)
            }
            guard tokens[index] == token else {
                collect(index)
                break
            }
        }
        return moved
    }
}

extension SpoolLab {
    /// Answers every search node `index`'s plane is waiting on, as a runner would, whether or not it is connected.
    func answerMining(_ index: Int) {
        let asked = pendingMining.filter { $0.relay == relay && mined[index].contains($0) }
        for request in asked {
            pendingMining.removeAll { $0 == request }
            let counter = SpoolPow.mine(scopeId: request.scope.bytes, day: request.day, bits: request.bits)
            planes[index].stampMined(request, counter: counter, engine: radio[index].engine)
        }
        pump()
    }

    /// Takes node `index`'s actions now, as ``Mesh`` does after every input.
    @discardableResult
    func takeActions(_ index: Int) -> [[UInt8]] {
        collect(index)
    }

    /// Marks node `index`'s table dirty and settles, as ``Mesh`` does after a block, an acceptance or a verification.
    func markTableDirty(_ index: Int) {
        planes[index].markTableDirty()
        pump()
    }

    /// Node `index` blocks `peer`, as ``Mesh/block(_:)`` does: the engine's block, then the plane's, then a settle.
    func block(_ index: Int, _ peer: NodeId) {
        radio[index].engine.block(peer)
        planes[index].block(peer, engine: radio[index].engine)
        pump()
    }

    /// Hands node `index`'s plane `candidate` as its relay's heal would, and answers the settlement: the door alone.
    func deliver(_ candidate: ScopeCandidate, to index: Int, relay: SpoolRelayHandle? = nil) -> ScopeHeal.Settlement {
        radio[index].engine.receiveFromSpool(candidate, relay: relay ?? self.relay)
    }

    // MARK: Oracles

    /// Clears node `index`'s record log.
    func forgetSent(_ index: Int) {
        sent[index].removeAll()
    }

    /// How many `list` records node `index` sent.
    func lists(_ index: Int) -> Int {
        sent[index].count { if case .list = $0 { true } else { false } }
    }

    /// How many records of any scope operation (`sub`, `list`, `pull`, `push`) node `index` sent naming `scope`.
    func operations(_ index: Int, on scope: SpoolID) -> Int {
        sent[index].count { record in
            switch record {
            case .sub(let sub):
                sub.subs.contains { $0.scope == scope.bytes }
            case .list(let list):
                list.scope == scope.bytes
            case .pull(let pull):
                pull.scope == scope.bytes
            case .push(let push):
                push.scope == scope.bytes
            default:
                false
            }
        }
    }

    /// The scopes node `index`'s table carries, live ones first.
    func scopes(_ index: Int) -> [SpoolScope] {
        planes[index].table.scopes
    }

    /// Node `index`'s heal loop.
    func heal(_ index: Int) -> ScopeHeal? {
        planes[index].relays[relay]?.heal
    }

    /// The spool's digest of `scope`.
    func spoolDigest(_ scope: SpoolID) -> UInt64 {
        ScopeCrypto.digest(of: spool.liveIds(scope).map(\.bytes))
    }

    /// The live frames node `index`'s custody holds between it and node `peer`, as the scope's rule admits them, by id.
    func pairIds(_ index: Int, with peer: Int) -> Set<String> {
        let me = radio[index].me.nodeId
        let other = radio[peer].me.nodeId
        let frames = radio[index].stores.custody.liveFrames(now: radio[index].clock.wallMilliseconds())
        return Set(frames.filter { ScopeFrames.eligible($0.envelope, me: me, peer: other) }.map(\.envelope.id))
    }

    /// Every blob the spool holds in `scope`, opened under `keys`.
    func opened(_ scope: SpoolScope) -> [(sig: [UInt8], envelope: RelayEnvelope)] {
        guard let held = spool.scopes[scope.id]?.live else {
            return []
        }
        return held.compactMap { blob in
            guard let opened = ScopeCrypto.open(scope.keys, blobId: blob.id.bytes, blob: blob.data),
                let envelope = try? RelayEnvelope(decoding: opened.signed)
            else {
                return nil
            }
            return (opened.sig, envelope)
        }
    }
}
