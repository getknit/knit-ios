import KnitStore
import KnitWire

/// The sealed receipts we minted for DMs addressed to us, so a re-delivery of a DM we already acked in this era mints no
/// other (knit-next #176, ADR 2026-10.8hn6; `DmReAckLedger`, knit-next `DmReAckLedger.kt` at `afdd37204`).
///
/// **Why.** The pre-decrypt exists-gate (``MeshEngine/acknowledge(_:sender:reDelivery:)``'s one gated caller) answers
/// every re-delivered DM, and toward an author who reads sealed receipts that answer was a new sealed `CTL_RECEIPT` under a
/// fresh id: flooded, carried by every node for a day, a chain key spent. A sealed receipt purges nothing (ADR 2026-09.p6nb,
/// amended), so nothing stopped the next copy, and one delivered DM could buy a receipt per router window, about 144 a day:
/// a carrier whose quota kept a DM ours evicted, or a back-fill fed by two holders that relays one holder's copy to us.
///
/// **What skips a re-seal** is ``heldReceipt(acked:currentRootTag:now:)``'s answer and the caller's custody read; the caller
/// checks the rest, an author who can read a sealed receipt. iOS has no LoRa plane, so Kotlin's LoRa exemption is empty here.
///
/// - **The era.** An entry names the session root its receipt was sealed under (``Entry/rootTag``), taken from the seal's
///   own result, never a session read after it. A re-delivery under another root, or with no session held, gets one fresh
///   receipt, since the old one was sealed into an era the author may have dropped with its receive state (knit-next ADR
///   2026-10.gcrd, ADR 2026-10.dmgw's re-seal).
/// - **The floor.** Held in custody is not applied at the author: it custodies a frame before it opens it, so a receipt it
///   holds and never applied is never re-served, and its digest hides it from every carrier. So an entry re-arms
///   ``floor(step:)`` after its last receipt, 15 min doubling per same-era re-seal to a 4 h ceiling: at most 10 receipts a
///   DM a day instead of 144.
/// - **Live in our own custody**, which the caller reads with ``KnitStore/CustodyStore/frame(_:now:)``, never `contains`,
///   which counts an expired row the sweep has not reached: a receipt our quota or the TTL dropped is re-served by nobody,
///   so the re-delivery is the only way back to a ✓✓, and it re-seals.
///
/// Only ``MeshEngine/sendSealedReceipt(for:to:)`` records, for the acked DM's own id, never the room ids riding along,
/// which ``AckSync`` owns. A reinstalled author that lost its session now gets one `NO_SESSION` piece of reset evidence per
/// floor from our re-acks, not one per copy; Kotlin has the same bound. In memory only, bounded oldest receipt first at
/// custody's row cap and aged out custody's TTL after an entry's last receipt (by then that receipt has left custody, so it
/// would re-seal anyway); a restart re-arms one receipt per held DM. Pure: the caller passes the wall clock, the one
/// custody's `now` reads. Ids compare by their bytes (ADR 2026-09.jc2x).
public struct DmReAckLedger: Sendable {
    /// One acked DM: the root its last receipt was sealed under, that receipt's frame id, when, and how many times it was
    /// re-sealed in this era.
    public struct Entry: Sendable, Equatable {
        /// ``KnitCrypto/RatchetCrypto/rootTag(_:)`` of the root the receipt was sealed under.
        public let rootTag: Int64
        /// The receipt's own frame id.
        public let receiptId: String
        /// Our wall clock when it was sealed, its `sentAt`.
        public let sealedAt: Int64
        /// Same-era re-seals so far, capped at ``maxStep``.
        public let step: Int
    }

    /// The first re-arm floor, 15 minutes: past the router's 10-minute seen window, the heal heartbeat's 15 (`FLOOR_MS`).
    public static let floorMilliseconds: Int64 = 900_000
    /// The ceiling the doubling stops at, 4 hours (`MAX_FLOOR_MS`).
    public static let maxFloorMilliseconds: Int64 = 14_400_000
    /// 15 min << 4 is 4 h; a step past it would only overflow the shift (`MAX_STEP`).
    public static let maxStep = 4

