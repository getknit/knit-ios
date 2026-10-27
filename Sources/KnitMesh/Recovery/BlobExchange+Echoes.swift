import KnitWire

/// What a want made for an asker may cost here (knit-ios #20, from knit-next's malicious-fork review of 2026-10-26, H3 and
/// H2's prefix item). A `blobreq` is unsigned, and one for a blob we lack makes a want on the asker's behalf, an *echo*
/// (knit-next ADR 2026-10.2drc). A hop budget bounds how deep an echo goes, but not what it costs: before this, one
/// neighbour could ask for 256 made-up hashes, serve junk under each at the next cycle, and have every one stored until
/// Knit next started, its echoes pushing our own fetches out of the want set on the way.
///
/// So an echo is told apart from a want of ours (``Origin``), and bounded three ways:
/// - **The want set.** Every echo is made while the set has room. A full set drops an echo of the asker holding the most,
///   its oldest (``fairVictim(adding:excluding:arriving:)``), and never a want of ours while an echo is left; a new echo
///   that would cost a want of ours is declined. So a fork flooding a full set churns its own echoes, and one contending
///   with an honest root leaves it about half the set.
/// - **Bytes.** What we hold that no row names, and what the echoes fetching now may still bring, stay within
///   ``echoBudgetBytes`` (``EchoBudget``). Over it, a new echo is declined, an echo's next fetch is held back, and a file
///   that lands for an echo alone is refused, so held bytes nobody here names stay under the budget.
/// - **Kept prefixes.** Only a want of ours keeps a cut stream's prefix (``ownWanted``), so an asker's cut streams cannot
///   evict ours from the eight the links keep.
///
/// Android keeps no origin and applies no budget to an echo at knit-next `4408e0fca` (`echoFor`, `BlobExchange.kt:1698-1720`);
/// its `CARRIER_BLOB_BUDGET_BYTES` gates a carrier's pulls alone (`FrameFanout.kt:70-76`). Every rule here is local: none
/// is on the wire, none is in custody or its digest, and a node that applies none of them still interoperates.
extension BlobExchange {
    /// Whose want a want is: ours, or an echo made for the neighbour whose ask created it.
    enum Origin: Sendable, Equatable {
        case own
        case echo(NodeId)
    }

    /// The bytes held that no row names, plus those the echoes fetching now may bring, that an echo may not pass, 128 MiB:
    /// Android's carrier budget (`CARRIER_BLOB_BUDGET_BYTES`, `FrameFanout.kt:76`), which by its KDoc is a local knob
    /// that need not match across nodes, and gates only a carrier's pulls there.
    static let echoBudgetBytes: Int64 = 134_217_728
    /// How often a budget that reads spent may be measured again from the store before an echo is declined: the serve
    /// memo, so one asker's next ask after a sweep freed room finds it.
    static let echoRemeasureMilliseconds: Int64 = serveMemoMilliseconds
    /// The most hashes remembered as refused for the budget until the next sweep.
    static let maxRefusedEchoes = 64
    /// The most files a fresh ask may find waiting on its asker's link and still be queued behind: about 8 × 8 MiB,
    /// minutes of work at Bluetooth's rates. Past it the ask is not queued, nothing is stamped, and the asker asks again
    /// at its floor; a parked ask whose turn came is queued whatever waits. Android's link queue has no bound
    /// (`FramedLink.kt:107`, `Channel.UNLIMITED`), so one asker could queue a serve of every blob held.
    static let maxWaitingServes = 8

    /// The blobs wanted of our own (``Origin/own``): the links keep a cut prefix of these alone.
    var ownWanted: Set<BlobHash> {
        Set(wants.values.filter { $0.origin == .own }.map(\.hash))
    }

    /// Whether `hash` is wanted only as an echo.
    func isEcho(_ hash: BlobHash) -> Bool {
        wants[hash]?.echoFor != nil
    }

    /// Why an ask for `hash`, which no want names yet, makes no echo here, or `nil` when it may: every slot of a full set
    /// holds a want of ours. A hash already wanted is never refused here: the ask only joins its want
    /// (``noteAsker(_:_:_:now:wall:)``).
    func echoRefusal(_ hash: BlobHash) -> String? {
        guard wants[hash] == nil, order.count >= Self.maxWanted, !wants.values.contains(where: { $0.echoFor != nil }) else {
            return nil
        }
        return "every want is ours"
    }

