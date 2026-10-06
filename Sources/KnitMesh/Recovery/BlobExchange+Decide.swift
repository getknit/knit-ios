import KnitWire

/// One step of a blob's fetch (`decide` and its helpers, `BlobExchange.kt:291-606`, knit-next ADRs 2026-10.6e5t and
/// 2026-10.f7gg).
extension BlobExchange {
    /// Where `hash`'s fetch stands at `now` against the `linked` neighbours, and the one change that moves it on: the
    /// queries it owes go into the outbox, and the asks, the wake and the log lines come back for the engine to carry
    /// out. A hash not wanted gets an empty plan. The engine reads the link and the store first: a blob on its way or
    /// held is never stepped.
    mutating func decide(_ hash: BlobHash, among linked: [Candidate], now: Int64) -> Plan {
        guard var want = wants[hash] else {
            return Plan()
        }
        var plan = Plan()
        decide(&want, linked, now, &plan)
        wants[hash] = want
        queue(hash, for: plan.query)
        return plan
    }

    private mutating func decide(_ want: inout Want, _ linked: [Candidate], _ now: Int64, _ plan: inout Plan) {
        if let fetch = want.fetch {
            // Queries go out mid-fetch too (a newcomer, a fetching neighbour's recheck): fresh answers for the fallback.
            owedQueries(&want, capableOf(linked.filter { !want.pullers.contains($0.id) }), now, &plan)
            if let wait = fetchWait(&want, fetch, holder: linked.first { $0.id == fetch.peer }, now, &plan) {
                plan.waitFor(wait)
                return
            }
        }
        // A cycle closes only with no ask outstanding, so an ask's grace always runs out inside the cycle it began in.
        if want.isCycleDue(at: now) {
            openCycle(&want, at: now, &plan)
        }
        let live = linked.filter { !want.pullers.contains($0.id) }
        let capable = capableOf(live)
        owedQueries(&want, capable, now, &plan)
        if askHolder(&want, capable, now, &plan) {
            return
        }
        if askBlind(&want, Self.blind(want, live, capable), now, &plan) {
            return
        }
        pullThrough(&want, capable, now, &plan)
    }

    /// Opens `want`'s next cycle at `now`, and logs it when the last one was dead.
    func openCycle(_ want: inout Want, at now: Int64, _ plan: inout Plan) {
        want.openCycle(at: now, natural: true)
        if want.deadCycles > 0 {
            plan.notes.append(
                "blob cycle \(want.hash8)… after \(want.deadCycles) dead, next if dead in \(want.cycleGap(dead: true)) ms")
        }
    }

    /// The neighbours among `live` this node queries: those whose link says they answer, while querying is on.
    private func capableOf(_ live: [Candidate]) -> [Candidate] {
        queriesHolders ? live.filter(\.capable) : []
    }

    /// The queries `want` owes this cycle (`owedQueries`): each capable neighbour once, and again once its recheck is
    /// due, or due within the timer's window, which stepped it early to share this frame. A recheck of one we asked to
    /// pull it through counts against ``pullRechecks``.
    private func owedQueries(_ want: inout Want, _ capable: [Candidate], _ now: Int64, _ plan: inout Plan) {
        let owed = capable.filter { candidate in
            guard let at = want.queried[candidate.id] else {
                return true
            }
            return recheckAt(want, candidate.id, queriedAt: at).map { now + Self.timerCoalesceMilliseconds >= $0 } == true
        }
        for candidate in owed {
            if want.queried[candidate.id] != nil, want.answers[candidate.id]?.state != .fetching {
                want.pullRechecks[candidate.id, default: 0] += 1
            }
            want.queried[candidate.id] = now
            plan.query.append(candidate.id)
        }
    }

