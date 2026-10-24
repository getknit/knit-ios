import KnitWire

/// The shapes a blob's fetch is kept in (`Want`, `Answer`, `Fetch`, `SentQuery`, `Candidate`, `Plan`, `Tier` and `Rank`
/// in knit-next's `BlobExchange.kt:1074-1280`).
extension BlobExchange {
    /// A blob we lack and how far its fetch has got (`Want`).
    ///
    /// A cycle queries every capable neighbour once (``queried``, ``answers``), keeps one ask outstanding (``fetch``),
    /// and passes over a holder that brought nothing (``failed``). The neighbours nobody can query get knit-next ADR
    /// 2026-10.f7gg's round (``blindAsked``, ``blindWidened``). A cycle ends no sooner than ``cycleGap(now:wall:dead:)``,
    /// and only with no ask outstanding. Whether it pulls through is bounded by its frame's deadline (``until``) and by
    /// the hops its budget still allows (``budget``, knit-next ADR 2026-10.2drc).
    ///
    /// Two clocks: every time here is on the monotonic clock but ``until``, which is the frame's, so each check of it takes
    /// the wall clock read at the step (ADR 2026-10.8hek; Kotlin keeps one clock for both).
    struct Want: Sendable {
        let hash: BlobHash
        var wantedAt: Int64
        /// Who posted the frame that names the blob, the one holder we can name.
        var author: NodeId?
        /// The neighbour that frame came from, the first asked to pull it through.
        var via: NodeId?
        var cycleAt: Int64
        /// Whether this cycle heard of a holder or a fetcher, and how many cycles in a row did not.
        var cycleSawLead = false
        var emptyCycles = 0
        /// Dead cycles in a row before this one (``isDead``): each doubles the wait for the next. When the streak began, on
        /// the monotonic clock, and how many dead cycles it has opened since it went ``longDead(now:wall:)``.
        var deadCycles = 0
        var deadSince: Int64?
        var longDeadCycles = 0
        /// How many phones deeper this want may ask to pull its blob, counting the one asked (``pullBudget`` for our own,
        /// one less than the ask allowed for an echo), and until when, epoch ms on the frame's clock: `nil` for no deadline
        /// (`Want.budget`, `Want.until`). 0 until whatever records the want says otherwise, so a site that forgets mints no
        /// root. And whether this cycle already counted and logged a pull it did not make.
        var budget = 0
        var until: Int64?
        var pullWithheld = false
        /// Neighbours that linked in this cycle and have not been pulled since: pulled once, at once
        /// (``BlobExchange/pullNewcomers(_:_:_:_:)``).
        var freshLinks: Set<NodeId> = []
        /// Neighbours we are pulling it for: they lack it, so this cycle neither queries nor asks them.
        var pullers: Set<NodeId> = []
        /// Each capable neighbour's query for this blob, when it was queued, and its latest answer, this cycle.
        var queried: [NodeId: Int64] = [:]
        var answers: [NodeId: Answer] = [:]
        /// Holders that brought nothing this cycle, and those asked again on a confirm that said they hold it.
        var failed: Set<NodeId> = []
        var reasked: Set<NodeId> = []
        var fetch: Fetch?
        /// Every ask, any cycle: the memo's floor on asking a holder again, and the rule for a peer streaming to us.
        var askedAt: [NodeId: Int64] = [:]
        /// Each neighbour's ask of ours that a `blobcancel` already withdrew, by when it was made: one cancel per ask.
        var withdrawnAt: [NodeId: Int64] = [:]
        /// The blind round over the neighbours nobody can query.
        var blindAsked: Set<NodeId> = []
        var blindWidened = false
        var blindWidenedAt: Int64?
        /// The neighbours asked to pull it through this cycle, how often each was queried again since, and when the
        /// cycle's first pull went.
        var pulled: Set<NodeId> = []
        var pullRechecks: [NodeId: Int] = [:]
        var pulledAt: Int64?
        /// When its next step is due, or `nil` when no timer is armed.
        var timerDue: Int64?

