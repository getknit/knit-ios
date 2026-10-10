import KnitWire

/// Fetches content-addressed blobs one hop at a time (`BlobExchange.kt` in knit-next, ADR 2026-10.nh55 and the ADR
/// router's blob rows).
///
/// A node that wants a blob works in *cycles* (knit-next ADR 2026-10.6e5t). A cycle first *queries* each linked
/// neighbour whose HELLO carries ``Capabilities/blobHave`` with an unsigned `blobhave`, then asks the best one that says
/// it holds the blob, alone, with an unsigned `blobreq`. A holder that brings nothing within its grace is queried again,
/// then passed over for the next. Neighbours that cannot be queried get one blind ask of the likeliest holder (the
/// author, then the hop the frame came from), then every other at once once its grace is up (knit-next ADR 2026-10.f7gg).
/// When nobody in reach holds it, a neighbour that lacks it is asked to pull it through, and wants it in turn.
///
/// Nothing is pushed to a node that did not just ask, and nothing is asked for while its bytes stream in or land
/// (knit-next ADR 2026-09.4tx5). Everything here is unsigned, so the books are bounded: at most 256 blobs wanted, each
/// forgotten after 30 minutes unrefreshed; a 45-second serve memo of at most 512 entries; 256 queries remembered; and a
/// budget of answers and a round trip per neighbour, for at most 64 neighbours. This type keeps the books and decides;
/// the engine reads the links and the store, sends what a step decides, and times its next step. Times are on the
/// monotonic clock.
internal struct BlobExchange: Sendable {
    /// The most blobs wanted at once (`MAX_FETCHING`), the bound on what unsigned requests can make us fetch.
    static let maxWanted = 256
    /// A want nobody refreshed ages out after this (`FETCH_TTL_MS`), generous because a blob can take minutes.
    static let wantMilliseconds: Int64 = 1_800_000
    /// How long a serve to one neighbour holds off another of the same blob (`SERVE_MEMO_MS`): shorter than the
    /// 60-second re-ask, so a serve lost when its link died is tried again at the next round.
    static let serveMemoMilliseconds: Int64 = 45_000
    /// The most serves remembered at once (`MAX_SERVE_MEMO`). Android's `FALLBACK_MIME` has no twin here: every blob
    /// this port holds was stored with its type.
    static let maxServeMemo = 512
    /// How long a cycle stands before the next may open (`CYCLE_MS`, which is `ROUND_MS`, which is the serve memo), so
    /// a fresh ask always passes the holder's memo.
    static let cycleMilliseconds = serveMemoMilliseconds
    /// How long an ask has to bring a header in before the next holder is tried (`FIRST_ASK_GRACE_MS`). This port has
    /// no Wi-Fi Aware link for a holder to wait on, so no ask ever gets Android's `BULK_GRACE_MS` on top.
    static let firstAskGraceMilliseconds: Int64 = 5000
    /// How long the choice waits for every queried neighbour's answer (`QUERY_WAIT_MS`), before the neighbour's own
    /// round trip stretches it (``queryWait(for:)``).
    static let queryWaitMilliseconds: Int64 = 5000
    /// The most a neighbour's measured round trip stretches the wait for its answer, or adds to an ask's grace
    /// (`QUERY_WAIT_CAP_MS`, knit-next #140). Past it a neighbour reads as silent anyway, and an ask to a holder still
    /// stands to its floor.
    static let queryWaitCapMilliseconds: Int64 = 30_000
    /// How often a holder streaming us a file is looked at again, so its grace starts when the stream ends
    /// (`STREAM_POLL_MS`).
    static let streamPollMilliseconds: Int64 = 2000
    /// How long a neighbour's stream of another file to us may still have before an idle holder is asked instead
    /// (`STREAM_SWITCH_MS`, knit-next `79f38d3d`).
    static let streamSwitchMilliseconds: Int64 = 30_000
    /// When a neighbour fetching the blob, or one asked to pull it through, is queried again
    /// (`FETCHING_RECHECK_MS`).
    static let fetchingRecheckMilliseconds: Int64 = 10_000
    /// The most times a neighbour asked to pull a blob through is queried again in one cycle (`PULL_RECHECKS`).
    static let pullRechecks = 4
    /// Pull rechecks run only in this many cycles at the start of a dead streak (`PULL_RECHECK_DEAD_CYCLES`).
    static let pullRecheckDeadCycles = 2
    /// Dead cycles double the next cycle's wait at most this many times (`MAX_BACKOFF_SHIFT`): 45 s up to 6 min.
    static let maxBackoffShift = 3
    /// The most confirms one ask gets (`MAX_CONFIRMS`).
    static let maxConfirms = 2
    /// How long past a SENDING answer's `eta` the asker holds on that holder (`HOLD_SLACK_MS`, knit-next ADR 2026-10.nsr7),
    /// and the most an `eta` is taken for (`HOLD_CAP_MS`): a holder's lie costs at most that, plus the slack.
    static let holdSlackMilliseconds: Int64 = 30_000
    static let holdCapMilliseconds: Int64 = 900_000
    /// The most hashes one query names, and one answer is read for (`MAX_QUERY_HASHES`).
    static let maxQueryHashes = 32
    /// The longest hash a query is answered for (`MAX_HASH_CHARS`).
    static let maxHashCharacters = 128
    /// The most queries remembered for matching their answers (`MAX_SENT_QUERIES`).
    static let maxSentQueries = 256
    /// Wants whose timers come due this close together step together, so their queries share a frame
    /// (`TIMER_COALESCE_MS`).
    static let timerCoalesceMilliseconds: Int64 = 1000
    /// How much of a hash the log shows (`LOG_HASH_CHARS`), and of a query's id (`LOG_ID_CHARS`).
    static let shownHashCharacters = 8
    static let shownIdCharacters = 6

