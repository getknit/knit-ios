import KnitStore
import KnitWire

/// The spool plane's synchronous core (ADR 2026-11.adrq, P4a): the scope table, one heal loop and connection per relay,
/// and the one seal cache the relays share, owned by ``Mesh`` beside its links. Every input runs to completion in one
/// turn: each candidate a heal raises is verified, delivered and settled through the engine
/// (``MeshEngine/receiveFromSpool(_:relay:)``) before the heal's next input, and nothing awaits across a delivery.
///
/// P4b's sockets and miners are tasks that post into ``Mesh``; here a driver (a test's, or ``Mesh``'s) opens a relay's
/// connection with ``connected(_:engine:)``, hands it every record with ``receive(_:from:engine:)``, takes what to write
/// with ``takeOutgoing(_:)``, answers stamps with ``stampMined(_:counter:engine:)``, and fires ``tick(engine:)`` at
/// ``nextDeadline``.
///
/// **The table** is read again only between inputs, never inside a store unit, so every input it reads committed: when
/// the ratchet's ``RatchetSessions/generation`` moved (a root replaced, a reset sealed or adopted, an init answered, a
/// session confirmed or forgotten), when ``markTableDirty()`` says an unblock, an acceptance, a deleted thread or a
/// verification moved the gate, when ``block(_:engine:)`` dropped a peer's scopes in its own turn, at the earliest
/// retiring scope's drain end, and every ``reconcileMilliseconds``. Each of
/// its inputs is read in a store unit of its own (``SpoolTableInputs``); one that failed keeps the table and keeps it
/// dirty for the next input. Our own reset bumps the generation, so its peer's scopes leave the table before any heal
/// input after it: nothing sealed under the new root is pushed into the old scope.
internal struct SpoolPlane: CustomStringConvertible, CustomReflectable {
    /// The table's timed reconcile (`RECONCILE_INTERVAL_MS`, `ScopeSync.kt:3373` at knit-next `0832b8462`).
    static let reconcileMilliseconds: Int64 = 60_000

    /// One relay: its heal loop, which outlives every connection, and the connection open now, if any.
    struct Relay {
        var heal: ScopeHeal
        var session: SpoolSession?
        var outgoing: [SpoolSessionOutput] = []
    }

    /// What the plane asks of its miner.
    enum Mining: Equatable, Sendable {
        case mine(SpoolMiningRequest)
        case cancel(SpoolMiningRequest)

        /// The ask a heal's output makes of the miner, or `nil` for a candidate.
        init?(_ output: ScopeHeal.Output) {
            switch output {
            case .mine(let request):
                self = .mine(request)
            case .cancelMining(let request):
                self = .cancel(request)
            case .candidate:
                return nil
            }
        }
    }

    let me: NodeId
    private(set) var table = ScopeTable()
    private(set) var relays: [SpoolRelayHandle: Relay] = [:]
    /// The one seal cache, lent to each heal for the input it runs (P3b's "one seal cache per engine").
    private var seals = ScopeSealCache()
    private var tableDirty = true
    private var readGeneration: Int?
    private var reconcileAt: Int64?
    private var drainEndAt: Int64?
    private var mining: [Mining] = []
    /// Table reads that kept the table because an input could not be read.
    private(set) var unreadableTables = 0

    var description: String { "spool plane: \(table.scopes.count) scopes, \(relays.count) relays" }
    var customMirror: Mirror { Mirror(self, children: [:]) }

    init(me: NodeId) {
        self.me = me
    }

    // MARK: Relays

    /// Carries `relay` from now on, with no connection yet.
    /// P4b's socket and mining tasks call it; until then the tests alone do.
    mutating func add(_ relay: SpoolRelayHandle, engine: MeshEngine) { // swiftlint:disable:this unused_declaration
        guard relays[relay] == nil else {
            return
        }
        var heal = ScopeHeal(relay: relay, me: me)
        heal.adopt(table.scopes)
        relays[relay] = Relay(heal: heal)
        tableDirty = true
        refreshTable(engine: engine)
    }

    /// Drops `relay`, cancelling every stamp its heal was mining.
    /// P4b's socket and mining tasks call it; until then the tests alone do.
    mutating func remove(_ relay: SpoolRelayHandle) { // swiftlint:disable:this unused_declaration
        guard let gone = relays.removeValue(forKey: relay) else {
            return
        }
        for request in gone.heal.mining.values {
            mining.append(.cancel(request))
        }
    }