        init(hash: BlobHash, at: Int64, author: NodeId?, via: NodeId?, puller: NodeId?) {
            self.hash = hash
            wantedAt = at
            cycleAt = at
            self.author = author
            self.via = via
            if let puller {
                pullers.insert(puller)
            }
        }

        /// The hash as the log shows it.
        var hash8: Substring { hash.string.prefix(BlobExchange.shownHashCharacters) }

        /// Whether this cycle is dead (`dead`, `BlobExchange.kt:2408-2412` at knit-next `1ce131fd`): every neighbour asked
        /// said it lacks the blob. At least one answered or was asked blind, and none holds or is fetching it. A blind ask
        /// keeps the cycle's pace only for the first ``pullRecheckDeadCycles`` cycles without a lead, since that one may
        /// hold it; past them a cycle whose blind asks brought nothing is dead too and backs off with the rest (knit-next
        /// ADR 2026-10.2drc). A blind ask is still made every cycle that opens: an iPhone holder can only be found that way.
        /// Android's fast-only branch has no twin: one radio, no Wi-Fi Aware link to wait on.
        var isDead: Bool {
            let blindSpent = blindAsked.isEmpty || emptyCycles >= BlobExchange.pullRecheckDeadCycles
            return !cycleSawLead && (!answers.isEmpty || !blindAsked.isEmpty) && blindSpent
        }

        /// Why this want asks nobody to pull its blob through at `wall`, or `nil` when it may (`pullWithheldWhy`): its frame's
        /// deadline has passed, or it has no budget left.
        func pullWithheldWhy(wall: Int64) -> String? {
            if let until, wall >= until {
                return "past its deadline"
            }
            return budget < 1 ? "fetch only" : nil
        }

        /// How long this cycle stands before the next opens (`cycleGap`): a cycle, doubled for each dead cycle in a row
        /// before this one while this one is dead too, at most ``maxBackoffShift`` times: 45 s, 90 s, 3 min, then 6 min. A
        /// ``longDead(now:wall:)`` streak doubles on with each further dead cycle, to ``maxLongBackoffShift``: 12, 24, 48 and
        /// 96 min, then about 3.2 h. Any lead ends the streak, and a neighbour that links is still queried at once.
        func cycleGap(now: Int64, wall: Int64, dead: Bool) -> Int64 {
            guard dead else {
                return BlobExchange.cycleMilliseconds
            }
            let extra = longDead(now: now, wall: wall) ? longDeadCycles : 0
            return BlobExchange.cycleMilliseconds
                << min(min(deadCycles, BlobExchange.maxBackoffShift) + extra, BlobExchange.maxLongBackoffShift)
        }

        /// Whether this want's dead streak backs off past the 6 min ceiling (`longDead`, `BlobExchange.kt:2442` at knit-next
        /// `1ce131fd`): it has reached the ceiling, and it has been dead for ``longDeadMilliseconds`` on the monotonic clock,
        /// or its frame's deadline has passed on the wall clock. The deadline is the trigger a restart cannot forget: the streak is kept in
        /// memory, and iOS restarts Knit far more often than daily, while the deadline comes back with every re-arm.
        func longDead(now: Int64, wall: Int64) -> Bool {
            guard deadCycles >= BlobExchange.maxBackoffShift else {
                return false
            }
            return deadSince.map { now - $0 >= BlobExchange.longDeadMilliseconds } == true || until.map { wall >= $0 } == true
        }

        /// Whether the next cycle may open at `now` (`cycleDue`): no ask outstanding, and a cycle's gap since it opened,
        /// or since its first pull when it pulled, so the pull's rechecks run out first.
        func isCycleDue(at now: Int64, wall: Int64) -> Bool {
            fetch == nil && now - max(cycleAt, pulledAt ?? cycleAt) >= cycleGap(now: now, wall: wall, dead: isDead)
        }

