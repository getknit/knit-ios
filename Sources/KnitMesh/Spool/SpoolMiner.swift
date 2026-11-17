import KnitCrypto
import KnitWire

/// One search the runner hashes: ``SpoolPow/mine(scopeId:day:bits:from:shouldStop:)`` for one value, from `from`, under the
/// miner's run number.
internal struct SpoolMinerJob: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    let run: Int64
    let scope: SpoolID
    let day: Int64
    let bits: Int
    let from: Int64

    var description: String { "run \(run): \(scope) day \(day), \(bits) bits from \(from)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The engine's stamp miner as a value (ADR 2026-11.adrq, P4b2), owned by ``SpoolPlane``: the requests the heals asked for
/// by serial, the values they wait on, the one run, the cache (``SpoolMinerCache``) and the budget (``SpoolMinerBudget``).
/// Only the runner is off the actor: it hashes one job with a stop flag and posts the result, which reaches ``ended(run:_:now:)``.
///
/// - **One search per value, many requests.** A value is (scope, day, bits). Every request for it attaches to it, across
///   relays, and at most one run goes engine-wide. A cancel detaches its serial; the runner is told to stop only when none is
///   left, and a request that attaches to a value whose run is stopping clears the flag again, unless the plane is paused.
/// - **Exactly one ending per request:** one answer (found, exhausted or over budget), or its own cancel. A stopped run is
///   never answered: its value is queued again from the counter it reached while requests are attached, or dropped.
/// - **Answers at once.** The cache is read when a request is asked and whenever the queue is looked at, so a request the
///   cache answers, or one the budget cannot hold, is answered in the turn it is asked. When the budget cannot hold a queued
///   value, every request on it is answered over budget, with the park until the short shares hold its whole range.
/// - **Which relay pays.** A value several relays ask for is charged to the least-spent of those relays whose share holds
///   its range (ties by handle); it is refused for want of a relay share only when none holds. The engine's window and the
///   peer's share bind the whole value, since its scope has one peer.
/// - **Order.** A free runner takes the value whose charged relay has spent the fewest counters in the window, then whose
///   peer has, then the scope's rank in the table (live before retiring, most recent activity first), then the oldest
///   request.
/// - **Pause.** No run starts while paused; a pause stops the running one, whose requests stay attached, and the resume
///   starts it again from the counter it reached, before any other value, whether the stopped search's result lands before
///   the resume or after it.
///
/// It prints counts alone, and mirrors nothing: it holds peer ids, as the budget's shares need, and they never leave.
internal struct SpoolMiner: Sendable, CustomStringConvertible, CustomReflectable {
    /// What the runner is told.
    enum Action: Sendable, Equatable {
        /// Hash this job and post its result.
        case start(SpoolMinerJob)
        /// Set the run's stop flag.
        case stop(run: Int64)
        /// Clear it: a request attached again before the runner looked.
        case proceed(run: Int64)
    }

    /// What the miner has done, engine-wide, for `status` and the log.
    struct Counts: Sendable, Equatable {
        /// Runs started, resumed ones included.
        var runs = 0
        /// Runs that found a stamp.
        var found = 0
        /// Runs that covered every counter and found none.
        var exhausted = 0
        /// Runs stopped before they ended.
        var stopped = 0
        /// Runs started from a counter a stopped run reached.
        var resumed = 0
        /// Values answered over budget because the engine's window could not hold the search.
        var overBudget = 0
        /// Values answered over budget because no share of a relay asking for them could.
        var overRelayShare = 0
        /// Values answered over budget because their peer's share could not.
        var overPeerShare = 0
        /// Requests the cache answered with no run.
        var fromCache = 0
        /// Asks for a scope the miner's table no longer carried, not taken (the same batch cancels them).
        var unheldScopes = 0
    }

    /// A search's value: every request for it is served by one run.
    struct Value: Hashable, Sendable {
        let scope: SpoolID
        let day: Int64
        let bits: Int

        init(_ request: SpoolMiningRequest) {
            scope = request.scope
            day = request.day
            bits = request.bits
        }

        var key: SpoolMinerCache.Key { SpoolMinerCache.Key(scope: scope, day: day) }
    }

    /// The requests a value serves, oldest serial first, and its scope's peer.
    struct Waiting: Sendable {
        var serials: [Int64]
        let peer: NodeId
    }

    /// The run in flight: its value and job, the relay and peer it is charged to, and whether its stop flag is set.
    struct Running: Sendable {
        let value: Value
        let job: SpoolMinerJob
        let relay: SpoolRelayHandle
        let peer: NodeId
        var stopping = false
        /// Whether a pause set the stop flag, so a stopped result resumes first even when it lands after the resume.
        var stoppedByPause = false
    }

    /// One request's answer, for the plane to hand its heal.
    struct Answer: Sendable, Equatable {
        let request: SpoolMiningRequest
        let answer: SpoolStampAnswer
    }

    /// The attached requests, by serial.
    private(set) var requests: [Int64: SpoolMiningRequest] = [:]
    /// Every value with a request attached, and the running one, which may have none left while it stops.
    private(set) var values: [Value: Waiting] = [:]
    private(set) var running: Running?
    /// Whether runs wait: the plane starts paused, as it does.
    private(set) var paused = true
    private(set) var cache = SpoolMinerCache()
    /// The window's spend: only ``ended(run:_:now:)`` charges it, and a test may charge a share before it asks.
    var budget = SpoolMinerBudget()
    private(set) var counts = Counts()
    /// The table's scopes, by rank, and each one's peer.
    private var ranks: [SpoolID: Int] = [:]
    private var peers: [SpoolID: NodeId] = [:]
    /// The value a pause stopped with requests still attached, which the resume starts before any other.
    private var resumeFirst: Value?
    private var nextRun: Int64 = 1
    private var actions: [Action] = []

    var description: String { "miner: \(requests.count) requests, \(values.count) values, \(running == nil ? "idle" : "running")" }
    var customMirror: Mirror { Mirror(self, children: [:]) }

    /// What the runner should do, in order, since the last take.
    mutating func takeActions() -> [Action] {
        defer { actions.removeAll() }
        return actions
    }

    /// Takes the scope table: the ranks the order reads, each scope's peer, and what the cache keeps first.
    mutating func adopt(_ scopes: [SpoolScope]) {
        ranks = [:]
        peers = [:]
        for (rank, scope) in scopes.enumerated() where ranks[scope.id] == nil {
            ranks[scope.id] = rank
            peers[scope.id] = scope.peer
        }
    }

    // MARK: Inputs

    /// Takes the heals' asks in order, then answers what it can at once and starts a run if none goes. A `.mine` for a scope
    /// the table no longer carries is not taken: the table change that dropped it also cancelled it, later in the same batch.
    mutating func take(_ asks: [SpoolPlane.Mining], now: SpoolNow) -> [Answer] {
        for ask in asks {
            switch ask {
            case .mine(let request):
                if let peer = peers[request.scope] {
                    attach(request, peer: peer)
                } else {
                    counts.unheldScopes += 1
                }
            case .cancel(let request):
                detach(request)
            }
        }
        return schedule(now: now)
    }

    /// The runner's result for `run`. Charges exactly its `tried`, records what it learnt, answers every request still
    /// attached when it found or exhausted, and queues the value again from where it stopped when it was stopped with
    /// requests attached. A result for any other run is dropped.
    mutating func ended(run: Int64, _ search: SpoolPow.Search, now: SpoolNow) -> [Answer] {
        guard let current = running, current.job.run == run else {
            return []
        }
        running = nil
        budget.charge(search.tried, relay: current.relay, peer: current.peer, now: now.monotonic)
        let value = current.value
        let table = Set(ranks.keys)
        var answers: [Answer] = []
        switch search {
        case .found(let counter, _):
            counts.found += 1
            let bits = SpoolPow.leadingZeroBits(SpoolPow.digest(scopeId: value.scope.bytes, day: value.day, n: counter))
            cache.found(value, counter: counter, bits: bits, table: table)
            answers = finish(value, .found(counter: counter, bits: bits))
        case .exhausted:
            counts.exhausted += 1
            cache.exhausted(value, table: table)
            answers = finish(value, .exhausted)
        case .cancelled(let tried):
            counts.stopped += 1
            cache.reached(value, counter: current.job.from + tried, table: table)
            if values[value]?.serials.isEmpty == true {
                values[value] = nil
            } else if current.stoppedByPause {
                resumeFirst = value
            }
        }
        return answers + schedule(now: now)
    }

    /// Stops the running search and starts none until ``resume(now:)``.
    mutating func pause() {
        paused = true
        guard var run = running else {
            return
        }
        // A run already stopping because no request was left is still the pause's to resume first.
        run.stoppedByPause = true
        if !run.stopping {
            run.stopping = true
            actions.append(.stop(run: run.job.run))
        }
        running = run
    }

    /// Lets runs start again: the running search, stopped by the pause with requests still attached, carries on, and a
    /// queued one starts.
    mutating func resume(now: SpoolNow) -> [Answer] {
        paused = false
        if var run = running, run.stopping, values[run.value]?.serials.isEmpty == false {
            run.stopping = false
            running = run
            actions.append(.proceed(run: run.job.run))
        }
        return schedule(now: now)
    }

    // MARK: Requests

    private mutating func attach(_ request: SpoolMiningRequest, peer: NodeId) {
        let value = Value(request)
        requests[request.serial] = request
        values[value, default: Waiting(serials: [], peer: peer)].serials.append(request.serial)
        if var run = running, run.value == value, run.stopping, !paused {
            run.stopping = false
            running = run
            actions.append(.proceed(run: run.job.run))
        }
    }

    private mutating func detach(_ request: SpoolMiningRequest) {
        guard let held = requests.removeValue(forKey: request.serial) else {
            return
        }
        let value = Value(held)
        values[value]?.serials.removeAll { $0 == held.serial }
        guard values[value]?.serials.isEmpty == true else {
            return
        }
        guard var run = running, run.value == value else {
            values[value] = nil
            return
        }
        if !run.stopping {
            run.stopping = true
            running = run
            actions.append(.stop(run: run.job.run))
        }
    }

    /// Answers every request on `value` with `answer`, and forgets the value.
    private mutating func finish(_ value: Value, _ answer: SpoolStampAnswer) -> [Answer] {
        let serials = [values.removeValue(forKey: value)].compactMap(\.self).flatMap(\.serials)
        return serials.compactMap { serial in requests.removeValue(forKey: serial).map { Answer(request: $0, answer: answer) } }
    }

    // MARK: The queue

    /// A value waiting for a run: its scope's peer and rank in the table, its oldest request, the counters its search needs,
    /// and the relay it is charged to.
    private struct Queued {
        let value: Value
        let peer: NodeId
        let rank: Int
        let oldest: SpoolMiningRequest
        let need: Int64
        let relay: SpoolRelayHandle
    }

    /// Answers the queued values the cache or the budget settles, then starts the first in order when no run goes and the
    /// plane is not paused.
    private mutating func schedule(now: SpoolNow) -> [Answer] {
        cache.prune(wall: now.wall)
        var answers: [Answer] = []
        for entry in queued(now: now) {
            if let answer = cache.answer(entry.value) {
                let settled = finish(entry.value, answer)
                counts.fromCache += settled.count
                answers += settled
                continue
            }
            if let short = budget.shortfall(need: entry.need, relay: entry.relay, peer: entry.peer, now: now.monotonic) {
                answers += finish(entry.value, .overBudget(parkMilliseconds: short.parkMilliseconds))
                count(short.share)
            }
        }
        guard running == nil, !paused else {
            return answers
        }
        let waiting = queued(now: now)
        let stopped = waiting.first { $0.value == resumeFirst }
        resumeFirst = nil
        if let first = stopped ?? waiting.min(by: { order($0, now: now).lexicographicallyPrecedes(order($1, now: now)) }) {
            start(first)
        }
        return answers
    }

    /// The values waiting for a run, oldest request first.
    /// A value whose scope left the table is not among them: the table change that dropped it cancelled its requests.
    private func queued(now: SpoolNow) -> [Queued] {
        values.compactMap { value, waiting -> Queued? in
            guard value != running?.value, let rank = ranks[value.scope] else {
                return nil
            }
            let need = SpoolPow.maxTries - cache.resumeFrom(value)
            let asking = waiting.serials.compactMap { requests[$0] }
            return asking.first.map { oldest in
                let relay = charged(asking.map(\.relay), fallback: oldest.relay, need: need, now: now)
                return Queued(value: value, peer: waiting.peer, rank: rank, oldest: oldest, need: need, relay: relay)
            }
        }
        .sorted { $0.oldest.serial < $1.oldest.serial }
    }

    /// The relay a value several relays ask for is charged to: the least-spent in the window whose share holds `need`, ties
    /// by handle; when none holds it, the one whose share frees soonest, which the budget then refuses.
    private func charged(_ relays: [SpoolRelayHandle], fallback: SpoolRelayHandle, need: Int64, now: SpoolNow) -> SpoolRelayHandle {
        func key(_ relay: SpoolRelayHandle) -> [Int64] {
            let frees = budget.relayFreesAt(relay, need: need, now: now.monotonic)
            return [frees ?? Int64.min, budget.spent(relay: relay, now: now.monotonic), Int64(relay.number)]
        }
        return relays.reduce(fallback) { best, relay in key(relay).lexicographicallyPrecedes(key(best)) ? relay : best }
    }

    /// The order a free runner takes values in: the charged relay's spend in the window, the peer's, the scope's rank, the
    /// oldest request.
    private func order(_ entry: Queued, now: SpoolNow) -> [Int64] {
        let relay = budget.spent(relay: entry.relay, now: now.monotonic)
        return [relay, budget.spent(peer: entry.peer, now: now.monotonic), Int64(entry.rank), entry.oldest.serial]
    }

    private mutating func start(_ entry: Queued) {
        let from = cache.resumeFrom(entry.value)
        let value = entry.value
        let job = SpoolMinerJob(run: nextRun, scope: value.scope, day: value.day, bits: value.bits, from: from)
        nextRun += 1
        running = Running(value: value, job: job, relay: entry.relay, peer: entry.peer)
        counts.runs += 1
        if from > 0 {
            counts.resumed += 1
        }
        actions.append(.start(job))
    }

    private mutating func count(_ share: SpoolMinerBudget.Share) {
        switch share {
        case .engine:
            counts.overBudget += 1
        case .relay:
            counts.overRelayShare += 1
        case .peer:
            counts.overPeerShare += 1
        }
    }
}
