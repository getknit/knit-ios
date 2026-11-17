import KnitCrypto
import KnitStore
import KnitWire

/// A round, scope by scope: compare, list, pull, push, re-anchor (`healLocked` and `reconcileListing`,
/// `ScopeSync.kt:1910-1992`, with `2c32655bf`'s re-anchor).
extension ScopeHeal {
    /// Starts a round over the custody read `custody` (`healAll`, `:1884-1900`): the subscriptions first, then each due
    /// scope in the table's order. Due are every scope on the tick, and otherwise the dirty ones past their floor. An
    /// unreadable custody skips the round and leaves every mark standing, so the next try is a floor away.
    mutating func roundStarted(_ custody: Custody, session: inout SpoolSession, now: SpoolNow) {
        syncSubscriptions(&session, now: now)
        guard round == nil, session.isReady else {
            return
        }
        guard case .frames(let frames) = custody else {
            counts.unreadableRounds += 1
            roundFloorUntil = SpoolSession.later(now.monotonic, by: Self.healFloorMilliseconds)
            return
        }
        let timed = timedDue
        let due = table.map(\.id).filter { scope in
            !isParked(scope, now: now.monotonic) && (timed || isDue(scope, now: now.monotonic))
        }
        timedDue = false
        dirty.subtract(due)
        round = Round(due: due, frames: frames)
        advance(&session, now: now)
    }

    /// Moves the round on until it waits on the spool or ends.
    mutating func advance(_ session: inout SpoolSession, now: SpoolNow) {
        while step == nil, var current = round {
            guard !current.due.isEmpty else {
                round = nil
                return
            }
            let id = current.due.removeFirst()
            round = current
            // `adopt` takes a scope that leaves the table out of `due`, so every id here has its scope and its state.
            if let scope = scopesById[id], let state = states[id] {
                startStep(scope, state, frames: current.frames, session: &session, now: now)
            }
        }
    }

    /// One scope's look (`healLocked`): its local fold against the spool's anchor, and a LIST only on a mismatch.
    ///
    /// The local fold is the held frames' blob ids, less the unpushable ones, XOR the accounted ids custody does not hold
    /// (C-9.6-3, `:1925-1928`): never both, or an id back in custody would cancel itself out of the fold.
    private mutating func startStep(
        _ scope: SpoolScope, _ stored: ScopeState, frames: [CarriedFrame], session: inout SpoolSession, now: SpoolNow
    ) {
        let id = scope.id
        var state = stored
        let held = seals.held(frames, in: scope, me: me)
        let heldIds = Set(held.map(\.id))
        state.unpushable.removeAll { !heldIds.contains($0) }
        state.stickyUnpushable.formIntersection(state.unpushable.members)
        let fold =
            Self.fold(held.lazy.map(\.id).filter { !state.unpushable.contains($0) })
            ^ Self.fold(state.accounted.ordered.lazy.filter { !heldIds.contains($0) })
        state.localFold = fold
        state.lastHealAt = now.monotonic
        states[id] = state
        // The `sub` has not been answered yet: there is nothing to compare against (`:1931`).
        guard let anchor = session.anchor(id), anchor.digest != fold else {
            return
        }
        // The session sends a LIST for every scope it anchored while it stands.
        if let request = session.list(id, now: now.monotonic) {
            counts.listings += 1
            step = Step(
                scope: scope,
                held: held,
                heldIds: heldIds,
                listedAgainst: anchor.digest,
                accountedBefore: state.accounted.members,
                invalidBefore: state.invalid.members,
                phase: .listing(request: request)
            )
        }
    }

    /// A request's terminal answer, read against the step that waits on it.
    mutating func answered(_ request: Int64, _ reply: SpoolReply, session: inout SpoolSession, now: SpoolNow) {
        guard let current = step else {
            return
        }
        switch current.phase {
        case .listing(let waiting) where waiting == request:
            listingAnswered(reply, current, session: &session, now: now)
        case .pulling(let waiting) where waiting == request:
            pullAnswered(reply, current.scope.id, session: &session, now: now)
        case .pushing(let waiting, let blob, let stamped) where waiting == request:
            pushAnswered(blob, stamped: stamped, reply, session: &session, now: now)
        default:
            return
        }
        advance(&session, now: now)
    }

