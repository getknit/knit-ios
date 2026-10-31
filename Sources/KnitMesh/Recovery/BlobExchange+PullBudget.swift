import KnitWire

/// The pull-through's hop budget and deadline (knit-next ADR 2026-10.2drc and its 2026-10-19 amendment, `385bfba0` and
/// `1ce131fd`; ADR 2026-10.8hek): what a want is recorded with, which ask keeps it alive, when an ask makes no echo, and
/// whom a cycle with nobody holding the blob asks to pull it (`noteAsker`, `budgetOf`, `echoRefused`, `pullOrWithhold`,
/// `pullNewcomers`, `askToPull` and `withholdPull`, `BlobExchange.kt:955-1030`, `:1679` and `:2102-2155` at `1ce131fd`).
///
/// A deadline is epoch ms on the frame's clock (a DM's `sentAt` plus custody's day), so it is read against the wall
/// clock the engine reads at each step, while every other time here is on the monotonic clock. Kotlin keeps one clock
/// for both; this port keeps them apart and passes `wall` to each check (ADR 2026-10.8hek).
extension BlobExchange {
    /// The budget and deadline a want is recorded with (`Reach`).
    struct Reach: Sendable, Equatable {
        /// How many phones deeper the want may ask to pull, counting the one asked.
        var budget: Int
        /// Until when, epoch ms on the frame's clock; `nil` for no deadline.
        var until: Int64?
        /// Whether the caller read every row naming the hash (the re-arm, a delivery): its deadline replaces the want's,
        /// `nil` included.
        var rederived = false
        /// An ask with no `pull` field: it makes a want when none exists, and keeps none alive.
        var fieldless = false

        /// A want of our own: the whole budget, and `until` when the caller knows it. `rederived` when the caller read
        /// every row naming the hash, so a `nil` deadline means none; otherwise a `nil` keeps the want's own.
        static func own(until: Int64?, rederived: Bool) -> Self {
            Self(budget: BlobExchange.pullBudget, until: until, rederived: rederived)
        }

        /// A neighbour's ask that allowed `pull` and named `until`: one hop less (``BlobExchange/budgetOf(_:)``), and its
        /// deadline as it carried it.
        static func asked(pull: Int?, until: Int64?) -> Self {
            Self(budget: BlobExchange.budgetOf(pull), until: until, fieldless: pull == nil)
        }
    }

    /// A want of our own the re-arm makes (`wantAll`'s pair and its deadline): the blob, its author, its reach, and
    /// whether only a peer's profile photo names it (``WantKind``).
    struct OwnWant: Sendable, Equatable {
        var hash: BlobHash
        var author: NodeId?
        var reach: Reach
        var kind: WantKind = .attachment
    }

    /// The budget a want made for an ask that allowed `pull` has (`budgetOf`): one hop less, an ask no newer than this
    /// build's own ``pullBudget`` counted at that, and an ask with no field (a build before the field) counted as 1, a
    /// fetch only. Negative when the ask allowed none: such an ask makes no want. `pull` is a Swift `Int` from its decode
    /// on, so the smallest Kotlin `Int` less one is a plain negative, where Kotlin's `Int` wraps it to its largest and
    /// would echo with the whole budget (ADR 2026-10.8hek).
    static func budgetOf(_ pull: Int?) -> Int {
        min(pull ?? 1, pullBudget) - 1
    }

    /// Why an ask with `pull` and `until` makes no want here at `wall`, or `nil` when it does (`echoRefused`): it allowed
    /// no budget, or it is past its deadline. Such an ask is served if the blob is held, and that is all.
    static func echoRefusal(pull: Int?, until: Int64?, wall: Int64) -> String? {
        if budgetOf(pull) < 0 {
            return "fetch only"
        }
        if let until, wall >= until {
            return "past its deadline"
        }
        return nil
    }

