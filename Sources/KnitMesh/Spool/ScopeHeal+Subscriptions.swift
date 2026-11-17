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
    /// the one held while it is still in its window, or a new one asked of the caller.
    func stampNeed(_ scope: SpoolID, session: SpoolSession, now: SpoolNow) -> StampNeed {
        guard session.powBits > 0, let state = states[scope], state.stampDemanded else {
            return .unasked
        }
        if let stamp = state.stamp, SpoolPow.reusable(stampDay: stamp.day, nowMs: now.wall) {
            return .stamp(stamp)
        }
        return .waiting
    }

    /// The spool asked a stamp of `scope`: one is mined for today at the session's bits, unless one is already.
    /// Every caller passes a scope of the table.
    mutating func demandStamp(_ scope: SpoolID, session: SpoolSession, now: SpoolNow) {
        states[scope]?.stampDemanded = true
        guard session.powBits > 0, mining[scope] == nil else {
            return
        }
        if let stamp = states[scope]?.stamp, SpoolPow.reusable(stampDay: stamp.day, nowMs: now.wall) {
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
        let request = SpoolMiningRequest(relay: relay, scope: scope, day: day, bits: session.powBits)
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

    /// A stamp the caller mined, or `nil` when the search ran out (`SpoolPow.mine`'s budget). A stamp lets the scope be
    /// subscribed and pushed again at once; none parks it for the floor, as a refused stamp would be.
    mutating func stampMined(_ request: SpoolMiningRequest, counter: Int64?, session: inout SpoolSession, now: SpoolNow) {
        guard mining[request.scope] == request else {
            return
        }
        // `adopt` cancels the mining of a scope that leaves the table, so a request still in `mining` is a table scope's.
        mining[request.scope] = nil
        if let counter {
            // Only a stamp mined counts toward the day's allowance; a search that ran out or was cancelled does not.
            // `demandStamp` set the request's day as `minedDay` when it asked, and asks nothing more while it is mined.
            states[request.scope]?.minedToday += 1
            states[request.scope]?.stamp = PowStamp(counter: counter, day: request.day)
            dirty.insert(request.scope)
            subsWanted = true
            nextSubAt = .min
            syncSubscriptions(&session, now: now)
        } else {
            park(request.scope, for: SpoolSession.minParkMilliseconds, now: now)
        }
    }
}
