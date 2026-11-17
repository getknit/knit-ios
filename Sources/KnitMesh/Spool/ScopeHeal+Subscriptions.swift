import KnitCrypto
import KnitWire

/// Subscriptions, refusals, parks and stamps (`subscribe`, `handleScopeError`, `stampFor`, `demanded`,
/// `ScopeSync.kt:2955-2977`, `:3271-3316`; spec §8, C-9.1-5).
extension ScopeHeal {
    /// What a request for `scope` carries for proof of work.
    enum StampNeed: Sendable, Equatable {
        /// Nothing: the spool asked none.
        case unasked
        /// This stamp, mined before and still in its window.
        case stamp(PowStamp)
        /// One is being mined; the request waits for it.
        case waiting
    }

    /// Subscribes every table scope not subscribed on this connection, not parked and not waiting on a stamp, at most one
    /// pass per ``ScopeHeal/healFloorMilliseconds`` (so a spool that refuses `internal` costs a `sub` per interval, not
    /// per record), in `sub`s of at most ``ScopeHeal/subBatch`` scopes. Scopes that left the table are forgotten on the
    /// connection first. The session holds the batch to the spool's `maxScopes`, in the table's order, so a spool's cap
    /// drops retiring scopes and the least recent peers first.
    mutating func syncSubscriptions(_ session: inout SpoolSession, now: SpoolNow) {
        session.retainSubscriptions(Set(states.keys))
        guard session.isReady, subsWanted, now.monotonic >= nextSubAt else {
            return
        }
        var subs: [ScopeSub] = []
        var stamped: Set<SpoolID> = []
        for scope in table where !session.isSubscribed(scope.id) && !isParked(scope.id, now: now.monotonic) {
            switch stampNeed(scope.id, session: session, now: now) {
            case .unasked:
                subs.append(ScopeSub(scope: scope.id.bytes, bounds: ScopeFrames.bounds))
            case .stamp(let stamp):
                subs.append(ScopeSub(scope: scope.id.bytes, bounds: ScopeFrames.bounds, pow: stamp))
                stamped.insert(scope.id)
            case .waiting:
                demandStamp(scope.id, session: session, now: now)
            }
        }
        subsWanted = false
        guard !subs.isEmpty else {
            return
        }
        nextSubAt = SpoolSession.later(now.monotonic, by: Self.healFloorMilliseconds)
        let size = min(subBatch, subs.count)
        lastSubSize = size
        for start in stride(from: 0, to: subs.count, by: size) {
            let sent = session.subscribe(Array(subs[start..<min(start + size, subs.count)]), now: now.monotonic)
            guard !sent.isEmpty else {
                break
            }
            stampedSubs.formUnion(stamped.intersection(sent))
        }
    }

    /// The spool refused a scope (a `sub`'s scoped `err`, or a batch's unscoped one), and the session forgot it
    /// (`handleScopeError`, `:2955-2977`). Only `quota` and `pow` park it, for the session's clamped
    /// ``SpoolRefusal/parkMilliseconds``, which is set for every code, so the gate is the code. A first `pow` for a `sub`
    /// that carried no stamp asks one mined and parks nothing. A `malformed` refusal is the batch's: the next pass sends
    /// `sub`s half the size, down to one scope each (P3a's review). Anything else is subscribed again on the next pass.
    mutating func scopeRefused(_ scope: SpoolID, _ refusal: SpoolRefusal, session: inout SpoolSession, now: SpoolNow) {
        guard states[scope] != nil else {
            return
        }
        let wasStamped = stampedSubs.remove(scope) != nil
        subsWanted = true
        if refusal.code.is(SpoolErrorCode.pow) {
            if !wasStamped, session.powBits > 0, states[scope]?.stampDemanded == false {
                demandStamp(scope, session: session, now: now)
            } else {
                states[scope]?.stamp = nil
                park(scope, for: refusal.parkMilliseconds, now: now)
            }
        } else if refusal.code.is(SpoolErrorCode.quota) {
            park(scope, for: refusal.parkMilliseconds, now: now)
        } else if refusal.code.is(SpoolErrorCode.malformed) {
            subBatch = min(subBatch, max(lastSubSize / Self.subBatchShrink, 1))
        }
    }

    /// Parks `scope` until `now + milliseconds`: neither subscribed nor healed until then (C-9.1-5).
    mutating func park(_ scope: SpoolID, for milliseconds: Int64, now: SpoolNow) {
        states[scope]?.parkedUntil = SpoolSession.later(now.monotonic, by: milliseconds)
        counts.parks += 1
    }

    /// What a request for `scope` carries (`stampFor`, `:3300-3316`): a stamp only after the spool asked for one (C-8-4),
    /// the one held while ``usableStamp(_:session:now:)`` takes it, or a new one asked of the caller.
    func stampNeed(_ scope: SpoolID, session: SpoolSession, now: SpoolNow) -> StampNeed {
        guard session.powBits > 0, let state = states[scope], state.stampDemanded else {
            return .unasked
        }
        if let stamp = usableStamp(scope, session: session, now: now) {
            return .stamp(stamp)
        }
        return .waiting
    }