    /// One blob served to one neighbour.
    struct Serve: Hashable {
        var hash: BlobHash
        var peer: NodeId
    }

    /// Whether this node queries holders before it asks (`HolderQuery.enabled`, `BuildConfig.BLOB_QUERY` on Android).
    /// Off, every neighbour gets the blind round. Answering a query is never gated.
    let queriesHolders: Bool
    /// What the query has done so far.
    var counts = BlobCounts()

    /// The wanted blobs and how far each fetch has got, and the order they were first wanted in, oldest first.
    var wants: [BlobHash: Want] = [:]
    var order: [BlobHash] = []
    /// The queries the steps since the last flush owe, by neighbour in the order first owed.
    var outbox: [(peer: NodeId, hashes: [BlobHash])] = []
    /// Queries sent, by their envelope id's bytes (ADR 2026-09.jc2x), oldest first.
    var sentQueries: [ExactKey: SentQuery] = [:]
    var sentOrder: [ExactKey] = []
    /// Asks parked behind another copy's feed, by blob and asker, and the blobs in the order their first ask was parked
    /// (``park(_:for:bytes:now:)``).
    var parked: [BlobHash: [NodeId: ParkedAsk]] = [:]
    var parkedOrder: [BlobHash] = []
    /// When the parked asks are next looked at, or `nil` while none is parked (`parkPoll`).
    var parkPollAt: Int64?
    /// Recent serves, oldest first.
    private var serves: [(serve: Serve, at: Int64)] = []
    /// Each neighbour's budget of answers.
    private var answerBudget = AnswerBudget()
    /// How long each neighbour's latest answer took to come back (`answerRtt`, knit-next #140): our own outgoing backlog
    /// on that link, which every wait on it is stretched by.
    var roundTrips = AnswerRoundTrips()

    /// Books for a node that queries holders before asking, or, with `queriesHolders` off, asks blind.
    init(queriesHolders: Bool) {
        self.queriesHolders = queriesHolders
    }

    /// The blobs still wanted, oldest first.
    var wanted: [BlobHash] { order }

    /// How many serves are remembered.
    var servedCount: Int { serves.count }

    /// Whether `hash` is wanted.
    func isWanted(_ hash: BlobHash) -> Bool {
        wants[hash] != nil
    }

    // MARK: Wants

    /// Wants `hash`, or refreshes the want and fills in the hints it lacked (`recordWant`). `author` and `via` rank the
    /// neighbours that cannot be queried; `asker` is a neighbour we are pulling it for, which this cycle neither queries
    /// nor asks. A full set drops its oldest want. Answers the log lines it owes.
    mutating func recordWant(_ hash: BlobHash, now: Int64, author: NodeId?, via: NodeId?, asker: NodeId?) -> [String] {
        guard var want = wants[hash] else {
            wants[hash] = Want(hash: hash, at: now, author: author, via: via, puller: asker)
            order.append(hash)
            if order.count > Self.maxWanted {
                for dropped in order.prefix(order.count - Self.maxWanted) {
                    wants[dropped] = nil
                }
                order.removeFirst(order.count - Self.maxWanted)
            }
            return []
        }
        // Refreshed in place: the order is when it was first wanted, as in Android's insertion-ordered map.
        want.wantedAt = now
        want.author = want.author ?? author
        want.via = want.via ?? via
        var plan = Plan()
        if let asker {
            // It lacks the bytes: not this cycle. Its ask may be what opens the next one, so open it first: opened after,
            // it would forget the mark and query the asker back, and a dead blob's pulls would go back and forth.
            if want.isCycleDue(at: now) {
                openCycle(&want, at: now, &plan)
            }
            want.pullers.insert(asker)
        }
        wants[hash] = want
        return plan.notes
    }

