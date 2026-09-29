public import KnitStore
public import KnitWire

/// Store-and-forward over a link (`ForwardSync.kt`): which frames this node takes into custody, what it serves a
/// neighbour whose digest lists what it holds, and what a receipt purges.
///
/// The link-up and 60-second digest exchange is the whole protocol. Each side sends the ids of every live frame
/// it carries; on receiving the other's, it serves every live frame the list omits. Android serves custody only
/// in answer to a digest, so a node that never sends one never gets back-filled (`.agents/context/custody.md`).
public struct CustodySync: Sendable {
    /// How long a purged DM's id stays tombstoned: the custody TTL, so the tombstone outlives every copy still
    /// in flight (`ACK_TOMBSTONE_TTL_MS`).
    public static let tombstoneMilliseconds: Int64 = 86_400_000

    /// Ids purged by a receipt, on the wall clock, so a copy an unvaccinated peer re-serves is not taken again.
    private var tombstones: SeenSet

    /// Every receipt, keyed by the acknowledged id and its acker, for the tombstone's window (`earlyAcks`): the DM
    /// that lands after its own receipt is refused on arrival rather than carried to its expiry (knit-next ADR
    /// 2026-09.adpz).
    private var earlyReceipts: SeenSet

    /// Custody bookkeeping with knit-next's tombstone window unless told otherwise.
    public init(tombstoneMilliseconds: Int64 = Self.tombstoneMilliseconds) {
        tombstones = SeenSet(windowMilliseconds: tombstoneMilliseconds)
        earlyReceipts = SeenSet(windowMilliseconds: tombstoneMilliseconds)
    }

    /// The purged ids tombstoned now.
    public var tombstoneCount: Int { tombstones.count }

    /// The receipts remembered for a DM that may land after them, stale ones included until the set's capacity
    /// evicts them.
    public var earlyReceiptCount: Int { earlyReceipts.count }

    /// Takes a relayed frame into custody (`ForwardSync.onSeen`) if `authenticate` says so, and answers whether it
    /// was stored just now.
    ///
    /// Only custodial types are carried, never an id already held or tombstoned, nor a DM whose recipient's receipt
    /// came first. The store applies the TTL and the quotas, and refuses a frame that is dead on arrival or dated too
    /// far ahead. Times are on the wall clock.
    public mutating func carry(_ frame: CarriedFrame, in store: some CustodyStore, now: Int64, authenticate: () -> Bool) -> Bool {
        guard admits(frame, in: store, now: now), authenticate() else {
            return false
        }
        return store.store(frame, origin: .relayed, now: now)
    }

    /// Takes a frame of ours into custody (ORIGIN_SELF): trivially authentic, and under the same quotas as
    /// everyone's, so every node keeps the same newest frames.
    public mutating func carryOwn(_ frame: CarriedFrame, in store: some CustodyStore, now: Int64) -> Bool {
        guard admits(frame, in: store, now: now) else {
            return false
        }
        return store.store(frame, origin: .own, now: now)
    }

    /// What a neighbour's digest is answered with (`ForwardSync.onDigest`).
    public struct DigestReply: Sendable, Equatable {
        /// The senders whose key goes ahead of ``frames``, each as its signed profile from the pin store, point to
        /// point (knit-next ADR 2026-09.g64k).
        public var keysAhead: [NodeId]
        /// Every live frame the digest omits, profiles first.
        public var frames: [WireEnvelope]
    }

