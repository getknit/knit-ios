import KnitWire

/// The shapes a blob's fetch is kept in (`Want`, `Answer`, `Fetch`, `SentQuery`, `Candidate`, `Plan`, `Tier` and `Rank`
/// in knit-next's `BlobExchange.kt:1074-1280`).
extension BlobExchange {
    /// A blob we lack and how far its fetch has got (`Want`).
    ///
    /// A cycle queries every capable neighbour once (``queried``, ``answers``), keeps one ask outstanding (``fetch``),
    /// and passes over a holder that brought nothing (``failed``). The neighbours nobody can query get knit-next ADR
    /// 2026-10.f7gg's round (``blindAsked``, ``blindWidened``). A cycle ends no sooner than ``cycleGap(dead:)``, and only
    /// with no ask outstanding.
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
        /// Dead cycles in a row before this one (``isDead``): each doubles the wait for the next.
        var deadCycles = 0
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

        /// Whether this cycle is dead (`dead`): every neighbour asked said it lacks the blob. At least one answered,
        /// none holds or is fetching it, and nobody was asked blind, since that one may hold it.
        var isDead: Bool { !cycleSawLead && !answers.isEmpty && blindAsked.isEmpty }

        /// How long this cycle stands before the next opens (`cycleGap`): a cycle, doubled for each dead cycle in a row
        /// before this one while this one is dead too, at most ``maxBackoffShift`` times: 45 s, 90 s, 3 min, then 6 min.
        func cycleGap(dead: Bool) -> Int64 {
            dead ? BlobExchange.cycleMilliseconds << min(deadCycles, BlobExchange.maxBackoffShift) : BlobExchange.cycleMilliseconds
        }

        /// Whether the next cycle may open at `now` (`cycleDue`): no ask outstanding, and a cycle's gap since it opened,
        /// or since its first pull when it pulled, so the pull's rechecks run out first.
        func isCycleDue(at now: Int64) -> Bool {
            fetch == nil && now - max(cycleAt, pulledAt ?? cycleAt) >= cycleGap(dead: isDead)
        }

        /// A neighbour said it holds the blob or is fetching it (`sawLead`). A backed-off cycle starts over from `now`,
        /// its answers kept: the backoff is over, and the next cycle is due a cycle after the lead.
        mutating func sawLead(at now: Int64) {
            if !cycleSawLead, deadCycles > 0 {
                deadCycles = 0
                cycleAt = now
            }
            cycleSawLead = true
        }

        /// Opens the next cycle at `now` (`Want.openCycle`). A natural one counts the cycle it closes; a forced one
        /// starts its ask over.
        mutating func openCycle(at now: Int64, natural: Bool) {
            if natural {
                deadCycles = isDead ? deadCycles + 1 : 0
                emptyCycles = cycleSawLead ? 0 : emptyCycles + 1
            }
            cycleAt = now
            fetch = nil
            cycleSawLead = false
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

        /// Forgets what this cycle knew of neighbours that linked again (`linked`). Every ask's time stays, so the memo
        /// floor and the rule for a peer streaming to us still hold.
        mutating func forgetLinks(_ ids: Set<NodeId>) {
            pullers.subtract(ids)
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

    /// A neighbour's answer for one blob (`Answer`): its state, its load, when the query it answers went, and, for a
    /// SENDING one that said so, when our copy should have landed (knit-next ADR 2026-10.nsr7), which ``hold`` waits on.
    /// Android also keeps the size, to tell whether a blob is worth raising the Wi-Fi Aware link for; one radio has no
    /// link to raise, so the size is only logged.
    struct Answer: Sendable {
        var state: BlobHolding
        var load: Int
        var querySentAt: Int64
        var etaAt: Int64?
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

    /// A linked neighbour as a step reads it (`Candidate`): whether it is streaming a file to us, and whether its link
    /// says it answers a query. One radio, so there is no plane to choose and no slow link to tell apart.
    struct Candidate: Sendable, Equatable {
        var id: NodeId
        var streaming: Bool
        var capable: Bool
    }

    /// What one step decided (`Plan`): the neighbours it owes a query, the asks it makes, when it wants to be stepped
    /// again, and the log lines it owes.
    struct Plan: Sendable {
        var query: [NodeId] = []
        var asks: [Ask] = []
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