    /// The want a full set drops for a new one of `newAsker`'s, `nil` for ours, `excluding` the new one when it is in the
    /// set already (knit-ios #20). The shape of knit-next's fair custody eviction, which takes from the largest sender
    /// (its #18, ADR 2026-10.7mqm):
    /// - an echo of the asker holding the most echoes, the new one counted toward its asker's share, a tie going to the
    ///   asker whose oldest echo is oldest by when it was made (``order``);
    /// - of that asker's, the oldest by when it was made with no bytes among `arriving` and no ask of its parked, else its
    ///   oldest;
    /// - our own oldest only when no echo is left, and `nil` then for a new echo, which is declined
    ///   (``echoRefusal(_:)``).
    ///
    /// Android drops the oldest want whoever made it (`MAX_FETCHING`). A cap per asker would be a cache smaller than a
    /// root's cycle, which re-asks its whole backlog in one order: the same echoes would stand for good, and the rest never.
    func fairVictim(adding newAsker: NodeId?, excluding: BlobHash?, arriving: Set<BlobHash>) -> BlobHash? {
        // Each asker's echoes oldest first, with where its oldest stands in the order: never empty, as each is made by one.
        var echoes: [NodeId: (oldest: Int, hashes: [BlobHash])] = [:]
        for (index, hash) in order.enumerated() where hash != excluding {
            if let asker = wants[hash]?.echoFor {
                echoes[asker, default: (index, [])].hashes.append(hash)
            }
        }
        let share = { (entry: (key: NodeId, value: (oldest: Int, hashes: [BlobHash]))) in
            entry.value.hashes.count + (entry.key == newAsker ? 1 : 0)
        }
        let largest = echoes.max { lhs, rhs in
            share(lhs) != share(rhs) ? share(lhs) < share(rhs) : lhs.value.oldest > rhs.value.oldest
        }
        guard let theirs = largest?.value.hashes else {
            return newAsker == nil ? order.first { $0 != excluding } : nil
        }
        return theirs.first { !arriving.contains($0) && parked[$0] == nil } ?? theirs.first
    }

    /// Makes room in a full set for `hash`, not wanted yet, which `asker`'s ask, or ours with `nil`, is about to make
    /// (``fairVictim(adding:excluding:arriving:)``): the want dropped goes into ``evicted`` with the neighbours our asks
    /// for it stand on, each owed a `blobcancel` (knit-next ADR 2026-10.nsr7). The engine calls it ahead of
    /// ``recordWant(_:now:wall:author:via:asker:reach:)``, which reads nothing of the links, with the blobs arriving.
    mutating func makeRoom(for hash: BlobHash, asker: NodeId?, arriving: Set<BlobHash>) {
        guard wants[hash] == nil, order.count >= Self.maxWanted, let victim = fairVictim(adding: asker, excluding: nil, arriving: arriving)
        else {
            return
        }
        evicted.append((victim, obtained(victim, from: nil)))
    }

    /// Records `want`, a hash not wanted yet, last in the order. A set still past ``maxWanted`` (one the engine made no
    /// room in, which only a test does) drops ``fairVictim(adding:excluding:arriving:)``'s, reading nothing as arriving,
    /// into ``evicted``. ``echoRefusal(_:)`` turns away an echo that would cost a want of ours. Answers the hashes
    /// dropped.
    @discardableResult
    mutating func admit(_ want: Want) -> [BlobHash] {
        wants[want.hash] = want
        order.append(want.hash)
        var dropped: [BlobHash] = []
        // A victim always exists: ours takes any want, and an echo is admitted to a full set only beside another echo.
        while order.count > Self.maxWanted, let victim = fairVictim(adding: want.echoFor, excluding: want.hash, arriving: []) {
            evicted.append((victim, obtained(victim, from: nil)))
            dropped.append(victim)
        }
        return dropped
    }

    /// The wants ``admit(_:)`` dropped since the last call, and the neighbours each one's asks still stand on.
    mutating func takeEvicted() -> [(hash: BlobHash, asks: [NodeId])] {
        defer { evicted.removeAll() }
        return evicted
    }

    /// Makes the echo of `hash` a want of ours, its bytes already on their way in, so the links keep a prefix of them if
    /// the stream is cut. Its budget and timers stay as they were: the next re-arm from the stores, once nothing is
    /// arriving, refreshes it as any want of ours. Answers whether anything changed.
    mutating func promote(_ hash: BlobHash) -> Bool {
        guard wants[hash]?.echoFor != nil else {
            return false
        }
        wants[hash]?.origin = .own
        return true
    }