    /// A socket to `relay` opened.
    /// P4b's socket and mining tasks call it; until then the tests alone do.
    mutating func connected(_ relay: SpoolRelayHandle, engine: MeshEngine) { // swiftlint:disable:this unused_declaration
        refreshTable(engine: engine)
        relays[relay]?.session = SpoolSession(openedAt: engine.clock.monotonicMilliseconds())
        run(relay, engine: engine, nil)
    }

    /// One record off `relay`'s socket.
    /// P4b's socket and mining tasks call it; until then the tests alone do.
    mutating func receive(_ bytes: [UInt8], from relay: SpoolRelayHandle, engine: MeshEngine) { // swiftlint:disable:this unused_declaration
        refreshTable(engine: engine)
        relays[relay]?.session?.receive(bytes)
        run(relay, engine: engine, nil)
    }

    /// `relay`'s socket closed, whoever closed it.
    /// P4b's socket and mining tasks call it; until then the tests alone do.
    mutating func socketClosed(_ relay: SpoolRelayHandle, engine: MeshEngine) { // swiftlint:disable:this unused_declaration
        refreshTable(engine: engine)
        relays[relay]?.session?.socketClosed()
        run(relay, engine: engine, nil)
        relays[relay]?.session = nil
    }

    /// What to write to `relay`'s socket, in order: records, and a close.
    /// P4b's socket and mining tasks call it; until then the tests alone do.
    mutating func takeOutgoing(_ relay: SpoolRelayHandle) -> [SpoolSessionOutput] { // swiftlint:disable:this unused_declaration
        defer { relays[relay]?.outgoing.removeAll() }
        return relays[relay]?.outgoing ?? []
    }

    /// What the miner should start or stop.
    /// P4b's socket and mining tasks call it; until then the tests alone do.
    mutating func takeMining() -> [Mining] { // swiftlint:disable:this unused_declaration
        defer { mining.removeAll() }
        return mining
    }

    /// A stamp search ended: `counter` found, or `nil` when it ran out of tries. A search cancelled because its connection
    /// dropped is never answered (P3b's "what P4 owes").
    /// P4b's socket and mining tasks call it; until then the tests alone do.
    mutating func stampMined( // swiftlint:disable:this unused_declaration
        _ request: SpoolMiningRequest, counter: Int64?, engine: MeshEngine
    ) {
        refreshTable(engine: engine)
        run(request.relay, engine: engine) { heal, session, now in
            heal.stampMined(request, counter: counter, session: &session, now: now)
        }
    }

    // MARK: Inputs from the engine

    /// Custody changed: every scope of every relay looks again. ``Mesh`` calls it where it notices a custody revision
    /// change, beside the advert's digest cue, never per writer.
    mutating func custodyChanged() {
        for relay in relays.keys {
            relays[relay]?.heal.custodyChanged()
        }
    }

    /// Something the gate reads moved (a block or an unblock, an acceptance, a deleted thread, a verification): the table
    /// is read again before the next heal input.
    mutating func markTableDirty() {
        tableDirty = true
    }

    /// Reads the table again now if it is due, and hands every heal the result: a block commit drops its peer's scopes, and
    /// cancels their mining, in the same turn.
    mutating func refreshTable(engine: MeshEngine) {
        guard !relays.isEmpty else {
            return
        }
        let now = engine.clock.monotonicMilliseconds()
        let wall = engine.clock.wallMilliseconds()
        let due =
            tableDirty || readGeneration != engine.ratchet.generation || reconcileAt.map { now >= $0 } != false
            || drainEndAt.map { wall >= $0 } == true
        guard due else {
            return
        }
        let generation = engine.ratchet.generation
        let inputs = engine.spoolTableInputs(now: wall)
        reconcileAt = SpoolSession.later(now, by: Self.reconcileMilliseconds)
        guard let dmScopes = inputs.dmScopes, let accepted = inputs.accepted, let blocked = inputs.blocked, let recent = inputs.recent
        else {
            // A store that could not answer keeps the table, and the next input tries again.
            unreadableTables += 1
            tableDirty = true
            return
        }
        tableDirty = false
        readGeneration = generation
        drainEndAt = dmScopes.compactMap(\.retiringUntil).min()
        let update = table.updated(dmScopes: dmScopes, accepted: accepted, blocked: blocked, recent: recent, relays: Array(relays.keys))
        guard case .table(let next) = update else {
            return
        }
        adopt(next)
    }

    /// `peer` was blocked: its scopes leave the table, and their mining is cancelled, in this turn, whatever the stores
    /// answer; a later read of the blocked set that succeeds decides, and one that fails keeps the table without them.
    mutating func block(_ peer: NodeId, engine: MeshEngine) {
        tableDirty = true
        adopt(table.dropping(peer))
        refreshTable(engine: engine)
    }