    /// The stamp held for `scope` while it is still in its window and meets the session's `powBits` (P4b2, this port's
    /// own rule: Kotlin's stamp cache keys by scope alone). A stamp mined for a spool that asked fewer bits is not sent to one
    /// that asks more.
    func usableStamp(_ scope: SpoolID, session: SpoolSession, now: SpoolNow) -> PowStamp? {
        guard let state = states[scope], let stamp = state.stamp, state.stampBits >= session.powBits,
            SpoolPow.reusable(stampDay: stamp.day, nowMs: now.wall)
        else {
            return nil
        }
        return stamp
    }

    /// The spool asked a stamp of `scope`: one is mined for today at the session's bits, unless one is already, one held
    /// meets them, the day's allowance is spent, or the scope is retiring and its drain ends within the table's reconcile.
    /// Every caller passes a scope of the table.
    mutating func demandStamp(_ scope: SpoolID, session: SpoolSession, now: SpoolNow) {
        states[scope]?.stampDemanded = true
        guard session.powBits > 0, mining[scope] == nil, usableStamp(scope, session: session, now: now) == nil else {
            return
        }
        // A retiring scope about to leave the table is not worth a search: it parks until it leaves (P4b2). Both times are
        // this phone's own wall clock; a wrapped difference is far off and parks nothing.
        if let until = scopesById[scope]?.retiringUntil, until &- now.wall < SpoolPlane.reconcileMilliseconds {
            counts.stampsRetiring += 1
            park(scope, for: max(until &- now.wall, SpoolSession.minParkMilliseconds), now: now)
            return
        }
        let day = SpoolPow.utcDay(nowMs: now.wall)
        if states[scope]?.minedDay != day {
            states[scope]?.minedDay = day
            states[scope]?.minedToday = 0
        }
        if let state = states[scope], state.minedToday >= Self.maxStampsPerDay {
            counts.stampsCapped += 1
            park(scope, for: Self.untilNextDay(day, now: now), now: now)
            return
        }
        let request = SpoolMiningRequest(serial: nextSerial, relay: relay, scope: scope, day: day, bits: session.powBits)
        nextSerial += 1
        mining[scope] = request
        outbox.append(.mine(request))
    }

    /// The milliseconds from `now` to the start of UTC day `day + 1`, at least the shortest park and never past a day.
    static func untilNextDay(_ day: Int64, now: SpoolNow) -> Int64 {
        let (start, overflow) = (day &+ 1).multipliedReportingOverflow(by: SpoolPow.dayMilliseconds)
        guard !overflow else {
            return SpoolPow.dayMilliseconds
        }
        let (left, under) = start.subtractingReportingOverflow(now.wall)
        return under ? SpoolPow.dayMilliseconds : min(max(left, SpoolSession.minParkMilliseconds), SpoolPow.dayMilliseconds)
    }

    /// The miner's answer to `request` (P4b2). Found: the stamp is kept with the bits it actually meets and counts toward
    /// ``maxStampsPerDay`` whether a search or the engine's cache produced it, and the scope is subscribed and pushed again
    /// at once. Exhausted: no stamp exists below ``SpoolPow/maxTries`` for that (scope, day, bits), so the scope parks until
    /// the next UTC day after the request's. Over budget: it parks for the answer's park.
    ///
    /// The answer reaches the heal whether or not a session is open (P4b1): `mining` is cleared, the stamp kept and counted
    /// and the scope marked wanted, and only the `sub` waits for a session. So a search outlives the connection that asked
    /// for it, and the next connection's `sub` carries the stamp with no second search.
    /// Answers whether the heal took the answer: one whose serial the heal no longer waits on changes nothing.
    @discardableResult
    mutating func stampMined(
        _ request: SpoolMiningRequest, _ answer: SpoolStampAnswer, session: inout SpoolSession?, now: SpoolNow
    ) -> Bool {
        guard mining[request.scope] == request else {
            return false
        }
        // `adopt` cancels the mining of a scope that leaves the table, so a request still in `mining` is a table scope's.
        mining[request.scope] = nil
        switch answer {
        case .found(let counter, let bits):
            // `demandStamp` set the request's day as `minedDay` when it asked, and asks nothing more while it is mined.
            states[request.scope]?.minedToday += 1
            states[request.scope]?.stamp = PowStamp(counter: counter, day: request.day)
            states[request.scope]?.stampBits = bits
            dirty.insert(request.scope)
            subsWanted = true
            nextSubAt = .min
            if var open = session {
                syncSubscriptions(&open, now: now)
                session = open
            }
        case .exhausted:
            park(request.scope, for: Self.untilNextDay(request.day, now: now), now: now)
        case .overBudget(let milliseconds):
            park(request.scope, for: milliseconds, now: now)
        }
        return true
    }
}