    /// The LIST's answer: a listing, or none. A listing that never came (`:1955-1961`) is asked again while the session
    /// stands, since a spool that went quiet strikes out on the connection's silent-request rule; on a closed one the
    /// session's end is the cue.
    private mutating func listingAnswered(_ reply: SpoolReply, _ current: Step, session: inout SpoolSession, now: SpoolNow) {
        guard case .listing(let live, let tombstones) = reply else {
            step = nil
            if session.isReady {
                markDirty(current.scope.id)
            }
            return
        }
        // `adopt` clears the step of a scope that leaves the table, so a step's scope has its state.
        if let state = states[current.scope.id] {
            listed((live, tombstones), current, state, session: &session, now: now)
        }
    }

    /// A pull's end: what the spool no longer holds, and what it served past our `maxBlob`, quarantined (§9.3). A pull
    /// that failed ends the pulling (`pullMissing`'s `?: return`); the pushes still run.
    private mutating func pullAnswered(_ reply: SpoolReply, _ scope: SpoolID, session: inout SpoolSession, now: SpoolNow) {
        // What the pull's worst case did not use goes back to the hour; an oversize blob was charged as it came.
        if let current = step {
            intake.refund(bytes: current.pullReserved - min(current.pullReceived, current.pullReserved))
            step?.pullReserved = 0
            step?.pullReceived = 0
        }
        if case .pulled(let missing, let oversize) = reply {
            step?.gone.formUnion(missing)
            for id in oversize {
                quarantine(id, in: scope)
            }
        } else {
            step?.batches.removeAll()
        }
        nextPull(&session, now: now)
    }

    /// A listing came (`reconcileListing` from `:1963`): refused whole past the bounds, then what it teaches, then the
    /// pulls of what this phone lacks.
    private mutating func listed(
        _ listing: (live: [SpoolID], tombstones: [SpoolID]), _ waiting: Step, _ stored: ScopeState, session: inout SpoolSession,
        now: SpoolNow
    ) {
        var current = waiting
        let (live, tombstones) = listing
        var state = stored
        // `plausible` (`:2038-2047`): refused whole, never truncated, or a partial view would re-anchor us on it.
        guard live.count <= Self.maxListedIds, tombstones.count <= Self.maxListedTombstones else {
            counts.overlongListings += 1
            step = nil
            return
        }
        current.listed = live
        current.listedSet = Set(live)
        current.tombstones = Set(tombstones)
        noteListing(&current, &state, session: session, now: now)
        // `wanted` (`:1973-1978`): listed, and neither held, quarantined, handled on this connection nor accounted.
        var named: Set<SpoolID> = []
        let wanted = live.filter { id in
            !current.heldIds.contains(id) && !state.invalid.contains(id) && !state.accounted.contains(id)
                && !session.hasClaimed(current.scope.id, blobId: id) && named.insert(id).inserted
        }
        let size = max(session.limits?.maxPull ?? Self.defaultMaxPull, 1)
        current.batches = stride(from: 0, to: wanted.count, by: size).map { Array(wanted[$0..<min($0 + size, wanted.count)]) }
        states[current.scope.id] = state
        step = current
        nextPull(&session, now: now)
    }

    /// What a listing teaches before the pulls (`noteListing`, `:2010-2026`): it prunes the accounted and invalid ids the
    /// spool no longer lists, only from what was there before the LIST, so an id accounted while the LIST was in flight is
    /// never taken for one the spool let go; it moves held ids in and out of the unpushable set; and it accounts what this
    /// connection delivered that custody no longer holds. Sets ``Step/learnt`` when any of it changed the local fold.
    private mutating func noteListing(_ current: inout Step, _ state: inout ScopeState, session: SpoolSession, now: SpoolNow) {
        let listedSet = current.listedSet
        if state.accounted.removeAll(where: { current.accountedBefore.contains($0) && !listedSet.contains($0) }) {
            current.learnt = true
        }
        if state.invalid.removeAll(where: { current.invalidBefore.contains($0) && !listedSet.contains($0) }) {
            current.learnt = true
        }
        // The unpushable set: a listed id is back in the fold; a held id the listing leaves out and this relay will never
        // take from us leaves it. A pushable id never goes in.
        for held in current.held {
            if listedSet.contains(held.id) {
                if state.unpushable.remove(held.id) {
                    current.learnt = true
                }
            } else if pushable(held, current, session: session, now: now) {
                // A listing reason that lapsed (a tombstone the spool let go, a scope it shed) gives the frame back; a
                // push this relay refused stays refused.
                if !state.stickyUnpushable.contains(held.id), state.unpushable.remove(held.id) {
                    current.learnt = true
                }
            } else {
                if state.unpushable.insert(held.id) {
                    counts.unpushable += 1
                    current.learnt = true
                }
            }
        }
        // A listed blob this connection already delivered that custody no longer holds was swept or evicted since: it is
        // accounted now, as its delivery would have accounted it had custody refused it then (C-9.6-1). Kotlin leaves it to
        // the next connection's re-pull, so a member that pulled a frame lists every tick from the day custody sweeps it.
        for id in current.listed where !current.heldIds.contains(id) && session.hasClaimed(current.scope.id, blobId: id) {
            if state.accounted.insert(id) {
                counts.accounted += 1
                current.learnt = true
            }
        }
    }