    /// The bytes the echoes fetching now may still bring, but `excluding`'s: ``FileIntake/maxFileBytes`` for each with an
    /// ask standing on a holder or its bytes among `arriving`. A blind ask, of a neighbour that cannot say whether it holds
    /// the blob, and an echo nobody in reach holds reserve nothing, so a root with many dead photos never takes the room a
    /// live pull-through needs.
    func echoReservedBytes(arriving: Set<BlobHash>, excluding: BlobHash?) -> Int64 {
        let fetching = wants.values.count { want in
            want.echoFor != nil && want.hash != excluding && (arriving.contains(want.hash) || want.fetch.map { $0.tier != .blind } == true)
        }
        return Int64(fetching) * Int64(FileIntake.maxFileBytes)
    }

    /// Whether `want`, an echo, is held back for want of `room` in the budget (``holdEcho(_:for:_:)``): with none it asks
    /// nobody new.
    mutating func holdsEcho(_ want: inout Want, room: Bool, _ plan: inout Plan) -> Bool {
        guard !room, let asker = want.echoFor else {
            return false
        }
        holdEcho(&want, for: asker, &plan)
        return true
    }

    /// A step of `want`, an echo, held back by the budget: it asks nobody, and the first such step of a cycle is counted
    /// and logged. The re-offer steps it again within 60 s, and the sweep measures the budget anew.
    mutating func holdEcho(_ want: inout Want, for asker: NodeId, _ plan: inout Plan) {
        guard !want.fetchHeld else {
            return
        }
        want.fetchHeld = true
        counts.echoFetchesHeld += 1
        plan.notes.append("blob no-fetch \(want.hash8)… for \(asker) (over budget)")
    }
}

/// The weight of the blobs fetched for askers (knit-ios #20): the bytes we hold that no row names, measured from the store
/// at a start and at each sweep and grown by each echo's file that lands between, so it reads high and never low until the
/// next measure. A sweep, a row naming a blob after it landed, or a blob removed between measures is seen at the next one.
/// Read with the reservation of the echoes fetching now (``BlobExchange/echoReservedBytes(arriving:excluding:)``). Custody's
/// carried photos count too: their blobs stay while a carried frame names them, but they are held for others all the
/// same.
internal struct EchoBudget: Sendable {
    /// The bytes held that no row names, as last measured plus what landed since.
    private(set) var heldForOthers: Int64 = 0
    /// When a measure was last tried, failed or not, on the monotonic clock, or `nil` before the first.
    private(set) var triedAt: Int64?
    /// The hashes whose file was refused for the budget since the last sweep, oldest first.
    private var refused: [BlobHash] = []

    /// A measure from the store is tried at `now`: the next waits ``BlobExchange/echoRemeasureMilliseconds``, so a store
    /// that keeps failing is not read again for every ask.
    mutating func tried(at now: Int64) {
        triedAt = now
    }

    /// The store's measure at `now`. A failed measure is never passed here: an error reads as 0, which would open the
    /// budget, so the last value stands.
    mutating func measured(_ bytes: Int64, at now: Int64) {
        heldForOthers = max(0, bytes)
        triedAt = now
    }

    /// A file of `bytes` stored that no row names.
    mutating func landed(_ bytes: Int64) {
        heldForOthers += max(0, bytes)
    }

    /// Whether no new echo may be made while `reserved` bytes are still on their way.
    func isSpent(reserved: Int64) -> Bool {
        heldForOthers + reserved >= BlobExchange.echoBudgetBytes
    }

    /// Whether `bytes` more fit beside `reserved` ones still on their way.
    func fits(_ bytes: Int64, reserved: Int64) -> Bool {
        heldForOthers + reserved + bytes <= BlobExchange.echoBudgetBytes
    }

    /// Whether a budget that reads spent may be measured again at `now`.
    func mayRemeasure(now: Int64) -> Bool {
        triedAt.map { now - $0 >= BlobExchange.echoRemeasureMilliseconds } ?? true
    }

    /// Remembers `hash` as refused until the next sweep, the oldest forgotten past ``BlobExchange/maxRefusedEchoes``.
    mutating func refuse(_ hash: BlobHash) {
        guard !refused.contains(hash) else {
            return
        }
        refused.append(hash)
        if refused.count > BlobExchange.maxRefusedEchoes {
            refused.removeFirst(refused.count - BlobExchange.maxRefusedEchoes)
        }
    }

    /// Whether `hash`'s file was refused for the budget since the last sweep.
    func hasRefused(_ hash: BlobHash) -> Bool {
        refused.contains(hash)
    }

    /// The sweep: what was refused may be asked for again.
    mutating func forgetRefused() {
        refused.removeAll()
    }
}
