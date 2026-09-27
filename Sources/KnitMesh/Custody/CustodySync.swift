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

    /// Custody bookkeeping with knit-next's tombstone window unless told otherwise.
    public init(tombstoneMilliseconds: Int64 = Self.tombstoneMilliseconds) {
        tombstones = SeenSet(windowMilliseconds: tombstoneMilliseconds)
    }

    /// The purged ids tombstoned now.
    public var tombstoneCount: Int { tombstones.count }

    /// Takes a relayed frame into custody (`ForwardSync.onSeen`) if `authenticate` says so, and answers whether it
    /// was stored just now.
    ///
    /// Only custodial types are carried, never an id already held or tombstoned. The store applies the TTL and the
    /// quotas, and refuses a frame that is dead on arrival or dated too far ahead. Times are on the wall clock.
    public func carry(_ frame: CarriedFrame, in store: some CustodyStore, now: Int64, authenticate: () -> Bool) -> Bool {
        guard admits(frame, in: store, now: now), authenticate() else {
            return false
        }
        return store.store(frame, origin: .relayed, now: now)
    }

    /// Takes a frame of ours into custody (ORIGIN_SELF): trivially authentic, and under the same quotas as
    /// everyone's, so every node keeps the same newest frames.
    public func carryOwn(_ frame: CarriedFrame, in store: some CustodyStore, now: Int64) -> Bool {
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
    @discardableResult
    public mutating func acknowledge(_ ackId: String, from sender: String, in store: some CustodyStore, now: Int64) -> Bool {
        guard let recipient = store.recipient(of: ackId), ExactKey(recipient) == ExactKey(sender) else {
            return false
        }
        store.remove(ackId)
        _ = tombstones.insert(ackId, now: now)
        return true
    }

    private func admits(_ frame: CarriedFrame, in store: some CustodyStore, now: Int64) -> Bool {
        let id = frame.envelope.id
        return frame.envelope.type.isCustodial && !tombstones.contains(id, now: now) && !store.contains(id)
    }

    /// Whether `ackId` was purged by its recipient within the window.
    public func isTombstoned(_ ackId: String, now: Int64) -> Bool {
        tombstones.contains(ackId, now: now)
    }
}