    /// Stops wanting `hash`, now held (`clearFetching`, then `withdrawAsks`), and answers the neighbours asked for it whose
    /// ask still stands, but `from`, whose link brought it. Each is owed a `blobcancel` (knit-next ADR 2026-10.nsr7), so a
    /// copy one queued for us is not sent as a second.
    mutating func obtained(_ hash: BlobHash, from: NodeId?) -> [NodeId] {
        guard var want = wants[hash] else {
            return []
        }
        let asked = want.askedAt.keys.sorted().filter { $0 != from && want.withdraw($0) }
        forget(hash)
        return asked
    }

    /// Stops wanting `hash`: it arrived, or is held some other way.
    mutating func forget(_ hash: BlobHash) {
        guard wants.removeValue(forKey: hash) != nil else {
            return
        }
        order.removeAll { $0 == hash }
    }

    /// Drops wants no one refreshed within ``wantMilliseconds``, and answers how many (`sweepExpired`). The database
    /// re-arms a blob still missing at the next re-ask (knit-next ADR 2026-09.ptv8).
    mutating func sweep(now: Int64) -> Int {
        let expired = wants.filter { now - $0.value.wantedAt > Self.wantMilliseconds }.keys
        for hash in expired {
            forget(hash)
        }
        return expired.count
    }

    /// Neighbours that just linked, or linked again (`linked`): an ask or a query sent before may have died with the old
    /// link, so each is open to every cycle again, its answer and failure forgotten, and a fetch that went to it starts
    /// over. Its round trip goes too: a new link, a new queue. Call it ahead of the link-up's steps.
    mutating func linked(_ ids: Set<NodeId>) {
        roundTrips.forget(ids)
        for hash in order {
            wants[hash]?.forgetLinks(ids)
        }
    }

    /// The wants whose ask or hold stands on one of `ids`, oldest first (`unlinked`, knit-next #140): when those links
    /// go, the engine steps them at once, so the next holder is asked now rather than at the next timer or tick.
    func fetches(on ids: Set<NodeId>) -> [BlobHash] {
        order.filter { hash in wants[hash]?.fetch.map { ids.contains($0.peer) } == true }
    }

    // MARK: Timers

    /// Steps `hash` again at `at` unless an earlier step is already due: the earliest wake wins (`armTimer`).
    mutating func arm(_ hash: BlobHash, at: Int64) {
        guard let due = wants[hash].map({ $0.timerDue ?? .max }), due > at else {
            return
        }
        wants[hash]?.timerDue = at
    }

    /// When a want is next due a step, or `nil` when none is.
    var nextDeadline: Int64? {
        wants.values.compactMap(\.timerDue).min()
    }

    /// The wants due a step at `now`, oldest first, with every one due within ``timerCoalesceMilliseconds`` of it, so
    /// their queries share one frame per neighbour (`takeDue`). Each is disarmed, so it is stepped once.
    mutating func takeDue(now: Int64) -> [BlobHash] {
        guard let earliest = nextDeadline, earliest <= now else {
            return []
        }
        let due = order.filter { hash in wants[hash]?.timerDue.map { $0 <= now + Self.timerCoalesceMilliseconds } ?? false }
        for hash in due {
            wants[hash]?.timerDue = nil
        }
        return due
    }

    // MARK: Serving

    /// Whether to serve `hash` to `peer` now, which stamps the serve (`servedRecently`): not inside the memo of an
    /// earlier serve to that neighbour.
    mutating func shouldServe(_ hash: BlobHash, to peer: NodeId, now: Int64) -> Bool {
        serves.removeAll { now - $0.at >= Self.serveMemoMilliseconds }
        let serve = Serve(hash: hash, peer: peer)
        guard !serves.contains(where: { $0.serve == serve }) else {
            return false
        }
        serves.append((serve, now))
        if serves.count > Self.maxServeMemo {
            serves.removeFirst(serves.count - Self.maxServeMemo)
        }
        return true
    }

