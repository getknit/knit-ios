public import KnitWire

/// ``AckSync``'s two holds toward an absent author who could read a sealed tick (`AckSync.kt` at knit-next `cbf2a487`): the
/// batch, a group's ticks escalating into custody as one sealed tick (knit-next ADR 033), and the ride hold, a room's
/// ticks waiting for a frame sealed toward that author anyway (knit-next ADR 2026-09.aa27). Both live inside a sealed
/// frame, so only ``TickSealing`` puts an id in one, and a live link ends either as one tick.
extension AckSync {
    /// Which of the two holds.
    enum Hold {
        /// A group's ticks, escalating once their debounce ends (`pending`).
        case batch
        /// A room's ticks, waiting for a ride (`riding`).
        case ride
    }

    /// When the oldest batch's debounce ends, on the monotonic clock, or `nil` with no batch waiting: the engine's deadline
    /// for ``flushDueBatches(linked:now:seals:)``, where Kotlin's first id arms a wake (`enqueue`, `AckSync.kt:428-433`).
    public var nextBatchDue: Int64? {
        pending.values.compactMap { $0.first?.at }.min().map { $0 + Self.batchDebounceMilliseconds }
    }

    /// Escalates every batch whose oldest id has waited out the debounce (`flushDueBatches`, `AckSync.kt:441-453`), and
    /// answers the ticks a failed escalation leaves to send now. Past a sweep first, so a batch past its day is dropped
    /// rather than escalated, as the heal's pass drops one.
    public mutating func flushDueBatches(linked: Set<NodeId>, now: Int64, seals: some TickSealing) -> [Tick] {
        sweep(now: now)
        return flushBatchesDue(linked: linked, now: now, seals: seals)
    }

    /// The ids waiting for a ride toward `author`, oldest stamp first, at most `limit`, taken out of the hold
    /// (`takeRiding`, `AckSync.kt:343-362`): for a frame sealed toward that author alone, which carries them, so they reach
    /// only the reader they concern (knit-next ADR 018). A carrier that cannot carry them hands them back
    /// (``giveBackRiding(_:_:now:)``), and one that did says so (``rode(_:now:)``).
    public mutating func takeRiding(_ author: NodeId, limit: Int) -> [String] {
        guard limit > 0, let held = riding[author] else {
            return []
        }
        let order = held.indices.sorted { (held[$0].at, $0) < (held[$1].at, $1) }.prefix(limit)
        for index in order {
            lent[held[index].key] = held[index].at
        }
        let taken = Set(order)
        let kept = held.indices.filter { !taken.contains($0) }.map { held[$0] }
        riding[author] = kept.isEmpty ? nil : kept
        return order.map { held[$0].messageId }
    }

    /// How many ids wait for a ride toward `author` (`ridingFor`).
    public func ridingFor(_ author: NodeId) -> Int {
        riding[author]?.count ?? 0
    }

    /// Puts back ids ``takeRiding(_:limit:)`` handed out that never rode, each with the stamp it had (`giveBackRiding`,
    /// `AckSync.kt:372-377`), so the wait it counted toward is unmoved: `now` only for an id no carrier took. Nothing here
    /// originates them.
    public mutating func giveBackRiding(_ author: NodeId, _ ids: [String], now: Int64) {
        for id in ids {
            let key = ExactKey(id)
            holdForRide(Waiting(messageId: id, key: key, at: lent.removeValue(forKey: key) ?? now), author: author)
        }
    }

    /// A carrier sealed `ids` toward their author (`rode`, `AckSync.kt:384-392`): they are done, and remembered as escalated
    /// ids are, so a re-serve of the room post owes nothing more.
    public mutating func rode(_ ids: [String], now: Int64) {
        guard !ids.isEmpty else {
            return
        }
        for id in ids {
            lent[ExactKey(id)] = nil
        }
        remember(ids.map(ExactKey.init), at: now)
    }

    // MARK: Batches

