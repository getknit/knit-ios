public import KnitWire

/// The inits this identity answered, kept beside its prekeys in the identity's own item (ADR 2026-10.wcex).
///
/// **Why.** An iPhone reinstall keeps the Keychain, so the identity and the prekeys, and loses the database, so every
/// session (ADR 2026-09.tkww). For a day afterwards custody serves the node back its peers' openers: the DMs their inits
/// rode, signed, against a prekey the Keychain still holds. Read as a first contact, one rebuilds a root the peer may
/// have left, or races the node's own reset by node id and wins (ADR 2026-10.5sk9's P5d limits). Kotlin never meets it:
/// its restore keeps the message rows, whose exists-gate stops the opener, and its idempotence rule for an init it already
/// resolved (`RatchetEngine.kt:575-578` at `4f3cd995`, the `peerInitEphPub` anchor; the stamp rule at `:593-594`) dies
/// with the session row here. Keeping the ephemeral of each init a session anchored, outside the database, carries that
/// rule across the reinstall, keyed by the ephemeral as Kotlin's anchor is, never by a stamp.
///
/// **The stored form grows additively,** as the prekeys did: `answered: [{peer, eph, at}]`, a fourth key of the identity's
/// map, `peer` the node id's 16 bytes, `eph` the init's 32-byte ephemeral and `at` our wall clock when the open that
/// anchored it committed. An older build reads its identity and prekeys by key, and its rotation writes every other entry
/// back as it was stored, so it neither loses nor reads this one.
///
/// **A write** reads the item, checks the identity in it byte for byte, replaces `answered` alone, writes and reads back,
/// and only then changes ``PrekeyRing/answeredInits``, as a rotation does. One that fails leaves the ring and the store as
/// they were: the next answered open tries again, and a reinstall before then meets the opener as every build before this
/// one did. Loading reads it with the prekeys, in the same read, which throws before the first unlock.
extension PrekeyRing {
    /// How long an answered init is kept: custody's day doubled (`STRANDED_TAIL_MS`, knit-next ADR 026), since custody
    /// expires a frame at `sentAt + 24 h` on its sender's clock and a relay's, and `at` is ours.
    public static let answeredMilliseconds: Int64 = 172_800_000
    /// The most answered inits kept for one peer, the newest. An honest peer starts one session a day and resets at most
    /// every six hours, or every minute on demand, which a re-served frame of the eight before still has to outlive.
    public static let answeredPerPeer = 8
    /// The most answered inits kept in all, the newest: two days of new sessions with 256 peers, about 20 KB in the item.
    public static let answeredCount = 256

    private static let answeredKey = "answered"
    private static let peerKey = "peer"
    private static let ephKey = "eph"
    private static let atKey = "at"

    /// One init a session of ours anchored: the peer's node id, the init's ephemeral, and when the open that anchored it
    /// committed, on our clock.
    public struct AnsweredInit: Sendable, Equatable {
        /// The peer whose init it was.
        public let peer: NodeId
        /// The init's ephemeral public key, which knows it: an init is known by its ephemeral, never its stamp.
        public let eph: [UInt8]
        /// When our open of it committed, on our wall clock.
        public let at: Int64

        /// An answered init.
        public init(peer: NodeId, eph: [UInt8], at: Int64) {
            self.peer = peer
            self.eph = eph
            self.at = at
        }
    }

    /// Whether `eph` is the ephemeral of an init from `peer` that a session of this identity anchored within
    /// ``answeredMilliseconds`` of `now`. Ephemerals and node ids compare by their bytes.
    public func answered(_ eph: [UInt8], by peer: NodeId, now: Int64) -> Bool {
        answeredInits.contains { $0.peer == peer && $0.eph == eph && Self.isKept($0, now: now) }
    }

    /// Keeps `eph`, the ephemeral of an init from `peer` that an open of ours anchored and committed at `now`, and answers
    /// whether it wrote: `false` when it is already kept. Call it once the open's unit has committed, never inside one: the
    /// store is the Keychain, which a unit's rollback cannot undo. It prunes what is past ``answeredMilliseconds``, keeps
    /// the newest ``answeredPerPeer`` for each peer and the newest ``answeredCount`` in all, and drops a stored entry this
    /// build cannot read, which only a newer build could have written and which is a hint, never a key.
    @discardableResult
    public mutating func keepAnswered(_ eph: [UInt8], from peer: NodeId, now: Int64) throws(Failure) -> Bool {
        try keepAnswered([AnsweredInit(peer: peer, eph: eph, at: now)], now: now)
    }