    /// When neighbour `id` is owed another query this cycle, or `nil` (`recheckAt`). One that said it is fetching the
    /// blob is queried a recheck after it said so. One we asked to pull it through, and that has not said it holds it,
    /// is queried a recheck after the pull or its last query, at most ``pullRechecks`` times and only in the first
    /// ``pullRecheckDeadCycles`` cycles of a dead streak: it holds the blob the moment its own fetch lands, and the next
    /// cycle may be minutes off.
    private func recheckAt(_ want: Want, _ id: NodeId, queriedAt at: Int64) -> Int64? {
        let state = want.answers[id]?.state
        if state == .fetching {
            return at + Self.fetchingRecheckMilliseconds
        }
        guard let asked = want.askedAt[id], want.pulled.contains(id), !want.failed.contains(id), state?.isHeld != true,
            want.deadCycles < Self.pullRecheckDeadCycles, want.pullRechecks[id, default: 0] < Self.pullRechecks
        else {
            return nil
        }
        return max(at, asked) + Self.fetchingRecheckMilliseconds
    }

    /// How long the outstanding fetch still has, or `nil` once it is over (`fetchWait`). `holder` is its neighbour as
    /// linked now, `nil` once the link is gone. While the holder streams anything to us, our copy may be queued behind
    /// it, so the grace counts from the first quiet look, never from the last look during the stream. A queried holder
    /// whose grace is up is queried once more.
    private mutating func fetchWait(_ want: inout Want, _ fetch: Fetch, holder: Candidate?, _ now: Int64, _ plan: inout Plan) -> Int64? {
        var fetch = fetch
        guard let holder else {
            return over(&want, fetch, "link gone", &plan)
        }
        if holder.streaming {
            fetch.quietSince = nil
            want.fetch = fetch
            return min(Self.streamPollMilliseconds, fetch.graceMilliseconds)
        }
        let quiet = fetch.quietSince ?? now
        fetch.quietSince = quiet
        want.fetch = fetch
        let left = quiet + fetch.graceMilliseconds - now
        if left > 0 {
            return left
        }
        if fetch.tier == .blind {
            return over(&want, fetch, "grace", &plan)
        }
        if !holder.capable || !queriesHolders || fetch.confirms >= Self.maxConfirms {
            return over(&want, fetch, "grace", &plan)
        }
        return confirmWait(&want, fetch, holder, now, &plan)
    }

    /// ``fetchWait(_:_:holder:_:_:)`` once the grace is up (`confirmWait`): query the holder again, or read its answer.
    /// Still sending, it gets another grace. Holding it, to a query sent after our ask, it never had the ask and is asked
    /// again, once. Anything else, or silence, and the next holder is tried.
    private mutating func confirmWait(_ want: inout Want, _ fetch: Fetch, _ holder: Candidate, _ now: Int64, _ plan: inout Plan) -> Int64? {
        var fetch = fetch
        guard let sent = fetch.confirmAt else {
            fetch.confirmAt = now
            fetch.confirms += 1
            want.fetch = fetch
            want.answers[holder.id] = nil
            want.queried[holder.id] = now
            plan.query.append(holder.id)
            counts.confirms += 1
            plan.notes.append("blob confirm \(want.hash8)… → \(holder.id)")
            return Self.queryWaitMilliseconds
        }
        let answer = want.answers[holder.id]
        if answer == nil, now - sent < Self.queryWaitMilliseconds {
            return sent + Self.queryWaitMilliseconds - now
        }
        if answer?.state == .sending {
            fetch.quietSince = now
            fetch.confirmAt = nil
            want.fetch = fetch
            return fetch.graceMilliseconds
        }
        if answer?.state == .have, !want.reasked.contains(holder.id) {
            want.reasked.insert(holder.id)
            want.fetch = nil
            return nil
        }
        return over(&want, fetch, "confirm \(answer.map { Self.label($0.state) } ?? "silent")", &plan)
    }

    /// Ends `fetch`, whose holder brought nothing, and says why (`over`). A blind first ask's end widens its round
    /// instead, and says nothing.
    private mutating func over(_ want: inout Want, _ fetch: Fetch, _ why: String, _ plan: inout Plan) -> Int64? {
        want.fetch = nil
        if fetch.tier == .blind {
            want.blindWidened = true
            return nil
        }
        want.failed.insert(fetch.peer)
        counts.fallbacks += 1
        plan.notes.append("blob fallback \(want.hash8)… \(fetch.peer) (\(why)) → next")
        return nil
    }

