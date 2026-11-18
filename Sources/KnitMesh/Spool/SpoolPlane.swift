import KnitCrypto
import KnitStore
import KnitWire

/// The spool plane (ADR 2026-11.adrq, P4a and P4b1): the scope table, one heal loop and connection per relay, and the one
/// seal cache the relays share, owned by ``Mesh`` beside its links. Every input runs to completion in one turn: each
/// candidate a heal raises is verified, delivered and settled through the engine (``MeshEngine/receiveFromSpool(_:relay:)``)
/// before the heal's next input, and nothing awaits across a delivery.
///
/// **The plane owns a session's life** (`SpoolPlane+Connections`). It decides when each relay dials and hands ``Mesh`` a
/// ``SocketAction`` for it under a fresh ``SpoolConnectionToken``; the socket's task posts back under that token, and a post
/// under any other is dropped. Every session that began ends through one path, exactly once, in the same turn as the pause,
/// the removal, the dial or write-stall timeout or the socket's close that ended it, and that end clears the relay's queued
/// records, so nothing written for one socket reaches the next ahead of its hello.
///
/// **No session, no heal deadlines.** While a relay has no session, ``nextDeadline`` reports only its dial (none while
/// paused); its heal's tick and parks are read again at the next open. A pause keeps every heal (its accounted, invalid and
/// unpushable sets, stamps, searches and owed listings): only a process start or a removal makes a fresh one.
///
/// **The table** is read again only between inputs, never inside a store unit, so every input it reads committed: when
/// the ratchet's ``RatchetSessions/generation`` moved (a root replaced, a reset sealed or adopted, an init answered, a
/// session confirmed or forgotten), when ``markTableDirty()`` says an unblock, an acceptance, a deleted thread or a
/// verification moved the gate, when ``block(_:engine:)`` dropped a peer's scopes in its own turn, at the earliest
/// retiring scope's drain end, and every ``reconcileMilliseconds``. Each of its inputs is read in a store unit of its own
/// (``SpoolTableInputs``); one that failed keeps the table and keeps it dirty for the next input. Our own reset bumps the
/// generation, so its peer's scopes leave the table before any heal input after it: nothing sealed under the new root is
/// pushed into the old scope.
internal struct SpoolPlane: CustomStringConvertible, CustomReflectable {
    /// The table's timed reconcile (`RECONCILE_INTERVAL_MS`, `ScopeSync.kt:3373` at knit-next `0832b8462`).
    static let reconcileMilliseconds: Int64 = 60_000
    /// The most relays carried at once.
    static let maxRelays = 8

    /// One relay: its heal loop, which outlives every connection, the connection open now, if any, the records waiting
    /// for the socket, and the dial and its bounds.
    struct Relay {
        let url: AcceptedSpoolURL
        var heal: ScopeHeal
        var session: SpoolSession?
        var outgoing: [[UInt8]] = []
        var link = SpoolLink()
        /// The spool's refusals naming no request, by code (``SpoolPlane/knownErrorCodes``, or `other`).
        var errors: [String: Int] = [:]
        /// What the session dropped, by kind.
        var drops: [String: Int] = [:]
        /// Every record the session dropped, of any kind.
        var droppedRecords = 0
        /// The dropped records of a type this build does not know, which the drop window charges by their bytes alone.
        var unknownRecords = 0
        /// The close code of a session this side ended for a fault, until the turn hands it on.
        var faultClose: Int?
    }

    /// What ``Mesh`` does with a relay's socket.
    enum SocketAction: Equatable, Sendable {
        /// Open a socket to `url` and read it under `token`.
        case dial(SpoolRelayHandle, SpoolConnectionToken, AcceptedSpoolURL)
        /// Write one record: the only send in flight.
        case send(SpoolRelayHandle, SpoolConnectionToken, [UInt8])
        /// Cancel the task and close its socket with `code`.
        case close(SpoolRelayHandle, SpoolConnectionToken, code: Int)
        /// Let the reader that waited for the inbound budget read on.
        case resumeReader(SpoolRelayHandle, SpoolConnectionToken)
    }

    /// What the reader does after its post.
    enum ReaderNext: Equatable, Sendable {
        /// Read the next message.
        case next
        /// Wait until ``SocketAction/resumeReader(_:_:)``.
        case park
        /// Stop: the token is over.
        case stop
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

    /// The refusal codes counted by name (§7.2); any other counts as `other`.
    static let knownErrorCodes = [
        SpoolErrorCode.version, SpoolErrorCode.pow, SpoolErrorCode.tombstoned, SpoolErrorCode.quota, SpoolErrorCode.tooLarge,
        SpoolErrorCode.badId, SpoolErrorCode.rate, SpoolErrorCode.notSubscribed, SpoolErrorCode.malformed, SpoolErrorCode.internal,
        SpoolErrorCode.conflict, SpoolErrorCode.ticket,
    ]

