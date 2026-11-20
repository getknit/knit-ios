public import KnitStore
public import KnitWire

/// Who this node believes holds each frame it carries, the roster each group row names, and what each peer was handed and
/// did not keep (the `custody-carry-policy` contract, §1, §3 and §6). Engine state, single-threaded and in memory only: a
/// restart starts it empty, and eviction then orders by `(sentAt, id)` until digests refill it.
///
/// **Holders** (§3) are what the global cap's key 2 reads (``CustodyRules/evictions(after:among:limits:carry:)``): at most
/// ``CustodyLimits/spreadMax`` distinct peers per frame, a peer joining when its digest lists the frame (seen), when the
/// frame arrived from it (source, counted in the frame's own write by ``carry(counting:for:)``), or one round interval after
/// a round released it there with the link still up (handed). A digest is the peer's latest word: the peer leaves every
/// frame its digest lacks, but one still pending in its memo. Only a proven link feeds any of it, which the engine checks:
/// an unproven link's node id is only a claim. Ourselves are never counted.
///
/// **Rosters** order a round's third tier without loading a row: read once when custody stores a group frame, at most
/// ``GroupInfo/maxMembers`` member ids remembered. A longer roster, which no honest build makes, is not remembered.
///
/// **The memo** (§6) keeps a released id from going to the same peer again until a digest judges it, and an id the peer
/// did not keep from going again for ``notKeptLapseMilliseconds``. A frame addressed to the peer is never pending and never
/// marked. Android's is `LinkPushRounds` generalised (`ForwardSync.kt:280-356`, knit-next #235).
///
/// Every entry dies with its row: ``forget(_:)`` for what a write evicted and what a receipt purged, ``clear(_:)`` before an
/// id is written, so a returning frame never inherits holders or a roster, and ``prune(keeping:)`` against the live ids
/// after a sweep. Times are the engine's monotonic clock.
public struct CarryLedger: Sendable {
    /// How long after a round's release its hand-off is credited: one Bluetooth round interval
    /// (``CustodySync/roundMilliseconds``), the only plane this port has.
    public static let creditMilliseconds = CustodySync.roundMilliseconds
    /// How long before a digest a release must be for that digest to judge it on Bluetooth (`JUDGE_AFTER_MS`): a digest that
    /// crossed the release in flight would otherwise judge it wrongly.
    public static let judgeAfterMilliseconds: Int64 = 20_000
    /// How long a not-kept mark withholds an id from its peer, and how long an id stays pending unjudged
    /// (`NOT_KEPT_LAPSE_MS`).
    public static let notKeptLapseMilliseconds: Int64 = 600_000
    /// The most peers with a memo (`MEMO_MAX_PEERS`), the least recently used out first, never a linked peer's while
    /// another's can go.
    public static let maxMemoPeers = 64
    /// The most roster members remembered for a row (`MAX_MEMBERS`, ``GroupInfo/maxMembers``).
    public static let maxRosterMembers = GroupInfo.maxMembers

    /// One peer's memo.
    struct Memo: Sendable {
        /// Each id released to the peer and not yet judged, with when it was released.
        var pending: [ExactKey: Int64] = [:]
        /// Each id the peer did not keep, with when the mark was set.
        var notKept: [ExactKey: Int64] = [:]
        /// When the memo was last written, for the least-recent bound.
        var touched: Int64
    }

    /// One round's releases to a peer, credited at ``due`` unless the peer's link went first.
    struct Credit: Sendable {
        var peer: NodeId
        var ids: [ExactKey]
        var due: Int64
    }

    /// This node, never counted among a frame's holders, or `nil` for a ledger no node owns (a test's).
    private let own: NodeId?
    private var holders: [ExactKey: [NodeId]] = [:]
    private var rosters: [ExactKey: [ExactKey]] = [:]
    /// Each proven peer's memo, read by the tests through `@testable`.
    private(set) var memos: [NodeId: Memo] = [:]
    /// In release order, so the first is the earliest due.
    private var credits: [Credit] = []

    /// An empty ledger for the node `own`.
    public init(own: NodeId?) {
        self.own = own
    }

    // MARK: Reading

    /// How many peers are believed to hold `id`, by its bytes.
    public func spread(of id: String) -> Int {
        holders[ExactKey(id)]?.count ?? 0
    }

    /// The peers believed to hold `id`, in the order they joined.
    public func holders(of id: String) -> [NodeId] {
        holders[ExactKey(id)] ?? []
    }

    /// The roster remembered for `id`, or `nil` for a row not classified: never a group frame, a roster past the bound, or
    /// one not read since the start.
    public func roster(of id: ExactKey) -> [ExactKey]? {
        rosters[id]
    }