    /// Asks the best capable neighbour that said it holds the blob, or waits on one already sending it (`askHolder`).
    /// True when the step is decided: asked, or waiting for answers still due, a holder's memo floor, or a blind
    /// widening's grace. The choice waits for every answer: Android's one exception, a holder on a live Wi-Fi Aware
    /// link, never comes up here.
    private mutating func askHolder(_ want: inout Want, _ capable: [Candidate], _ now: Int64, _ plan: inout Plan) -> Bool {
        let holders = capable.compactMap { candidate in
            want.answers[candidate.id].flatMap { answer in
                !want.failed.contains(candidate.id) && answer.state.isHeld ? Holder(candidate: candidate, answer: answer) : nil
            }
        }
        if let sending = holders.first(where: { $0.answer.state == .sending }) {
            let peer = sending.candidate.id
            want.fetch = Fetch(peer: peer, tier: .sending, at: now, graceMilliseconds: Self.firstAskGraceMilliseconds)
            plan.notes.append("blob wait \(want.hash8)… on \(peer) (sending), grace \(Self.firstAskGraceMilliseconds) ms")
            plan.waitFor(Self.firstAskGraceMilliseconds)
            return true
        }
        // When each neighbour still to answer was queried, while its answer is due.
        let answering = capable.compactMap { want.answers[$0.id] == nil ? want.queried[$0.id] : nil }
            .filter { now - $0 < Self.queryWaitMilliseconds }
        let widenGate = want.blindWidenedAt.map { $0 + Self.firstAskGraceMilliseconds - now }.flatMap { $0 > 0 ? $0 : nil }
        let askable = holders.filter { isAskable(want, $0, now) }
        if let best = askable.min(by: Self.ranksBefore), widenGate == nil, answering.isEmpty {
            let tier = Self.tier(of: best.candidate)
            want.fetch = Fetch(peer: best.candidate.id, tier: tier, at: now, graceMilliseconds: Self.firstAskGraceMilliseconds)
            want.askedAt[best.candidate.id] = now
            plan.asks.append(Ask(to: best.candidate.id, line: .fetch))
            plan.why = "\(tier == .slowLink ? "slow link" : "link"), load \(best.answer.load)"
            counts.fetches += 1
            plan.waitFor(Self.firstAskGraceMilliseconds)
            return true
        }
        if holders.isEmpty, answering.isEmpty {
            return false
        }
        let floors = holders.compactMap { holder in want.askedAt[holder.candidate.id].map { $0 + Self.serveMemoMilliseconds - now } }
        let answersDue = answering.map { $0 + Self.queryWaitMilliseconds - now }
        if let wait = (floors + answersDue + [widenGate].compactMap(\.self)).filter({ $0 > 0 }).min() {
            plan.waitFor(wait)
        }
        return true
    }

    /// Whether a holder may be asked now (`askable`): never asked before, or its answer is newer than our last ask, or
    /// the memo has lapsed since.
    private func isAskable(_ want: Want, _ holder: Holder, _ now: Int64) -> Bool {
        guard let at = want.askedAt[holder.candidate.id] else {
            return true
        }
        return holder.answer.querySentAt > at || now - at >= Self.serveMemoMilliseconds
    }

    /// The link a holder's copy would come over (`tierOf`): one radio, so only whether it is streaming us a file.
    static func tier(of candidate: Candidate) -> Tier {
        candidate.streaming ? .slowLink : .link
    }

    /// Best holder first (`byTier`): by link, then by how many files it is feeding, then by id.
    private static func ranksBefore(_ lhs: Holder, _ rhs: Holder) -> Bool {
        let tiers = (tier(of: lhs.candidate), tier(of: rhs.candidate))
        guard tiers.0 == tiers.1 else {
            return tiers.0 < tiers.1
        }
        guard lhs.answer.load == rhs.answer.load else {
            return lhs.answer.load < rhs.answer.load
        }
        return lhs.candidate.id.string < rhs.candidate.id.string
    }