    /// The re-arm floor after `step` same-era re-seals: ``floorMilliseconds`` doubling, capped at ``maxFloorMilliseconds``
    /// (`floorMs`).
    public static func floor(step: Int) -> Int64 {
        min(floorMilliseconds << min(max(step, 0), maxStep), maxFloorMilliseconds)
    }

    /// The most entries held, custody's row cap (`DEFAULT_MAX_ROWS`).
    public let capacity: Int
    /// How long after its last receipt an entry ages out, custody's TTL (`DEFAULT_TTL_MS`).
    public let ttlMilliseconds: Int64

    private var entries: [ExactKey: Entry] = [:]
    /// The acked ids, oldest receipt first; a re-record moves an id to the end.
    private var order: [ExactKey] = []

    /// A ledger bounded as custody is: custody's row cap, 1000 entries, each aged out custody's TTL, 24 h, after its last
    /// receipt (`DEFAULT_MAX_ROWS`, `DEFAULT_TTL_MS`).
    public init() {
        let limits = CustodyLimits()
        self.init(capacity: limits.maxFrames, ttlMilliseconds: limits.ttlMilliseconds)
    }

    /// A ledger of at most `capacity` entries, each aged out `ttlMilliseconds` after its last receipt: for a test.
    public init(capacity: Int, ttlMilliseconds: Int64) {
        self.capacity = capacity
        self.ttlMilliseconds = ttlMilliseconds
    }

    /// How many acked DMs the ledger holds.
    public var count: Int { entries.count }

    /// The entry for `ackedId`, for tests.
    public func entry(_ ackedId: String) -> Entry? {
        entries[ExactKey(ackedId)]
    }

    /// Records that `receiptId`, sealed under the root `rootTag` names at `now`, acks `ackedId` (`record`). A re-seal in the
    /// same era doubles the floor; one under another root starts that era's floor afresh. The id moves to the newest end,
    /// and past the bound the oldest receipt's entry goes.
    public mutating func record(acked ackedId: String, rootTag: Int64, receiptId: String, now: Int64) {
        let key = ExactKey(ackedId)
        let previous = remove(key)
        let step = previous.map { $0.rootTag == rootTag ? min($0.step + 1, Self.maxStep) : 0 } ?? 0
        entries[key] = Entry(rootTag: rootTag, receiptId: receiptId, sealedAt: now, step: step)
        order.append(key)
        while order.count > max(capacity, 0) {
            entries[order.removeFirst()] = nil
        }
    }

    /// The receipt that already answers a re-delivery of `ackedId` at `now` under the root `currentRootTag` names, or `nil`
    /// when the re-delivery must re-seal (`heldReceipt`): never acked here (or aged out, or evicted), acked under another
    /// root or with no session held now (`nil`), or past the floor. The caller still re-seals when the receipt this answers
    /// is no longer live in its own custody.
    ///
    /// A negative age is our wall clock stepped back (a network fix after weeks offline): read as past the floor, and the
    /// entry dropped, or the jump would hold back the held-but-unapplied re-arm by its own size. An entry past the TTL is
    /// dropped too.
    public mutating func heldReceipt(acked ackedId: String, currentRootTag: Int64?, now: Int64) -> String? {
        let key = ExactKey(ackedId)
        guard let entry = entries[key] else {
            return nil
        }
        let (age, overflow) = now.subtractingReportingOverflow(entry.sealedAt)
        guard !overflow, age >= 0, age < ttlMilliseconds else {
            remove(key)
            return nil
        }
        guard let currentRootTag, entry.rootTag == currentRootTag, age < Self.floor(step: entry.step) else {
            return nil
        }
        return entry.receiptId
    }

    @discardableResult
    private mutating func remove(_ key: ExactKey) -> Entry? {
        guard let entry = entries.removeValue(forKey: key) else {
            return nil
        }
        order.removeAll { $0 == key }
        return entry
    }
}
