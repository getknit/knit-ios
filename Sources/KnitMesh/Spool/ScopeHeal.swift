import KnitWire

/// One relay's heal loop over the DM scopes it carries (`ScopeSync.Worker`, knit-next `ScopeSync.kt:1884-2290`,
/// `:2883-3263` at `0832b8462`, with `2c32655bf`'s re-anchor; spec §9.1–9.4, §9.6; ADR 2026-11.adrq), as a value.
///
/// It keeps what outlives a connection, per scope and keyed by ``SpoolScope/id`` alone, with no peer id anywhere in it:
/// - **the accounted set** (C-9.6): delivered blob ids custody did not keep, folded in beside what custody holds so a
///   scope whose spool outlives custody still converges, and never pulled again;
/// - **the invalid set** (C-9.3): pulled blobs that failed, never an `event`'s, never pulled again;
/// - **the unpushable set** (this port's own, ADR 2026-11.adrq, amended): held frames this relay will never take from us,
///   left out of the local fold until a listing names them, so a converged scope stops listing (knit/knit-next#188);
/// - a scope's park after a `quota` or `pow` refusal, its stamp, and when it last healed.
///
/// Each set holds at most 512 ids, the oldest dropped. Everything per connection (anchors, claims, requests in flight)
/// is the ``SpoolSession``'s, which every input that acts on the spool takes `inout`; the claims are never duplicated
/// here.
///
/// **One round at a time,** a state machine rather than one pure step, since each scope's list, pulls and pushes wait on
/// the spool. ``wantsRound(sessionReady:now:)`` says when one is due; the caller reads custody once
/// (`CustodyStore.liveFrames`) and starts it with ``roundStarted(_:session:now:)``, then feeds every ``SpoolSessionEvent``
/// the session drains to ``handle(_:session:now:)``, and calls ``tick(session:now:)`` at ``nextDeadline(sessionReady:)``.
/// The heal's own outputs (``drain()``) are candidates to verify and deliver, settled with ``settle(_:_:session:now:)``
/// before the next input, and stamps to mine or cancel.
///
/// **When a scope heals.** A scope is marked dirty when its `digest` moved or grew (the session reports only those), when
/// custody changed (every scope), when a round accepted, pushed or learnt something for it, and when a listing never came
/// while the session stayed up. A dirty scope heals at most once per ``healFloorMilliseconds``, and the
/// ``tickMilliseconds`` tick heals every scope.
internal struct ScopeHeal: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The timed round (`TICK_INTERVAL_MS`, `ScopeSync.kt:3374`).
    static let tickMilliseconds: Int64 = 60_000
    /// The least time between two heals of one scope a dirty mark asks for (P3b's design pass): a digest flood costs
    /// one listing per scope per interval. Kotlin heals on every mark.
    static let healFloorMilliseconds: Int64 = 5000
    /// The most live ids a listing may name (`accountBound` for a DM scope, `BLOB_SET_MAX`): what the sets can hold.
    static let maxListedIds = BoundedIDSet.defaultBound
    /// The most tombstones a listing may name (`tombstoneBound`, `:3246`): `max(2 × maxFrames, 1024)` over the
    /// `maxFrames` this side declared, never the spool's echo.
    static let maxListedTombstones = max(tombstonesPerFrame * ScopeFrames.maxFrames, minTombstoneBound)
    /// §12.2's tombstone bound per declared frame, and its floor (`MIN_TOMBSTONE_BOUND`).
    static let tombstonesPerFrame = 2
    static let minTombstoneBound = 1024
    /// The most stamps mined per scope per UTC day, counting only those mined; past it the scope parks until the day
    /// rolls.
    static let maxStampsPerDay = 2
    /// What a `sub` batch is divided by after the spool refuses one as `malformed` (P3a's review).
    static let subBatchShrink = 2
    /// The ids a `pull` names when the spool's hello gave no `maxPull` (`DEFAULT_MAX_PULL`, `:3407`).
    static let defaultMaxPull = 64

    /// The relay this loop heals.
    let relay: SpoolRelayHandle
    /// This node.
    let me: NodeId
    /// The scopes, in the table's order.
    private(set) var table: [SpoolScope] = []
    var scopesById: [SpoolID: SpoolScope] = [:]
    var states: [SpoolID: ScopeState] = [:]
    var dirty: Set<SpoolID> = []
    var timedDue = false
    var nextTickAt: Int64?
    /// No round before this, after one custody could not serve.
    var roundFloorUntil = Int64.min
    var round: Round?
    var step: Step?
    var seals = ScopeSealCache()
    var intake = SpoolIntake()
    var mining: [SpoolID: SpoolMiningRequest] = [:]
    /// The scopes whose `sub` on this connection carried a stamp.
    var stampedSubs: Set<SpoolID> = []
    /// The most scopes one `sub` names, halved after an unscoped `malformed` refusal.
    var subBatch = Int.max
    var lastSubSize = Int.max
    var nextSubAt = Int64.min
    var subsWanted = true
    var outbox: [Output] = []
    var counts = Counts()

    /// What it has done, and nothing it holds: no node id, no whole scope id, no frame's bytes (P3b's security review).
    var description: String {
        "heal \(relay): \(table.count) scopes, \(dirty.count) dirty, \(round == nil ? "idle" : "in a round"), \(counts)"
    }

    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }

    init(relay: SpoolRelayHandle, me: NodeId) {
        self.relay = relay
        self.me = me
    }

    /// Everything asked of the caller since the last drain, in order.
    mutating func drain() -> [Output] {
        defer { outbox.removeAll() }
        return outbox
    }

    /// The local fold `scope`'s last heal compared, or `nil` before one.
    /// Read by the tests alone, through `@testable`, which `swiftlint analyze` (Sources only) does not see.
    func localFold(_ scope: SpoolID) -> UInt64? { // swiftlint:disable:this unused_declaration
        states[scope]?.localFold
    }

    /// `scope`'s state: its accounted, invalid and unpushable sets, park and stamp.
    /// Read by the tests alone, through `@testable`, which `swiftlint analyze` (Sources only) does not see.
    func state(_ scope: SpoolID) -> ScopeState? { // swiftlint:disable:this unused_declaration
        states[scope]
    }

    /// Whether `scope` is parked at `now`.
    func isParked(_ scope: SpoolID, now: Int64) -> Bool {
        states[scope]?.parkedUntil.map { now < $0 } == true
    }

    // MARK: The table

    /// Takes the scope table (``ScopeTable/scopes``): a scope that left takes its state with it and its mining is
    /// cancelled; a new one is dirty and subscribed at the next chance. Its subscriptions go at the next input that holds
    /// the session.
    mutating func adopt(_ scopes: [SpoolScope]) {
        let ids = Set(scopes.map(\.id))
        for gone in states.keys where !ids.contains(gone) {
            states[gone] = nil
            dirty.remove(gone)
            stampedSubs.remove(gone)
            if let request = mining.removeValue(forKey: gone) {
                outbox.append(.cancelMining(request))
            }
        }
        for scope in scopes where states[scope.id] == nil {
            states[scope.id] = ScopeState()
            dirty.insert(scope.id)
        }
        table = scopes
        scopesById = [:]
        for scope in scopes where scopesById[scope.id] == nil {
            scopesById[scope.id] = scope
        }
        round?.due.removeAll { !ids.contains($0) }
        if let current = step, !ids.contains(current.scope.id) {
            // A pull in flight gives back what its worst case did not use.
            if case .pulling = current.phase {
                intake.refund(bytes: current.pullReserved - min(current.pullReceived, current.pullReserved))
            }
            // Its answer, when it comes, answers nothing; the next tick moves the round on.
            step = nil
        }
        subsWanted = true
        nextSubAt = .min
    }

    /// Custody moved: every scope looks again (`markAllDirty`).
    mutating func custodyChanged() {
        dirty.formUnion(table.map(\.id))
    }

    /// Marks `scope` for the next round, if the table carries it.
    mutating func markDirty(_ scope: SpoolID) {
        if states[scope] != nil {
            dirty.insert(scope)
        }
    }

    // MARK: Time

    /// Whether a round is due: none running, the session ready, and the tick due or a dirty scope past its floor.
    func wantsRound(sessionReady: Bool, now: SpoolNow) -> Bool {
        guard round == nil, sessionReady, now.monotonic >= roundFloorUntil else {
            return false
        }
        return timedDue || table.contains { isDue($0.id, now: now.monotonic) }
    }

    /// When ``tick(session:now:)`` next has something to do, or a round may be due.
    func nextDeadline(sessionReady: Bool) -> Int64? {
        var deadlines = states.values.compactMap(\.parkedUntil)
        if let nextTickAt {
            deadlines.append(nextTickAt)
        }
        if case .rateWait(let until)? = step?.phase {
            deadlines.append(until)
        }
        if round != nil, step == nil {
            deadlines.append(.min)
        }
        if sessionReady, timedDue, round == nil {
            deadlines.append(roundFloorUntil)
        }
        if sessionReady {
            if subsWanted {
                deadlines.append(nextSubAt)
            }
            if round == nil {
                for scope in dirty where states[scope]?.parkedUntil == nil {
                    deadlines.append(max(eligibleAt(scope), roundFloorUntil))
                }
            }
        }
        return deadlines.min()
    }

    /// Runs what is due at `now`: the 60 s tick, parks that ended, a `rate` wait that ended, and the subscriptions.
    mutating func tick(session: inout SpoolSession, now: SpoolNow) {
        // A scope that left the table mid-round took its step with it; the round goes on with the rest.
        if step == nil, round != nil {
            advance(&session, now: now)
        }
        if nextTickAt == nil {
            nextTickAt = SpoolSession.later(now.monotonic, by: Self.tickMilliseconds)
        } else if let due = nextTickAt, now.monotonic >= due {
            timedDue = true
            nextTickAt = SpoolSession.later(now.monotonic, by: Self.tickMilliseconds)
        }
        for (scope, state) in states {
            if let until = state.parkedUntil, now.monotonic >= until {
                states[scope]?.parkedUntil = nil
                dirty.insert(scope)
                subsWanted = true
            }
        }
        if case .rateWait(let until)? = step?.phase, now.monotonic >= until {
            nextPush(&session, now: now)
            advance(&session, now: now)
        }
        syncSubscriptions(&session, now: now)
    }

    /// Whether `scope` is dirty, not parked, and past its floor.
    func isDue(_ scope: SpoolID, now: Int64) -> Bool {
        dirty.contains(scope) && !isParked(scope, now: now) && now >= eligibleAt(scope)
    }

    func eligibleAt(_ scope: SpoolID) -> Int64 {
        guard let last = states[scope]?.lastHealAt else {
            return .min
        }
        return SpoolSession.later(last, by: Self.healFloorMilliseconds)
    }

    // MARK: Events

    /// Reads one event the session drained. Candidates it raises are settled by the caller before its next input.
    mutating func handle(_ event: SpoolSessionEvent, session: inout SpoolSession, now: SpoolNow) {
        switch event {
        case .connected:
            subsWanted = true
            nextSubAt = .min
            nextTickAt = SpoolSession.later(now.monotonic, by: Self.tickMilliseconds)
            syncSubscriptions(&session, now: now)
        case .digest(let scope):
            // A digest is the spool holding the scope, so it asks no stamp again until it sheds it (`handleDigest`).
            states[scope]?.stampDemanded = false
            markDirty(scope)
        case .live(let arrival):
            accept(arrival, .live, request: nil, session: &session, now: now)
        case .pulled(let request, let arrival):
            accept(arrival, .pulled, request: request, session: &session, now: now)
        case .servedOversize(_, _, let bytes):
            servedOversize(bytes: bytes, session: &session, now: now)
        case .answered(let request, let reply):
            answered(request, reply, session: &session, now: now)
        case .scopeRefused(let scope, let refusal):
            scopeRefused(scope, refusal, session: &session, now: now)
        case .subscriptionLapsed:
            subsWanted = true
        case .ended:
            sessionEnded()
        case .spoolError, .dropped:
            break
        }
    }

    /// The connection is gone: the round with it, and what the spool knew of this connection's `sub`s. Dirty marks
    /// stay, and the next session's `connected` subscribes everything again.
    mutating func sessionEnded() {
        round = nil
        step = nil
        stampedSubs.removeAll()
        subsWanted = true
        nextSubAt = .min
    }
}