    /// Adds a group tick to `author`'s batch (`enqueue`, `AckSync.kt:395-438`). A full batch escalates at once, and so does
    /// the oldest batch once every batch together reaches ``pendingCapacity``: memory stays bounded, and nothing is dropped.
    mutating func enqueue(_ waiting: Waiting, author: NodeId, linked: Set<NodeId>, now: Int64, seals: some TickSealing) -> [Tick] {
        var batch = pending.removeValue(forKey: author) ?? []
        batch.append(waiting)
        if batch.count >= Self.maxBatchAcks {
            return escalate(batch, of: author, linked: linked, now: now, seals: seals)
        }
        pending[author] = batch
        if Self.waitingCount(pending) >= Self.pendingCapacity, let oldest = Self.byAge(pending).first {
            pending[oldest.author] = nil
            return escalate(oldest.held, of: oldest.author, linked: linked, now: now, seals: seals)
        }
        return []
    }

    /// Escalates every batch whose oldest id has waited out the debounce, oldest batch first.
    mutating func flushBatchesDue(linked: Set<NodeId>, now: Int64, seals: some TickSealing) -> [Tick] {
        let cutoff = now - Self.batchDebounceMilliseconds
        var ticks: [Tick] = []
        for batch in Self.byAge(pending) where batch.first <= cutoff {
            pending[batch.author] = nil
            ticks += escalate(batch.held, of: batch.author, linked: linked, now: now, seals: seals)
        }
        return ticks
    }

    /// Escalates `batch`, `author`'s, already out of its hold (`flushAuthor`, `AckSync.kt:461-472`): one originated sealed tick
    /// covering every id and the room ticks riding it, up to ``maxBatchAcks`` in all, with no check of the link first, since
    /// the flood reaches the neighbours and custody the rest. The riders are taken here, where Kotlin's seam takes them
    /// (`originateDeliveryTick`, `MeshManager.kt:1948-1957`), since a seam never touches the ledger asking it. A seal that
    /// fails gives the riders back to their hold and the batch back as cleartext entries, each with its stamp, tried once now.
    mutating func escalate(_ batch: [Waiting], of author: NodeId, linked: Set<NodeId>, now: Int64, seals: some TickSealing) -> [Tick] {
        let riders = takeRiding(author, limit: Self.maxBatchAcks - batch.count)
        guard seals.originateTick(to: author, acks: batch.map(\.messageId) + riders) else {
            giveBackRiding(author, riders, now: now)
            return restoreAsCleartext(batch, author: author, linked: linked)
        }
        rode(riders, now: now)
        remember(batch.map(\.key), at: now)
        return []
    }

    // MARK: Rides

    /// Adds a room tick to `author`'s ride hold at `waiting`'s stamp: now for a fresh one, the one it had for a give-back
    /// (`holdForRide`, `AckSync.kt:300-331`). An id already held keeps its place and takes the stamp. The holds together
    /// stay within ``pendingCapacity``: past it the oldest hold's first id is dropped, never originated, since originating
    /// is the cost a ride exists to avoid (`trimRiding`, `AckSync.kt:741-756`).
    mutating func holdForRide(_ waiting: Waiting, author: NodeId) {
        if let index = riding[author]?.firstIndex(where: { $0.key == waiting.key }) {
            riding[author]?[index].at = waiting.at
        } else {
            riding[author, default: []].append(waiting)
        }
        while Self.waitingCount(riding) > Self.pendingCapacity, let oldest = Self.byAge(riding).first {
            riding[oldest.author] = oldest.held.count > 1 ? Array(oldest.held.dropFirst()) : nil
        }
    }