    let me: NodeId
    var table = ScopeTable()
    var relays: [SpoolRelayHandle: Relay] = [:]
    /// The earliest each relay may be dialled by the `Retry-After` its last refused dial named, by handle and with no
    /// address, beside ``relays`` rather than in its ``SpoolLink`` (P6): the switch, consent and park each remove a relay
    /// and add it again, and none of them is a reason to dial sooner than it asked. An entry goes once its time has passed,
    /// and the map holds at most ``maxRelays`` (``noteAskedFloor(_:_:now:)``).
    var askedFloors: [SpoolRelayHandle: Int64] = [:]
    /// The one seal cache, lent to each heal for the input it runs (P3b's "one seal cache per engine").
    private var seals = ScopeSealCache()
    var tableDirty = true
    var readGeneration: Int?
    var reconcileAt: Int64?
    var drainEndAt: Int64?
    /// The heals' asks of the miner since the last ``serviceMiner(engine:)``.
    var mining: [Mining] = []
    /// The engine's stamp miner (P4b2): its requests, its one run, its cache and its budget.
    var miner = SpoolMiner()
    /// The next stamp request's serial, lent to each heal for the input it runs.
    var nextSerial: Int64 = 1
    var actions: [SocketAction] = []
    /// Whether the plane is paused: no dial, and no session.
    var paused = true
    var nextToken: Int64 = 1
    var logBook = SpoolLogBook()
    /// Table reads that kept the table because an input could not be read.
    var unreadableTables = 0

    var description: String { "spool plane: \(table.scopes.count) scopes, \(relays.count) relays" }
    var customMirror: Mirror { Mirror(self, children: [:]) }

    init(me: NodeId) {
        self.me = me
    }

    /// The heals' asks of the miner since the last take.
    mutating func takeMining() -> [Mining] {
        defer { mining.removeAll() }
        return mining
    }

    // MARK: The miner

    /// After every input (``Mesh/serviceSpool()``): the heals' asks go to the miner, and what it answers at once (the cache,
    /// the budget) goes back to the heals, after their turn and never inside ``run(_:engine:cause:_:)``'s serve, until an
    /// answer raises no ask. Then the runner's actions. It ends: an answer parks its scope or gives it a stamp, so a scope
    /// asks again only on a later input.
    mutating func serviceMiner(engine: MeshEngine) -> [SpoolMiner.Action] {
        repeat {
            mine(takeMining(), engine: engine)
        } while !mining.isEmpty
        return miner.takeActions()
    }

    /// Hands `asks` to the miner and its answers at once to the heals.
    mutating func mine(_ asks: [Mining], engine: MeshEngine) {
        deliver(miner.take(asks, now: now(engine)), engine: engine)
    }

    /// The runner's result for `run` (``Mesh/spoolStampMined(_:_:)``).
    mutating func searchEnded(_ run: Int64, _ search: SpoolPow.Search, engine: MeshEngine) {
        deliver(miner.ended(run: run, search, now: now(engine)), engine: engine)
    }

    mutating func deliver(_ answers: [SpoolMiner.Answer], engine: MeshEngine) {
        for answer in answers {
            stampMined(answer.request, answer.answer, engine: engine)
        }
    }

    private func now(_ engine: MeshEngine) -> SpoolNow {
        SpoolNow(monotonic: engine.clock.monotonicMilliseconds(), wall: engine.clock.wallMilliseconds())
    }

    /// The miner answered `request`. The answer reaches the heal whether or not the relay has a session
    /// (``ScopeHeal/stampMined(_:_:session:now:)``); one for a relay since removed answers nothing.
    mutating func stampMined(_ request: SpoolMiningRequest, _ answer: SpoolStampAnswer, engine: MeshEngine) {
        refreshTable(engine: engine)
        guard var state = relays[request.relay] else {
            return
        }
        guard state.session != nil else {
            // With no session the heal subscribes nothing, so it asks nothing of the miner here.
            var none: SpoolSession?
            if state.heal.stampMined(request, answer, session: &none, now: now(engine)) {
                state.link.counts.stampsAnsweredOffline += 1
            }
            relays[request.relay] = state
            return
        }
        run(request.relay, engine: engine, cause: .socket(SpoolSocketEnd(.closed))) { heal, session, now in
            var open: SpoolSession? = session
            heal.stampMined(request, answer, session: &open, now: now)
            if let open {
                session = open
            }
        }
    }

    // MARK: Time

