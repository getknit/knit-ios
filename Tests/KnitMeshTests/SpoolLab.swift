import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// Engines of this port over one ``FakeSpool`` and, when a test links them, the radios of an ``EngineLab``: the P4a driver
/// (ADR 2026-11.adrq). Each node owns a ``SpoolPlane`` as ``Mesh`` does, and the lab ferries each relay's records between
/// the plane and its connection, hands the plane every custody revision change as ``Mesh/settle()`` does, and carries the
/// heals' stamp asks through the plane's miner (P4b2), running each search the moment the miner starts it, or holding it for
/// the test. Every clock moves together; the spool's runs on the wall clock.
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
    /// Whether the heals' asks go to the plane's miner; otherwise they wait in ``pendingMining`` and the test answers them
    /// with ``answerMining(_:)``, as P4b1's tests did before the miner.
    var minesAtOnce = true
    /// Whether the miner's runs wait in ``heldRuns`` for ``endRun(_:_:)``; otherwise each runs at once with ``SpoolPow``.
    var holdsRuns = false
    /// The runs held, by node, oldest first.
    private(set) var heldRuns: [(index: Int, job: SpoolMinerJob)] = []
    /// Every action each node's miner asked of its runner.
    private(set) var runnerActions: [[SpoolMiner.Action]]
    /// The searches asked for and not answered, and those the planes cancelled.
    private(set) var pendingMining: [SpoolMiningRequest] = []
    private(set) var cancelledMining: [SpoolMiningRequest] = []

    /// A lab over `fixtures`, none linked by radio and none connected to the spool yet; each plane carries the relay.
    init(_ fixtures: [EngineFixture], spool: FakeSpool? = nil, crossings: Bool = false) {
        radio = EngineLab(fixtures, crossings: crossings)
        self.spool = spool ?? FakeSpool(now: fixtures.first?.clock.wallMilliseconds() ?? 0)
        planes = fixtures.map { SpoolPlane(me: $0.me.nodeId) }
        connections = Array(repeating: nil, count: fixtures.count)
        tokens = Array(repeating: nil, count: fixtures.count)
        pendingDials = Array(repeating: nil, count: fixtures.count)
        revisions = fixtures.map(\.engine.custodyRevision)
        sent = Array(repeating: [], count: fixtures.count)
        mined = Array(repeating: [], count: fixtures.count)
        runnerActions = Array(repeating: [], count: fixtures.count)
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

    /// Carries node `index`'s heals' asks to its miner, as ``Mesh/serviceSpool()`` does, or holds them; then runs or holds
    /// what the miner starts. Answers whether anything moved.
    private func mine(_ index: Int) -> Bool {
        let engine = radio[index].engine
        var moved = false
        repeat {
            let asks = planes[index].takeMining()
            for ask in asks {
                moved = true
                switch ask {
                case .mine(let asked):
                    mined[index].append(asked)
                    if !minesAtOnce {
                        pendingMining.append(asked)
                    }
                case .cancel(let cancelled):
                    cancelledMining.append(cancelled)
                    pendingMining.removeAll { $0 == cancelled }
                }
            }
            if minesAtOnce {
                planes[index].mine(asks, engine: engine)
            }
        } while !planes[index].mining.isEmpty
        for action in planes[index].miner.takeActions() {
            moved = true
            runnerActions[index].append(action)
            guard case .start(let job) = action else {
                continue
            }
            if holdsRuns {
                heldRuns.append((index, job))
            } else {
                let search = SpoolPow.mine(scopeId: job.scope.bytes, day: job.day, bits: job.bits, from: job.from)
                planes[index].searchEnded(job.run, search, engine: engine)
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
            planes[index].stampMined(request, HealMember.found(request), engine: radio[index].engine)
        }
        pump()
    }

    /// The runner returns node `index`'s oldest held run with `search`, or with what a search from its counter finds when
    /// `search` is `nil`. Answers the job.
    @discardableResult
    func endRun(_ index: Int, _ search: SpoolPow.Search? = nil) -> SpoolMinerJob? {
        guard let at = heldRuns.firstIndex(where: { $0.index == index }) else {
            return nil
        }
        let job = heldRuns.remove(at: at).job
        let result = search ?? SpoolPow.mine(scopeId: job.scope.bytes, day: job.day, bits: job.bits, from: job.from)
        planes[index].searchEnded(job.run, result, engine: radio[index].engine)
        pump()
        return job
    }

    /// Clears node `index`'s record log.
    func forgetSent(_ index: Int) {
        sent[index].removeAll()
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
}