    /// The ride hold's deadline (`flushDueRides` and `escalateRide`, `AckSync.kt:479-516`): a hold whose oldest id has
    /// waited out ``rideHoldMilliseconds`` goes over its author's live link as one tick. With no link it keeps waiting: the
    /// deadline's other routes, the spool and the fast plane, are not this port's, and no chain key is spent on nobody.
    mutating func flushRidesDue(linked: Set<NodeId>, now: Int64, seals: some TickSealing) -> [Tick] {
        let cutoff = now - Self.rideHoldMilliseconds
        var ticks: [Tick] = []
        for hold in Self.byAge(riding) where linked.contains(hold.author) && hold.held.contains(where: { $0.at <= cutoff }) {
            ticks += flushOverLink(.ride, of: hold.author, seals: seals)
        }
        return ticks
    }

    // MARK: Both holds

    /// `author` is linked while a hold waits (`flushBatchOverLink`, `AckSync.kt:579-593`): the whole hold goes over the link
    /// as one sealed tick, `relay = false`, with no custody row. It is not remembered as escalated: a live-link send ends
    /// the hold, as it ends an owed entry, and a re-serve owes again. With no seal, each id goes as a cleartext tick.
    mutating func flushOverLink(_ hold: Hold, of author: NodeId, seals: some TickSealing) -> [Tick] {
        let held: [Waiting]?
        switch hold {
        case .batch:
            held = pending.removeValue(forKey: author)
        case .ride:
            held = riding.removeValue(forKey: author)
        }
        guard let held, !held.isEmpty else {
            return []
        }
        if let wire = seals.sealTick(to: author, acks: held.map(\.messageId)) {
            return [Tick(author: author, form: .sealed(wire))]
        }
        return restoreAsCleartext(held, author: author, linked: [author])
    }

    /// Whether `author`'s batch or ride hold holds `key`: the re-owe that does nothing (`holds`, `AckSync.kt:284-288`).
    func holds(_ hold: Hold, _ author: NodeId, _ key: ExactKey) -> Bool {
        let held = hold == .batch ? pending[author] : riding[author]
        return held?.contains { $0.key == key } == true
    }

    /// Remembers `keys` as done at `now`, forgetting the oldest past ``escalatedCapacity`` (`trimEscalated`,
    /// `AckSync.kt:718-723`): a forgotten id costs at most one more tick on a later re-owe, which the author applies
    /// idempotently.
    mutating func remember(_ keys: [ExactKey], at now: Int64) {
        for key in keys {
            escalated[key] = Done(at: now, order: nextOrder)
            nextOrder += 1
        }
        let excess = escalated.count - Self.escalatedCapacity
        if excess > 0 {
            let oldest = escalated.sorted { ($0.value.at, $0.value.order) < ($1.value.at, $1.value.order) }.prefix(excess)
            for (key, _) in oldest {
                escalated[key] = nil
            }
        }
    }

    /// How many ids `holds` keeps, across every author.
    static func waitingCount(_ holds: [NodeId: [Waiting]]) -> Int {
        holds.values.map(\.count).reduce(0, +)
    }

    /// One author's hold, and when its first id came.
    struct AgedHold {
        var author: NodeId
        var held: [Waiting]
        var first: Int64
    }

    /// Every hold in `holds`, the one whose first id came first leading, ties by node id: an order every run repeats, where
    /// Kotlin's hash maps leave it to chance (`minByOrNull`). A hold is never kept empty, so each has a first id.
    static func byAge(_ holds: [NodeId: [Waiting]]) -> [AgedHold] {
        holds.compactMap { author, held in held.first.map { AgedHold(author: author, held: held, first: $0.at) } }
            .sorted { ($0.first, $0.author) < ($1.first, $1.author) }
    }

    /// `holds` without the ids older than `cutoff`, and without a hold left empty.
    static func swept(_ holds: [NodeId: [Waiting]], before cutoff: Int64) -> [NodeId: [Waiting]] {
        guard holds.values.contains(where: { $0.contains { $0.at < cutoff } }) else {
            return holds
        }
        return holds.compactMapValues { held in
            let kept = held.filter { $0.at >= cutoff }
            return kept.isEmpty ? nil : kept
        }
    }
}