    /// knit-next ADR 2026-10.f7gg's round over the neighbours nobody can query (`askBlind`): those without
    /// ``Capabilities/blobHave``, and capable ones still silent past the wait. One blind ask of the likeliest, then every
    /// other at once once its grace is up, never one by one: without a negative answer, every non-holder ahead of a
    /// holder would cost a whole grace. A neighbour streaming us a file is not asked again (knit-next ADR 2026-10.nxfb).
    /// True when it asked.
    private mutating func askBlind(_ want: inout Want, _ blind: [Candidate], _ now: Int64, _ plan: inout Plan) -> Bool {
        let ranked = blind.min { lhs, rhs in
            let ranks = (Self.rank(of: lhs, in: want), Self.rank(of: rhs, in: want))
            return ranks.0 == ranks.1 ? lhs.id.string < rhs.id.string : ranks.0 < ranks.1
        }
        guard let pick = ranked else {
            return false
        }
        if !want.blindWidened {
            want.blindAsked.insert(pick.id)
            want.askedAt[pick.id] = now
            want.fetch = Fetch(peer: pick.id, tier: .blind, at: now, graceMilliseconds: Self.firstAskGraceMilliseconds)
            plan.asks.append(Ask(to: pick.id, line: .first))
            plan.why = Self.rank(of: pick, in: want).label
            counts.blindAsks += 1
            plan.waitFor(Self.firstAskGraceMilliseconds)
            return true
        }
        want.blindWidenedAt = now
        for candidate in blind {
            want.blindAsked.insert(candidate.id)
            want.askedAt[candidate.id] = now
            plan.asks.append(Ask(to: candidate.id, line: .widened))
        }
        counts.blindAsks += 1
        return true
    }

    /// The neighbours the blind round may ask: any not asked blind this cycle that has not answered a query, and is not
    /// streaming us a file after an ask of ours, since our copy may sit behind that file.
    private static func blind(_ want: Want, _ live: [Candidate], _ capable: [Candidate]) -> [Candidate] {
        let answered = Set(capable.map(\.id).filter { want.answers[$0] != nil })
        return live.filter { candidate in
            !answered.contains(candidate.id) && !want.blindAsked.contains(candidate.id)
                && !(candidate.streaming && want.askedAt[candidate.id] != nil)
        }
    }

    /// How likely a neighbour that cannot say is to hold the blob, best first (`rankOf`): its author, then the neighbour
    /// the frame came from, since a carrier pulls what it carries, then anyone.
    static func rank(of candidate: Candidate, in want: Want) -> Rank {
        if candidate.id == want.author {
            return .author
        }
        return candidate.id == want.via ? .sourceHop : .neighbour
    }

    /// Nobody in reach holds it (`pullThrough`). Unless a neighbour is fetching it, the neighbours that said they lack it
    /// are asked to pull it through: the hop the frame came from first, every one of them from the next empty cycle on,
    /// or at once when the hop is not among them. Each is queried again shortly, and the next cycle, opened by the tick
    /// or a link-up and never by a timer of its own, queries everyone again.
    private mutating func pullThrough(_ want: inout Want, _ capable: [Candidate], _ now: Int64, _ plan: inout Plan) {
        let fetching = capable.contains { want.answers[$0.id]?.state == .fetching }
        // A neighbour that answered nothing says nothing: one still silent here was asked blind.
        let lacking = capable.filter { want.answers[$0.id].map { !$0.state.isHeld && $0.state != .fetching } ?? false }
        if !fetching, want.pulled.isEmpty, !lacking.isEmpty {
            let hop = lacking.first { $0.id == want.via }
            let pulls = hop.flatMap { want.emptyCycles == 0 ? [$0] : nil } ?? lacking
            if want.pulledAt == nil {
                // The cycle's first pull: its rechecks run out inside the cycle.
                want.pulledAt = now
            }
            for candidate in pulls {
                want.pulled.insert(candidate.id)
                want.askedAt[candidate.id] = now
                plan.asks.append(Ask(to: candidate.id, line: .pull))
            }
            plan.why = pulls.count == 1 && pulls.first?.id == hop?.id ? "via hop" : "wide"
            counts.pullThroughs += 1
        }
        let rechecks = capable.compactMap { candidate in
            want.queried[candidate.id].flatMap { recheckAt(want, candidate.id, queriedAt: $0) }
        }
        if let next = rechecks.min() {
            plan.waitFor(max(next - now, 1))
        }
    }
}