    /// Keeps each of `inits` not already kept, stamped `now`, in one write, and answers whether it wrote: the start's pass
    /// over the anchors the session rows hold, which a write that failed or a process ended before it left unkept.
    @discardableResult
    public mutating func keepAnswered(_ inits: [AnsweredInit], now: Int64) throws(Failure) -> Bool {
        let missing = inits.filter { !answered($0.eph, by: $0.peer, now: now) }.map { AnsweredInit(peer: $0.peer, eph: $0.eph, at: now) }
        guard !missing.isEmpty else {
            return false
        }
        let stored = try read()
        let entries = try Self.entries(stored, of: identity)
        let held = try Self.storedAnswers(stored, of: identity)
        let kept = Self.pruned(held + missing, now: now)
        try persist(.array(kept.map(Self.cbor)), as: Self.answeredKey, beside: entries)
        answeredInits = kept
        return true
    }

    /// `inits` with each `(peer, eph)` once, the latest kept, none past ``answeredMilliseconds`` of `now`, at most
    /// ``answeredPerPeer`` for a peer and ``answeredCount`` in all, the newest kept, oldest first.
    static func pruned(_ inits: [AnsweredInit], now: Int64) -> [AnsweredInit] {
        var newestFirst: [AnsweredInit] = []
        var perPeer: [NodeId: Int] = [:]
        // Newest first; of two with one stamp, the later in the list, the one kept last.
        let ordered = inits.enumerated().sorted { ($0.element.at, $0.offset) > ($1.element.at, $1.offset) }.map(\.element)
        for answered in ordered where isKept(answered, now: now) {
            guard !newestFirst.contains(where: { $0.peer == answered.peer && $0.eph == answered.eph }),
                perPeer[answered.peer, default: 0] < answeredPerPeer, newestFirst.count < answeredCount
            else {
                continue
            }
            perPeer[answered.peer, default: 0] += 1
            newestFirst.append(answered)
        }
        return newestFirst.reversed()
    }

    /// Whether `answered` is still kept at `now`. One stamped ahead of `now`, by a wall clock set back since, is kept
    /// until the caps push it out.
    private static func isKept(_ answered: AnsweredInit, now: Int64) -> Bool {
        let (age, overflow) = now.subtractingReportingOverflow(answered.at)
        return overflow || age < answeredMilliseconds
    }

    /// The answered inits this build reads in the `answered` list of the item `stored` holds for `identity`, in the order
    /// stored. It throws when `stored` holds no identity or another one, and when `answered` is not one list.
    static func storedAnswers(_ stored: [UInt8]?, of identity: IdentityKeys) throws(Failure) -> [AnsweredInit] {
        let lists = try entries(stored, of: identity).filter { $0.key == .text(answeredKey) }
        guard let list = lists.first else {
            return []
        }
        guard lists.count == 1, case .array(let items) = list.value else {
            throw .unreadableAnswers
        }
        return items.compactMap(answered(from:))
    }

    /// One stored answered init, or `nil` unless it names a node id, a 32-byte ephemeral and a stamp.
    private static func answered(from item: CBOR) -> AnsweredInit? {
        guard case .bytes(let peer) = field(peerKey, of: item), let node = NodeId(bytes: peer),
            case .bytes(let eph) = field(ephKey, of: item), eph.count == RatchetCrypto.keyByteCount,
            let at = field(atKey, of: item)?.int64
        else {
            return nil
        }
        return AnsweredInit(peer: node, eph: eph, at: at)
    }

    /// An answered init's entry: `{peer, eph, at}`.
    private static func cbor(_ answered: AnsweredInit) -> CBOR {
        .map([
            CBOR.Entry(key: .text(peerKey), value: .bytes(answered.peer.bytes)),
            CBOR.Entry(key: .text(ephKey), value: .bytes(answered.eph)),
            CBOR.Entry(key: .text(atKey), value: CBOR(answered.at)),
        ])
    }
}