    /// Forgets a serve that never went out, so the next ask is served at once (`forgetServed`).
    mutating func forgetServe(_ hash: BlobHash, to peer: NodeId) {
        let serve = Serve(hash: hash, peer: peer)
        serves.removeAll { $0.serve == serve }
    }

    /// Whether `hash` was served to `peer` inside the memo (`memoHolds`): a peek for a holder query's answer, which
    /// stamps nothing and prunes nothing, since a query is not an ask.
    func memoHolds(_ hash: BlobHash, for peer: NodeId, now: Int64) -> Bool {
        let serve = Serve(hash: hash, peer: peer)
        return serves.contains { $0.serve == serve && now - $0.at < Self.serveMemoMilliseconds }
    }

    // MARK: Answering

    /// The hashes of a holder query worth answering (`onHaveQuery`): none empty or longer than
    /// ``maxHashCharacters``, each once, the first ``maxQueryHashes``. The rest are ignored, not refused.
    static func answerable(_ hashes: [String]) -> [String] {
        var seen = Set<ExactKey>()
        var asked: [String] = []
        for hash in hashes where !hash.isEmpty && hash.utf16.count <= maxHashCharacters && seen.insert(ExactKey(hash)).inserted {
            asked.append(hash)
            if asked.count == maxQueryHashes {
                break
            }
        }
        return asked
    }

    /// Whether `peer` may have another answer now (`admitQuery`), which spends from its budget.
    mutating func admitQuery(from peer: NodeId, now: Int64) -> Bool {
        answerBudget.admit(peer, now: now)
    }
}

/// A token bucket per neighbour for answering holder queries (`answerBudget` and `admitQuery`, `BlobExchange.kt:832-841`),
/// the bound on an unsigned flood of them: 16 deep, refilled continuously at one a second, one spent per query whatever
/// it names, and at most 64 neighbours remembered, the least recently heard dropped first. A neighbour dropped comes back
/// with a full bucket.
internal struct AnswerBudget: Sendable {
    /// How many answers a neighbour may have in a burst (`ANSWER_BURST`).
    static let burst = 16.0
    /// One answer comes back every this long (`ANSWER_REFILL_MS`).
    static let refillMilliseconds = 1000.0
    /// The most neighbours whose budgets are remembered (`MAX_ANSWER_BUCKETS`).
    static let maxPeers = 64

    /// One neighbour's budget: the answers it has left, and when they were last counted.
    private struct Bucket {
        var peer: NodeId
        var tokens: Double
        var at: Int64
    }

    private var buckets: [Bucket] = []

    /// Whether `peer` may have an answer at `now`, spending one if so. The bucket refills and moves to the back either
    /// way, as Android's access-ordered map does.
    mutating func admit(_ peer: NodeId, now: Int64) -> Bool {
        var tokens = Self.burst
        if let index = buckets.firstIndex(where: { $0.peer == peer }) {
            let bucket = buckets.remove(at: index)
            tokens = min(Self.burst, bucket.tokens + Double(max(0, now - bucket.at)) / Self.refillMilliseconds)
        }
        let admitted = tokens >= 1
        buckets.append(Bucket(peer: peer, tokens: admitted ? tokens - 1 : tokens, at: now))
        if buckets.count > Self.maxPeers {
            buckets.removeFirst(buckets.count - Self.maxPeers)
        }
        return admitted
    }
}

/// How long each neighbour's latest answer took to come back (`answerRtt`, knit-next #140), the backlog of our own
/// frames on that link. A wait for its answer, or for an ask's header, is stretched by it, so an asker whose sends are
/// queued never reads its own lag as the neighbour's silence. At most ``AnswerBudget/maxPeers`` neighbours are
/// remembered, the one answered longest ago dropped first; Android also counts a read as a use, which only matters past
/// that many neighbours.
internal struct AnswerRoundTrips: Sendable {
    private var trips: [(peer: NodeId, milliseconds: Int64)] = []

    /// `peer`'s latest answer took `milliseconds`.
    mutating func record(_ peer: NodeId, _ milliseconds: Int64) {
        trips.removeAll { $0.peer == peer }
        trips.append((peer, max(0, milliseconds)))
        if trips.count > AnswerBudget.maxPeers {
            trips.removeFirst(trips.count - AnswerBudget.maxPeers)
        }
    }

    /// Forgets the neighbours that linked again.
    mutating func forget(_ peers: Set<NodeId>) {
        trips.removeAll { peers.contains($0.peer) }
    }

    /// `peer`'s latest round trip, or `nil` before any answer of its came back.
    subscript(_ peer: NodeId) -> Int64? {
        trips.last { $0.peer == peer }?.milliseconds
    }
}