    /// Whether `held` passes every gate a push meets on this relay (`pushable` and `mayRefill`, `:2130-2174`): not
    /// tombstoned, the rule's refill (never a retiring scope, never our own flagged reset), alive in a 48 h scope, and no
    /// larger than the tighter of the spool's `maxBlob` and ours.
    private func pushable(_ held: HeldBlob, _ current: Step, session: SpoolSession, now: SpoolNow) -> Bool {
        !current.tombstones.contains(held.id) && ScopeFrames.mayRefill(held.envelope, me: me, scope: current.scope)
            && !ScopeFrames.deadOnArrival(held.envelope, ttl: ScopeFrames.ttlMilliseconds, now: now.wall)
            && held.sealed.blob.count <= min(session.limits?.maxBlob ?? Int.max, ScopeFrames.maxBlob)
    }

    /// The next pull batch, within the hour's byte budget; then the pushes.
    mutating func nextPull(_ session: inout SpoolSession, now: SpoolNow) {
        // Every caller holds a step.
        if var current = step {
            // A pull goes only while its worst case fits the hour: every id it names at the bound the session enforces on a
            // pulled blob, ours, whatever smaller bound the spool claims.
            let perBlob = ScopeFrames.maxBlob
            while let next = current.batches.first {
                let fits = intake.room(now: now.monotonic) / perBlob
                guard fits > 0 else {
                    counts.budgetDeferred += current.batches.reduce(0) { $0 + $1.count }
                    current.batches.removeAll()
                    break
                }
                let batch = Array(next.prefix(fits))
                if batch.count < next.count {
                    current.batches[0] = Array(next.dropFirst(batch.count))
                } else {
                    current.batches.removeFirst()
                }
                guard let request = session.pull(current.scope.id, batch, now: now.monotonic) else {
                    current.batches.removeAll()
                    break
                }
                current.pullReserved = batch.count * perBlob
                current.pullReceived = 0
                intake.charge(bytes: current.pullReserved, now: now.monotonic)
                current.phase = .pulling(request: request)
                step = current
                return
            }
            step = current
            beginPushes(&session, now: now)
        }
    }

    /// The frames this spool lacks and will take (`pushMissing`, `:2122-2153`), in custody's order. A retiring scope takes
    /// none (C-3.1-3).
    private mutating func beginPushes(_ session: inout SpoolSession, now: SpoolNow) {
        // Every caller holds a step.
        if var current = step, let state = states[current.scope.id] {
            if !current.scope.retiring {
                current.pushes = current.held.filter { held in
                    !current.listedSet.contains(held.id) && !state.invalid.contains(held.id) && !state.unpushable.contains(held.id)
                        && pushable(held, current, session: session, now: now)
                }
            }
            step = current
            nextPush(&session, now: now)
        }
    }

    /// Pushes the next frame, one at a time. A push the session cannot send while it is ready and the scope subscribed
    /// did not fit the spool's `maxRecord`, so that frame is unpushable here, or the scope would list every tick.
    mutating func nextPush(_ session: inout SpoolSession, now: SpoolNow) {
        // Every caller holds a step.
        if var current = step {
            let scope = current.scope.id
            while let held = current.pushes.first {
                current.pushes.removeFirst()
                let stamp: PowStamp?
                switch stampNeed(scope, session: session, now: now) {
                case .unasked:
                    stamp = nil
                case .stamp(let ready):
                    stamp = ready
                case .waiting:
                    demandStamp(scope, session: session, now: now)
                    current.pushes.removeAll()
                    continue
                }
                if let request = session.push(scope, blobId: held.id, data: held.sealed.blob, pow: stamp, now: now.monotonic) {
                    current.phase = .pushing(request: request, blob: held, stamped: stamp != nil)
                    step = current
                    return
                }
                guard session.isReady, session.isSubscribed(scope) else {
                    current.pushes.removeAll()
                    break
                }
                if states[scope]?.unpushable.insert(held.id) == true {
                    counts.unpushable += 1
                    current.learnt = true
                }
                states[scope]?.stickyUnpushable.insert(held.id)
            }
            step = current
            finishStep(&session)
        }
    }