    /// Hands every heal `next`: a scope that left cancels its search now, connected or not, since a search can outlive
    /// its connection.
    private mutating func adopt(_ next: ScopeTable) {
        table = next
        for (handle, var state) in relays {
            state.heal.adopt(next.scopes)
            mining += state.heal.drain().compactMap(Mining.init)
            state.session?.retainSubscriptions(next.ids)
            relays[handle] = state
        }
    }

    // MARK: Time

    /// When ``tick(engine:)`` next has something to do, on the monotonic clock. The drain end is on the wall clock, so it
    /// is read at the reconcile at the latest.
    var nextDeadline: Int64? {
        // A plane with no relay keeps no timer: the table is read when the first relay comes.
        guard !relays.isEmpty else {
            return nil
        }
        var deadlines: [Int64?] = [reconcileAt]
        for relay in relays.values {
            let ready = relay.session?.isReady == true
            deadlines.append(relay.heal.nextDeadline(sessionReady: ready))
            deadlines.append(relay.session?.nextDeadline)
        }
        return deadlines.compactMap(\.self).min()
    }

    /// Runs what is due at the engine's clock: the table, then each relay's session and heal timers, and a round where one
    /// is due.
    mutating func tick(engine: MeshEngine) {
        refreshTable(engine: engine)
        for relay in relays.keys.sorted() {
            run(relay, engine: engine) { _, session, now in
                session.tick(now: now.monotonic)
            }
            run(relay, engine: engine) { heal, session, now in
                heal.tick(session: &session, now: now)
            }
            startRoundIfDue(relay, engine: engine)
        }
    }

    /// Starts `relay`'s round when one is due, over one custody read in a unit of its own.
    private mutating func startRoundIfDue(_ relay: SpoolRelayHandle, engine: MeshEngine) {
        guard let state = relays[relay], let session = state.session else {
            return
        }
        let now = SpoolNow(monotonic: engine.clock.monotonicMilliseconds(), wall: engine.clock.wallMilliseconds())
        guard state.heal.wantsRound(sessionReady: session.isReady, now: now) else {
            return
        }
        let read = engine.stores.transactor.atomically { () -> [CarriedFrame]? in engine.stores.custody.liveFrames(now: now.wall) }
        let custody: ScopeHeal.Custody =
            if case .committed(let frames) = read {
                .frames(frames)
            } else {
                .unreadable
            }
        run(relay, engine: engine) { heal, session, now in
            heal.roundStarted(custody, session: &session, now: now)
        }
    }

    // MARK: The turn

    /// Runs `input`, if any, on `relay`'s heal and session with the shared seal cache lent to it, then carries every output until
    /// quiet: records out to ``takeOutgoing(_:)``, events into the heal, each candidate through the engine and settled
    /// before the next, and stamps to the miner.
    private mutating func run(
        _ relay: SpoolRelayHandle, engine: MeshEngine, _ input: ((inout ScopeHeal, inout SpoolSession, SpoolNow) -> Void)?
    ) {
        guard var state = relays[relay] else {
            return
        }
        let now = SpoolNow(monotonic: engine.clock.monotonicMilliseconds(), wall: engine.clock.wallMilliseconds())
        swap(&seals, &state.heal.seals)
        defer {
            swap(&seals, &state.heal.seals)
            relays[relay] = state
        }
        guard var session = state.session else {
            return
        }
        input?(&state.heal, &session, now)
        var quiet = false
        while !quiet {
            quiet = true
            for output in session.drain() {
                quiet = false
                switch output {
                case .send, .close:
                    state.outgoing.append(output)
                case .event(let event):
                    state.heal.handle(event, session: &session, now: now)
                }
                serve(&state, &session, relay: relay, engine: engine, now: now)
            }
            serve(&state, &session, relay: relay, engine: engine, now: now)
        }
        state.session = session
    }

    /// Hands the heal's outputs on: each candidate settled in this turn, before anything else reaches the heal.
    private mutating func serve(
        _ state: inout Relay, _ session: inout SpoolSession, relay: SpoolRelayHandle, engine: MeshEngine, now: SpoolNow
    ) {
        for output in state.heal.drain() {
            if let ask = Mining(output) {
                mining.append(ask)
            } else if case .candidate(let candidate) = output {
                let settlement = engine.receiveFromSpool(candidate, relay: relay)
                state.heal.settle(candidate, settlement, session: &session, now: now)
            }
        }
    }
}