        /// A lead, or a cycle that was not dead: the backoff starts over (`endDeadStreak`).
        mutating func endDeadStreak() {
            deadCycles = 0
            deadSince = nil
            longDeadCycles = 0
        }

        /// A neighbour said it holds the blob or is fetching it (`sawLead`). A backed-off cycle starts over from `now`,
        /// its answers kept: the backoff is over, and the next cycle is due a cycle after the lead.
        mutating func sawLead(at now: Int64) {
            if !cycleSawLead, deadCycles > 0 {
                endDeadStreak()
                cycleAt = now
            }
            cycleSawLead = true
        }

        /// Opens the next cycle at `now` (`Want.openCycle`). A natural one counts the cycle it closes; a forced one
        /// starts its ask over. A dead streak's start is its first dead cycle's; whether it is long dead is read before the
        /// count moves, so the 6 min cycle is kept, and a dead cycle that is not long dead forgets the long count, so a
        /// deadline a re-arm lifted and later restored ramps from 12 min again.
        mutating func openCycle(at now: Int64, wall: Int64, natural: Bool) {
            if natural {
                if isDead {
                    if deadCycles == 0 {
                        deadSince = cycleAt
                    }
                    longDeadCycles = longDead(now: now, wall: wall) ? longDeadCycles + 1 : 0
                    deadCycles += 1
                } else {
                    endDeadStreak()
                }
                emptyCycles = cycleSawLead ? 0 : emptyCycles + 1
            }
            cycleAt = now
            fetch = nil
            cycleSawLead = false
            pullWithheld = false
            // A link-up pulls in its own cycle or not at all.
            freshLinks.removeAll()
            pullers.removeAll()
            queried.removeAll()
            answers.removeAll()
            failed.removeAll()
            reasked.removeAll()
            blindAsked.removeAll()
            blindWidened = false
            blindWidenedAt = nil
            pulled.removeAll()
            pullRechecks.removeAll()
            pulledAt = nil
        }

        /// Whether our last ask of `peer` is still to be withdrawn (`Want.withdraw`), and marks it withdrawn, so each
        /// ask is withdrawn once. An ask whose neighbour said, at or after it, that it lacks the blob has nothing to
        /// withdraw: it was a pull, and a neighbour that lacks a blob remembers no asker (knit-next's device rerun of
        /// 2026-10-07, where a dead want sent a cancel every cycle).
        mutating func withdraw(_ peer: NodeId) -> Bool {
            guard let asked = askedAt[peer] else {
                return false
            }
            if let answer = answers[peer], !answer.state.isHeld, answer.receivedAt >= asked {
                return false
            }
            defer { withdrawnAt[peer] = asked }
            return withdrawnAt[peer] != asked
        }

        /// Forgets what this cycle knew of neighbours that linked again (`linked`). Every ask's time stays, so the memo
        /// floor and the rule for a peer streaming to us still hold.
        mutating func forgetLinks(_ ids: Set<NodeId>) {
            pullers.subtract(ids)
            // A newcomer that lacks it is asked to pull it through at once, once per link-up, in this cycle.
            freshLinks.formUnion(ids)
            blindAsked.subtract(ids)
            pulled.subtract(ids)
            failed.subtract(ids)
            reasked.subtract(ids)
            for id in ids {
                pullRechecks[id] = nil
                queried[id] = nil
                answers[id] = nil
            }
            if let fetch, ids.contains(fetch.peer) {
                self.fetch = nil
            }
        }
    }

    /// A neighbour's answer for one blob (`Answer`): its state, its load, when the query it answers went, for a SENDING
    /// one that said so when our copy should have landed (knit-next ADR 2026-10.nsr7), which ``hold`` waits on, and when
    /// it reached us. One saying the neighbour lacks the blob that reached us at or after our ask says the ask found it
    /// lacking.
    /// Android also keeps the size, to tell whether a blob is worth raising the Wi-Fi Aware link for; one radio has no
    /// link to raise, so the size is only logged.
    struct Answer: Sendable {
        var state: BlobHolding
        var load: Int
        var querySentAt: Int64
        var etaAt: Int64?
        var receivedAt: Int64
    }