    /// Every live frame a neighbour's digest omits, each in a fresh ``WireEnvelope`` around its verbatim bytes,
    /// with a full hop budget, and the senders whose key goes ahead of them (`ForwardSync.onDigest`).
    ///
    /// A frame the peer authored is served too when its digest lacks it: that is how a node whose custody was
    /// wiped gets its own frames back. A group frame goes only to a member of its roster.
    ///
    /// Profiles go first (knit-next ADR 2026-09.9xuu). The store reads newest-received first, which put a sender's
    /// profile, usually the oldest frame held of theirs, behind all of their chat, so a peer meeting that sender
    /// for the first time dropped the backlog for want of the key it was about to be handed.
    ///
    /// When custody holds no profile, the pin store does (knit-next ADR 2026-09.g64k). The per-sender quota evicts
    /// a chatty sender's profile, and the TTL takes a departed sender's up to a republish period before their last
    /// posts, so a carrier often serves frames whose author's profile it no longer carries. ``DigestReply/keysAhead``
    /// names each sender of the frames served whose key the peer may lack: not the peer itself, with no live profile
    /// in our custody, and with none of our live frames of theirs in the peer's digest. A peer that custodies one of
    /// their frames verified it, so it holds the key; that rule keeps two carriers of one chatty sender from trading
    /// the key on every reconcile.
    public func missing(from theirIds: [String], for peer: NodeId, in store: some CustodyStore, now: Int64) -> DigestReply {
        let held = Set(theirIds.map(ExactKey.init))
        let peerKey = ExactKey(peer.string)
        let live = store.liveFrames(now: now)
        let keysFirst = live.filter { $0.envelope.type == .profile } + live.filter { $0.envelope.type != .profile }
        let outgoing = keysFirst.filter { frame in
            guard !held.contains(ExactKey(frame.envelope.id)) else {
                return false
            }
            guard let members = frame.envelope.group?.members else {
                return true
            }
            return members.contains { ExactKey($0) == peerKey }
        }
        // Senders whose key the peer holds or gets anyway: a live profile goes first or the peer has it, and a frame
        // the peer holds, it verified. Each keyless sender joins the set as it is named, so it is named once.
        let keyedFrames = live.filter { $0.envelope.type == .profile || held.contains(ExactKey($0.envelope.id)) }
        var keyed = Set(keyedFrames.map { ExactKey($0.envelope.senderId) })
        var keysAhead: [NodeId] = []
        for frame in outgoing {
            guard keyed.insert(ExactKey(frame.envelope.senderId)).inserted, let sender = NodeId(frame.envelope.senderId), sender != peer
            else {
                continue
            }
            keysAhead.append(sender)
        }
        return DigestReply(keysAhead: keysAhead, frames: outgoing.map(\.reserved))
    }

    /// Applies a verified receipt for `ackId` from `sender` (`ForwardSync.onAck`): the carried DM is purged, and its
    /// id tombstoned, only when `sender` is that DM's recipient, so a forged receipt cannot evict an undelivered
    /// message. A room or group frame names no recipient, so nothing purges it but its TTL. Answers whether
    /// anything was purged.
    ///
    /// Every receipt is remembered with its sender too, for a DM not held yet. Only the DM names its recipient, and
    /// the router marks the receipt seen, so without the memo a DM that lands after its receipt is carried to its
    /// expiry here while every neighbour that heard the two the other way round refuses it. Back-fill serves newest
    /// first, and a recipient sends its receipt at once but relays the DM after the jitter, so that order is common
    /// (knit-next ADR 2026-09.adpz, #100). A memo that never matches, for a room or group frame or from anyone but
    /// the recipient, costs one slot in a bounded set.
    @discardableResult
    public mutating func acknowledge(_ ackId: String, from sender: String, in store: some CustodyStore, now: Int64) -> Bool {
        _ = earlyReceipts.insert(Self.earlyReceiptKey(ackId, sender), now: now)
        guard let recipient = store.recipient(of: ackId), ExactKey(recipient) == ExactKey(sender) else {
            return false
        }
        store.remove(ackId)
        _ = tombstones.insert(ackId, now: now)
        return true
    }

    /// Whether `frame` may enter custody. A DM whose recipient's receipt came first is refused and tombstoned, as
    /// the purge it missed would have left it. The memo is keyed on the acker, so a receipt from anyone but the DM's
    /// own recipient keeps nothing out, the same guard ``acknowledge(_:from:in:now:)`` applies.
    ///
    /// knit-next asks a second time after the custody write, for a receipt handled on another dispatcher while the
    /// row was being written. The engine here is synchronous behind one actor (ADR 2026-09.gq84), so no receipt can
    /// land between this check and the write.
    private mutating func admits(_ frame: CarriedFrame, in store: some CustodyStore, now: Int64) -> Bool {
        let id = frame.envelope.id
        guard frame.envelope.type.isCustodial, !tombstones.contains(id, now: now), !store.contains(id) else {
            return false
        }
        if let recipient = frame.envelope.recipientId, earlyReceipts.contains(Self.earlyReceiptKey(id, recipient), now: now) {
            _ = tombstones.insert(id, now: now)
            return false
        }
        return true
    }

    /// The memo's key, `ackId|acker`, spelled as knit-next spells it (`ForwardSync.earlyAckKey`) so both platforms
    /// match the same pairs. The set compares it by its bytes (ADR 2026-09.jc2x).
    private static func earlyReceiptKey(_ ackId: String, _ acker: String) -> String {
        "\(ackId)|\(acker)"
    }

    /// Whether `ackId` was purged by its recipient within the window.
    public func isTombstoned(_ ackId: String, now: Int64) -> Bool {
        tombstones.contains(ackId, now: now)
    }
}