    /// ``recordWant(_:now:wall:author:via:asker:reach:)``'s bookkeeping for `asker`, a neighbour that asked us at `now` to
    /// pull `want`'s blob through, with the budget and deadline its ask allows us (`noteAsker`). Answers the log lines it
    /// owes.
    ///
    /// The ask keeps the want alive only when it carries at least the want's own budget: only a root mints budget, and
    /// every hop spends one, so an echo's ask back, a newcomer's, or one from a link that keeps re-forming can never keep
    /// a want alive once the want's own source stops. One that carries more raises it, and its deadline with it; an equal
    /// one widens the deadline, none being the widest. The asker is a puller for this cycle either way. An ask with no
    /// field, from a build before it, may make a want here but never keeps one alive.
    mutating func noteAsker(_ want: inout Want, _ asker: NodeId, _ reach: Reach, now: Int64, wall: Int64) -> [String] {
        // It lacks the bytes: not this cycle. Its ask may be what opens the next one, so open it first: opened after, it
        // would forget the mark and query the asker back, and a dead blob's pulls would go back and forth.
        var plan = Plan()
        if want.isCycleDue(at: now, wall: wall) {
            openCycle(&want, at: now, wall: wall, &plan)
        }
        want.pullers.insert(asker)
        guard !reach.fieldless, reach.budget >= want.budget else {
            return plan.notes
        }
        want.wantedAt = now
        if reach.budget > want.budget {
            want.budget = reach.budget
            want.until = reach.until
        } else if let kept = want.until {
            want.until = reach.until.map { max($0, kept) }
        }
        return plan.notes
    }

    /// ``pullThrough(_:_:_:wall:_:)`` with no neighbour fetching the blob (`pullOrWithhold`): every one of `lacking` asked
    /// to pull it through, once a cycle, when the want may; else the newcomers among them; else the pull withheld and
    /// said so.
    mutating func pullOrWithhold(_ want: inout Want, _ lacking: [Candidate], _ now: Int64, wall: Int64, _ plan: inout Plan) {
        let due = want.pulled.isEmpty && !lacking.isEmpty
        if let withheld = want.pullWithheldWhy(wall: wall) {
            if due {
                withholdPull(&want, lacking, withheld, &plan)
            }
        } else if due {
            askToPull(&want, lacking, now, &plan, newcomers: false)
        } else {
            pullNewcomers(&want, lacking, now, &plan)
        }
    }

    /// The pull of the neighbours among `lacking` that linked in this cycle and are not pulled in it (`pullNewcomers`):
    /// at once, so a want deep in its backoff does not leave a newcomer for hours. Once per link-up; a link that went
    /// since, or a cycle that closed, pulls nobody later. Whatever it asks spends a hop of the want's budget, so a
    /// newcomer's ask back can never keep the want alive.
    mutating func pullNewcomers(_ want: inout Want, _ lacking: [Candidate], _ now: Int64, _ plan: inout Plan) {
        let fresh = lacking.filter { want.freshLinks.contains($0.id) && !want.pulled.contains($0.id) }
        if !fresh.isEmpty {
            askToPull(&want, fresh, now, &plan, newcomers: true)
        }
    }

    /// The pull-through's asks (`askToPull`): the hop the frame came from alone in the first empty cycle, else every one of
    /// `lacking`. A `newcomers` pull leaves the cycle's schedule as it was: its rechecks count from the cycle's first pull.
    mutating func askToPull(_ want: inout Want, _ lacking: [Candidate], _ now: Int64, _ plan: inout Plan, newcomers: Bool) {
        let hop = lacking.first { $0.id == want.via }
        let pulls = hop.flatMap { want.emptyCycles == 0 && !newcomers ? [$0] : nil } ?? lacking
        if want.pulledAt == nil, !newcomers {
            // The cycle's first pull: its rechecks run out inside the cycle.
            want.pulledAt = now
        }
        for candidate in pulls {
            want.pulled.insert(candidate.id)
            want.freshLinks.remove(candidate.id)
            want.askedAt[candidate.id] = now
            plan.asks.append(Ask(to: candidate.id, line: .pull))
        }
        if newcomers {
            plan.why = "newcomer"
        } else {
            plan.why = pulls.count == 1 && pulls.first?.id == hop?.id ? "via hop" : "wide"
        }
        counts.pullThroughs += 1
    }

    /// A cycle in which `want` may not ask `lacking` to pull its blob through (`withholdPull`): nobody is asked, and the
    /// cycle, in which every neighbour said it lacks the blob, is dead and backs off as one that pulled would. Counted and
    /// logged once a cycle, never as `blob pull`, the line the trials count pulls by.
    mutating func withholdPull(_ want: inout Want, _ lacking: [Candidate], _ why: String, _ plan: inout Plan) {
        guard !want.pullWithheld else {
            return
        }
        want.pullWithheld = true
        counts.pullsWithheld += 1
        let ids = lacking.map(\.id.string).joined(separator: ", ")
        plan.notes.append("blob no-pull \(want.hash8)… → nobody of \(ids) (\(why))")
    }
}
