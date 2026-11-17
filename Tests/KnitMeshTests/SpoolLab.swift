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
    private var connections: [FakeSpool.Connection?]
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
        revisions = fixtures.map(\.engine.custodyRevision)
        sent = Array(repeating: [], count: fixtures.count)
        mined = Array(repeating: [], count: fixtures.count)
        for index in fixtures.indices {
            planes[index].add(relay, engine: radio[index].engine)
        }
    }

    subscript(_ index: Int) -> EngineFixture {
        radio[index]
    }

    /// Opens node `index`'s connection to the spool, and carries what follows.
    func connect(_ index: Int) {
        connections[index] = spool.connect()
        planes[index].connected(relay, engine: radio[index].engine)
        pump()
    }

    /// Closes node `index`'s connection.
    func disconnect(_ index: Int) {
        if let connection = connections[index] {
            spool.drop(connection)
        }
        connections[index] = nil
        planes[index].socketClosed(relay, engine: radio[index].engine)
        pump()
    }

    /// Puts `fixture` in node `index`'s place with a fresh plane, as a restart or a reinstall does: the old connection is
    /// gone with the old process.
    func replace(_ index: Int, with fixture: EngineFixture) {
        if let connection = connections[index] {
            spool.drop(connection)
        }
        connections[index] = nil
        radio.replace(index, with: fixture)
        planes[index] = SpoolPlane(me: fixture.me.nodeId)
        planes[index].add(relay, engine: fixture.engine)
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
    private func exchange(_ index: Int, over connection: FakeSpool.Connection) -> Bool {
        let engine = radio[index].engine
        var moved = false
        for output in planes[index].takeOutgoing(relay) {
            moved = true
            switch output {
            case .send(let bytes):
                if let record = SpoolRecord(decoding: bytes) {
                    sent[index].append(record)
                }
                spool.receive(bytes, from: connection)
            case .close:
                spool.drop(connection)
                connections[index] = nil
                planes[index].socketClosed(relay, engine: engine)
            case .event:
                break
            }
        }
        for outgoing in spool.take(connection) {
            moved = true
            switch outgoing {
            case .record(let bytes):
                planes[index].receive(bytes, from: relay, engine: engine)
            case .close:
                connections[index] = nil
                planes[index].socketClosed(relay, engine: engine)
            }
        }
        return moved
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