    /// How many frames have an entry, holders or roster: what the bound of ``CustodyLimits/maxFrames`` is checked against.
    public var count: Int {
        max(holders.count, rosters.count)
    }

    /// Whether `id` is withheld from `peer` by its memo at `now`: pending, released less than ``notKeptLapseMilliseconds``
    /// ago, or marked not kept less than that ago.
    public func withholds(_ id: ExactKey, from peer: NodeId, now: Int64) -> Bool {
        guard let memo = memos[peer] else {
            return false
        }
        if let released = memo.pending[id], now - released < Self.notKeptLapseMilliseconds {
            return true
        }
        if let marked = memo.notKept[id], now - marked < Self.notKeptLapseMilliseconds {
            return true
        }
        return false
    }

    /// Whether `id` is pending in `peer`'s memo at `now`.
    func isPending(_ id: ExactKey, for peer: NodeId, now: Int64) -> Bool {
        guard let released = memos[peer]?.pending[id] else {
            return false
        }
        return now - released < Self.notKeptLapseMilliseconds
    }

    /// When the next hand-off is credited, or `nil` when none waits: an engine deadline (ADR 2026-09.gq84).
    public var nextCredit: Int64? {
        credits.first?.due
    }

    /// The carry a write of `id` reads (§5, key 2): this ledger's holders, and for `id` itself `source` alone, since the peer
    /// it arrived from holds it whether or not we keep it (§3, "source"), and any entry of an id custody does not hold is
    /// stale. A write of an id custody holds evicts nothing and reads no carry.
    public func carry(counting source: NodeId?, for id: String) -> some CustodyCarry {
        let counted = Self.sourceCountsInItsOwnWrite && source != own ? source : nil
        return LedgerCarry(holders: holders, newcomer: ExactKey(id), source: counted)
    }

    /// Whether a frame's source counts among its holders in the frame's own write (§3, "source"), the one place the rule
    /// lives. Without it a frame a full peer serves back has spread 0 while it is written and outranks every shared row, so
    /// two linked full stores swap a frame per exchange for good (`LinkPipeCustodyCarryTests`).
    static let sourceCountsInItsOwnWrite = true

    // MARK: The death feed

    /// Drops every entry of an id its write just inserted, which had no row before: a stale one can only be a row that died
    /// by a path the feed did not see, such as a store unit that rolled back.
    public mutating func clear(_ id: String) {
        forget(id)
    }

    /// Drops `id`'s holders, roster and uncredited hand-offs: its row is gone.
    public mutating func forget(_ id: String) {
        let key = ExactKey(id)
        holders[key] = nil
        rosters[key] = nil
        for index in credits.indices {
            credits[index].ids.removeAll { $0 == key }
        }
    }

    /// Keeps only the entries of `live`, the ids custody holds now. The caller reads them in a store unit and skips the
    /// prune when the read fails: a failed read answers nothing held, which would wipe the ledger.
    public mutating func prune(keeping live: Set<ExactKey>) {
        holders = holders.filter { live.contains($0.key) }
        rosters = rosters.filter { live.contains($0.key) }
        for index in credits.indices {
            credits[index].ids.removeAll { !live.contains($0) }
        }
    }

    // MARK: Writes

    /// What a write of `frame` came to: the rows it evicted die, and if the frame is held after it, its roster is remembered
    /// and `source`, the proven peer it arrived from, joins its holders. Nothing is recorded for a frame not held.
    public mutating func noteWrite(_ result: CustodyStoreResult, of frame: RelayEnvelope, from source: NodeId?, spreadMax: Int) {
        for id in result.evicted {
            forget(id)
        }
        guard result.held, result.changed else {
            return
        }
        remember(frame)
        if let source {
            add(source, holding: ExactKey(frame.id), spreadMax: spreadMax)
        }
    }

    /// Remembers `frame`'s roster when it names a group of at most ``maxRosterMembers`` members, for a row custody holds.
    public mutating func remember(_ frame: RelayEnvelope) {
        guard let members = frame.group?.members, members.count <= Self.maxRosterMembers else {
            return
        }
        rosters[ExactKey(frame.id)] = members.map(ExactKey.init)
    }

    // MARK: Digests