    /// A push's answer (`pushMissing` and `survivable`, `:2139-2151`, `:2236-2251`): a stored blob folds into the anchor; a
    /// refusal of the blob (`tombstoned`, `too_large`, `bad_id`) makes it unpushable and the round steps over it; `rate`
    /// waits at most 5 s and goes on to the next; `pow` without a stamp asks one mined; anything else ends the scope's
    /// pushes. A push refusal parks nothing: a park is a scope refusal's (`handleScopeError`).
    private mutating func pushAnswered(_ held: HeldBlob, stamped: Bool, _ reply: SpoolReply, session: inout SpoolSession, now: SpoolNow) {
        // Every caller holds a step.
        if var current = step {
            let scope = current.scope.id
            switch reply {
            case .stored:
                session.foldPushed(scope, blobId: held.id)
                current.pushed.append(held.id)
                counts.pushed += 1
                step = current
                nextPush(&session, now: now)
            case .refused(let refusal) where Self.refusesTheBlob(refusal):
                if states[scope]?.unpushable.insert(held.id) == true {
                    counts.unpushable += 1
                }
                // A tombstone lapses and a listing says so; a blob the spool called too large or misaddressed stays refused.
                if !refusal.code.is(SpoolErrorCode.tombstoned) {
                    states[scope]?.stickyUnpushable.insert(held.id)
                }
                current.learnt = true
                step = current
                nextPush(&session, now: now)
            case .refused(let refusal) where refusal.code.is(SpoolErrorCode.rate):
                current.phase = .rateWait(until: SpoolSession.later(now.monotonic, by: refusal.rateWaitMilliseconds))
                step = current
            case .refused(let refusal) where refusal.code.is(SpoolErrorCode.pow):
                // `stampDemand` (`:3271-3283`): a demand for a stamp we did not send is met next time. A refused stamp on a push
                // parks the scope, as on a `sub`.
                if stamped {
                    states[scope]?.stamp = nil
                    park(scope, for: refusal.parkMilliseconds, now: now)
                } else {
                    demandStamp(scope, session: session, now: now)
                }
                current.pushes.removeAll()
                step = current
                finishStep(&session)
            default:
                current.pushes.removeAll()
                step = current
                finishStep(&session)
            }
        }
    }

    private static func refusesTheBlob(_ refusal: SpoolRefusal) -> Bool {
        refusal.code.is(SpoolErrorCode.tombstoned) || refusal.code.is(SpoolErrorCode.tooLarge) || refusal.code.is(SpoolErrorCode.badId)
    }

    /// Ends a scope's heal (`reanchor`, `:2265-2280`, and the mark at `:1991`): the anchor becomes the listing less what
    /// the spool said was gone, plus what we pushed, but only over the digest the listing ran against. Each stored push
    /// already folded itself into the anchor, so after any push the compare-and-set fails and the anchor stays the one
    /// the pushes moved, as a `digest` that landed during the round stays. The scope looks again only when the round
    /// pushed something or the listing taught something; an accepted blob marks it at its settlement.
    private mutating func finishStep(_ session: inout SpoolSession) {
        // Every caller holds a step.
        if let current = step {
            step = nil
            let remaining = current.listed.filter { !current.gone.contains($0) }
            let fold = Self.fold(remaining) ^ Self.fold(current.pushed)
            _ = session.reanchor(current.scope.id, over: current.listedAgainst, to: fold, count: remaining.count + current.pushed.count)
            if !current.pushed.isEmpty || current.learnt {
                markDirty(current.scope.id)
            }
        }
    }

    /// The XOR of FNV-1a-64 over raw ids (§6.3).
    static func fold(_ ids: some Sequence<SpoolID>) -> UInt64 {
        ids.reduce(0) { $0 ^ ScopeCrypto.fnv64($1.bytes) }
    }
}