    /// A capable neighbour that said it holds the blob, with what it said.
    struct Holder: Sendable {
        var candidate: Candidate
        var answer: Answer
    }

    /// The one ask outstanding for a blob, or a wait on a holder already sending it (`Fetch`). Its grace counts from
    /// ``quietSince``, the first look that found the holder streaming nothing to us; ``confirmAt`` is when it was queried
    /// again once that grace ran out. A blind first ask whose pick said it holds the blob is re-tiered as a holder's, and
    /// a ``Tier/pending`` one is a hold on an ask already made, its grace running to the floor.
    struct Fetch: Sendable {
        var peer: NodeId
        var tier: Tier
        var graceMilliseconds: Int64
        var quietSince: Int64?
        var confirms = 0
        var confirmAt: Int64?

        init(peer: NodeId, tier: Tier, at: Int64, graceMilliseconds: Int64) {
            self.peer = peer
            self.tier = tier
            self.graceMilliseconds = graceMilliseconds
            quietSince = at
        }
    }

    /// A query on its way (`SentQuery`): to whom, when, and which hashes it named.
    struct SentQuery: Sendable {
        var peer: NodeId
        var at: Int64
        var hashes: Set<BlobHash>
    }

    /// A linked neighbour as a step reads it (`Candidate`): whether it is streaming a file to us, whether its link
    /// says it answers a query, and how long the file it streams us has left at its rate so far (`streamLeftMs`,
    /// `MeshTransport.fileArrivingEtaMs`), `nil` when that is not known. One radio, so there is no plane to choose and
    /// no slow link to tell apart.
    struct Candidate: Sendable, Equatable {
        var id: NodeId
        var streaming: Bool
        var capable: Bool
        var streamLeftMilliseconds: Int64?
    }

    /// What one step decided (`Plan`): the neighbours it owes a query, the asks it makes, the neighbours whose ask of ours
    /// it withdraws, when it wants to be stepped again, and the log lines it owes.
    struct Plan: Sendable {
        /// The want's budget and deadline as the step read them, which every ask it sends carries (knit-next ADR
        /// 2026-10.2drc): a fetch, a blind ask and a pull alike.
        var pull = BlobExchange.pullBudget
        var until: Int64?
        var query: [NodeId] = []
        var asks: [Ask] = []
        var cancels: [NodeId] = []
        var wake: Int64?
        var why = ""
        var notes: [String] = []

        mutating func waitFor(_ milliseconds: Int64) {
            if milliseconds > 0 {
                wake = min(wake ?? milliseconds, milliseconds)
            }
        }
    }

    /// One `blobreq` a step sends, and the log line it is told in.
    struct Ask: Sendable, Equatable {
        enum Line: Sendable {
            case first
            case widened
            case pull
            case fetch
        }

        var to: NodeId
        var line: Line
    }

    /// What an outstanding fetch is (`Tier`): an ask of a holder over a link with nothing streaming to us, or over one
    /// that is (Android's slow link also covers the Coded PHY, which this port cannot see), a wait on a holder already
    /// sending, a blind first ask, or a hold on an ask already made, its grace running to the ask's floor (knit-next
    /// #140). The first two rank holders, best first.
    enum Tier: Int, Comparable, Sendable {
        case link = 0
        case slowLink = 1
        case sending = 2
        case blind = 3
        case pending = 4

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// What put a neighbour first in a blind round, best first (`Rank`). This port has no Wi-Fi Aware, so Android's
    /// two fast-plane ranks never come up. The label is the log's.
    enum Rank: Int, Comparable, Sendable {
        case author = 0
        case sourceHop = 1
        case neighbour = 2

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .author:
                "author"
            case .sourceHop:
                "source hop"
            case .neighbour:
                "neighbour"
            }
        }
    }
}