    /// A digest from the proven `peer` arrived at `now`, listing `listed` of the ids we hold, `live`. Judges the peer's
    /// pending releases (§6), then counts the peer among the holders of what it lists and out of what it lacks (§3, seen and
    /// latest word). Answers how many ids were marked not kept.
    public mutating func noteDigest(
        listing listed: Set<ExactKey>, from peer: NodeId, live: Set<ExactKey>, now: Int64, spreadMax: Int
    ) -> Int {
        let marked = judge(listed, from: peer, live: live, now: now)
        for id in listed {
            add(peer, holding: id, spreadMax: spreadMax)
        }
        var latest: [ExactKey: [NodeId]] = [:]
        for (id, peers) in holders {
            let left = listed.contains(id) || isPending(id, for: peer, now: now) ? peers : peers.filter { $0 != peer }
            if !left.isEmpty {
                latest[id] = left
            }
        }
        holders = latest
        return marked
    }

    /// Judges each id pending for `peer` released at least ``judgeAfterMilliseconds`` before `now`: listed, it was kept;
    /// lacking and still held, it was not, and the peer leaves its holders; no longer held, it just leaves. A release past
    /// ``notKeptLapseMilliseconds`` leaves unjudged.
    private mutating func judge(_ listed: Set<ExactKey>, from peer: NodeId, live: Set<ExactKey>, now: Int64) -> Int {
        guard var memo = memos[peer] else {
            return 0
        }
        var marked = 0
        for (id, released) in memo.pending {
            if now - released >= Self.notKeptLapseMilliseconds {
                memo.pending[id] = nil
                continue
            }
            guard now - released >= Self.judgeAfterMilliseconds else {
                continue
            }
            memo.pending[id] = nil
            if !listed.contains(id), live.contains(id) {
                memo.notKept[id] = now
                holders[id]?.removeAll { $0 == peer }
                marked += 1
            }
        }
        memo.notKept = memo.notKept.filter { now - $0.value < Self.notKeptLapseMilliseconds }
        memo.touched = now
        memos[peer] = memo
        return marked
    }

    // MARK: Rounds

    /// A round released `ids` to the proven `peer` at `now`: each but those addressed to the peer goes pending in its memo,
    /// and all are credited one round interval later if the link holds. `linked` are the peers holding a link now, for the
    /// memo's bound.
    public mutating func released(_ ids: [CustodySync.Release], to peer: NodeId, now: Int64, linked: Set<NodeId>) {
        guard !ids.isEmpty else {
            return
        }
        var memo = memos[peer] ?? Memo(touched: now)
        for release in ids where !release.addressed {
            memo.pending[ExactKey(release.id)] = now
        }
        memo.touched = now
        if memos[peer] == nil {
            bound(linked: linked)
        }
        memos[peer] = memo
        credits.append(Credit(peer: peer, ids: ids.map { ExactKey($0.id) }, due: now + Self.creditMilliseconds))
    }

    /// Credits each hand-off due by `now`: its peer joins the holders of every id in it still held.
    public mutating func credit(now: Int64, spreadMax: Int) {
        while let first = credits.first, first.due <= now {
            credits.removeFirst()
            for id in first.ids {
                add(first.peer, holding: id, spreadMax: spreadMax)
            }
        }
    }

    /// `peer`'s link went: its memo, pending and not-kept ids alike, and its uncredited hand-offs go. Its holders stay, since
    /// it still holds what it held.
    public mutating func linkDown(_ peer: NodeId) {
        memos[peer] = nil
        credits.removeAll { $0.peer == peer }
    }

    /// Makes room for one more memo: the least recently used of a peer not linked goes, or failing that the least recently
    /// used of all.
    private mutating func bound(linked: Set<NodeId>) {
        guard memos.count >= Self.maxMemoPeers else {
            return
        }
        let byAge = memos.sorted { ($0.value.touched, $0.key) < ($1.value.touched, $1.key) }
        if let oldest = byAge.first(where: { !linked.contains($0.key) }) ?? byAge.first {
            memos[oldest.key] = nil
        }
    }

    /// Counts `peer` among `id`'s holders, unless it is us, already counted, or the frame has ``CustodyLimits/spreadMax``
    /// already: a ninth is not recorded.
    private mutating func add(_ peer: NodeId, holding id: ExactKey, spreadMax: Int) {
        guard peer != own else {
            return
        }
        var peers = holders[id] ?? []
        guard !peers.contains(peer), peers.count < spreadMax else {
            return
        }
        peers.append(peer)
        holders[id] = peers
    }
}

/// The carry one write reads: the ledger's holders, and the newcomer's source alone for the newcomer.
private struct LedgerCarry: CustodyCarry {
    let holders: [ExactKey: [NodeId]]
    let newcomer: ExactKey
    let source: NodeId?

    func holders(of id: String) -> Int {
        let key = ExactKey(id)
        guard key == newcomer else {
            return holders[key]?.count ?? 0
        }
        return source == nil ? 0 : 1
    }
}