    /// When ``tick(engine:)`` next has something to do, on the monotonic clock. A relay with no session reports its dial
    /// alone, and the table's reconcile and drain end only matter while a session is open: the next open reads the table.
    var nextDeadline: Int64? {
        var deadlines: [Int64?] = []
        var anyOpen = false
        for relay in relays.values {
            switch relay.link.phase {
            case .idle:
                deadlines.append(paused ? nil : relay.link.nextDialAt)
            case .dialing(_, let openBy):
                deadlines.append(openBy)
            case .open:
                anyOpen = true
                let ready = relay.session?.isReady == true
                deadlines.append(relay.heal.nextDeadline(sessionReady: ready))
                deadlines.append(relay.session?.nextDeadline)
                deadlines.append(relay.link.stallDeadline)
                if relay.link.readerParked {
                    deadlines.append(relay.link.inbound.readyAt)
                }
            }
        }
        if anyOpen {
            deadlines.append(reconcileAt)
        }
        return deadlines.compactMap(\.self).min()
    }

    /// Runs what is due at the engine's clock: the table, each relay's dial, its connection's bounds, its session and heal
    /// timers, and a round where one is due.
    mutating func tick(engine: MeshEngine) {
        refreshTable(engine: engine)
        for relay in relays.keys.sorted() {
            if let link = relays[relay]?.link {
                linkTimers(relay, link, engine: engine)
            }
            guard relays[relay]?.session != nil else {
                continue
            }
            run(relay, engine: engine, cause: .socket(SpoolSocketEnd(.closed))) { _, session, now in
                session.tick(now: now.monotonic)
            }
            run(relay, engine: engine, cause: .socket(SpoolSocketEnd(.closed))) { heal, session, now in
                heal.tick(session: &session, now: now)
            }
            startRoundIfDue(relay, engine: engine)
        }
        dialDue(engine: engine)
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
        run(relay, engine: engine, cause: .socket(SpoolSocketEnd(.closed))) { heal, session, now in
            heal.roundStarted(custody, session: &session, now: now)
        }
    }

    // MARK: The turn

    /// Runs `input`, if any, on `relay`'s heal and session with the shared seal cache lent to it, then carries every output until
    /// quiet: records into the relay's queue, events into the heal, each candidate through the engine and settled before the
    /// next, and stamps to the miner. A session that ended in the turn is torn down in it (``finish(_:_:engine:)``), for
    /// its own fault when it ended itself for one, and for `cause` otherwise: the socket's close, unless the input was one
    /// of the plane's ends.
    mutating func run(
        _ relay: SpoolRelayHandle, engine: MeshEngine, cause: SpoolSessionEnd,
        _ input: ((inout ScopeHeal, inout SpoolSession, SpoolNow) -> Void)?
    ) {
        guard var state = relays[relay], var session = state.session else {
            return
        }
        let now = SpoolNow(monotonic: engine.clock.monotonicMilliseconds(), wall: engine.clock.wallMilliseconds())
        swap(&seals, &state.heal.seals)
        state.heal.nextSerial = nextSerial
        state.heal.outboundFull = state.link.queuedBytes >= SpoolLink.maxQueuedBytes
        input?(&state.heal, &session, now)
        var quiet = false
        while !quiet {
            quiet = true
            for output in session.drain() {
                quiet = false
                switch output {
                case .send(let bytes):
                    queue(bytes, on: &state, now: now.monotonic)
                case .close(let code):
                    state.faultClose = code
                case .event(let event):
                    note(event, in: &state)
                    state.heal.handle(event, session: &session, now: now)
                }
                serve(&state, &session, relay: relay, engine: engine, now: now)
            }
            serve(&state, &session, relay: relay, engine: engine, now: now)
        }
        swap(&seals, &state.heal.seals)
        nextSerial = state.heal.nextSerial
        state.session = session
        if session.phase == .closed {
            let ended: SpoolSessionEnd = if let fault = session.fault { .fault(fault) } else { cause }
            finish(&state, ended, engine: engine)
        }
        relays[relay] = state
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

    /// Counts what the session dropped or the spool refused unasked, for `status` and the log: the drop's kind and the
    /// refusal's cleaned code, never its message.
    private func note(_ event: SpoolSessionEvent, in state: inout Relay) {
        switch event {
        case .dropped(let drop):
            state.drops[SpoolLogBook.word(for: drop), default: 0] += 1
            state.droppedRecords += 1
            if case .unknown = drop {
                state.unknownRecords += 1
            }
        case .spoolError(let refusal):
            // A code the spec names counts under its name; anything else a spool wrote is one word, so no line carries it.
            let code = Self.knownErrorCodes.first { refusal.code.is($0) } ?? "other"
            state.errors[code, default: 0] += 1
        default:
            break
        }
    }
}
