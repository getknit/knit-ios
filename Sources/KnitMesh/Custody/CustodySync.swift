public import KnitStore
public import KnitWire

/// Store-and-forward over a link (`ForwardSync.kt`): which frames this node takes into custody, what it serves a
/// neighbour whose digest lists what it holds, and what a receipt purges.
///
/// The link-up and 60-second digest exchange is the whole protocol. Each side sends the ids of every live frame
/// it carries; on receiving the other's, it serves the live frames the list omits, a capped round at a time here
/// (``missing(from:for:in:now:crossed:key:)``, ADR 2026-10.f5zs). Android serves custody only in answer to a digest,
/// so a node that never sends one never gets back-filled (`.agents/context/custody.md`).
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

    /// Where a refused oversize or group frame is noted, at `.debug`: the engine's log, or none.
    private let log: (any KnitLog)?

    /// Custody bookkeeping with knit-next's tombstone window unless told otherwise, noting oversize and group frames custody
    /// refuses to `log`.
    public init(tombstoneMilliseconds: Int64 = Self.tombstoneMilliseconds, log: (any KnitLog)? = nil) {
        tombstones = SeenSet(windowMilliseconds: tombstoneMilliseconds)
        earlyReceipts = SeenSet(windowMilliseconds: tombstoneMilliseconds)
        self.log = log
    }

    /// The purged ids tombstoned now.
    public var tombstoneCount: Int { tombstones.count }

    /// The receipts remembered for a DM that may land after them, stale ones included until the set's capacity
    /// evicts them.
    public var earlyReceiptCount: Int { earlyReceipts.count }

    /// Group frames custody refused because their roster is not their own (``CustodyRefusal/foreignRoster``, knit-next
    /// ADR 2026-10.7mqm), Android's `groupCustodyRefused`. Not a drop: each was still delivered and relayed.
    public private(set) var groupRefusedCount = 0

    /// Frames custody refused because their `signed` is longer than its byte cap (``CustodyRefusal/oversize``,
    /// knit-next ADR 2026-10.mqzv), Android's `custodyOversizeRefused` (`MeshMetrics.kt` at `f172d7c64`). Not a drop:
    /// each was still delivered and relayed. Our own count too, since the cap binds them.
    public private(set) var oversizeRefusedCount = 0

    /// Takes a relayed frame into custody (`ForwardSync.onSeen`) if `authenticate` says so, and answers whether custody
    /// changed, which is what re-reads the advert's digest cue.
    ///
    /// Only custodial types are carried, never an id already held or tombstoned, nor a DM whose recipient's receipt
    /// came first. The store applies the byte cap, the TTL and the quotas, and refuses a frame whose `signed` is over
    /// the cap, one that is dead on arrival or dated too far ahead, or a group frame whose roster is not its own. A refusal
    /// stops nothing but custody: the caller delivers and relays without reading the answer. Times are on the wall clock.
    ///
    /// "Changed" is not "held": a frame its own write evicted changed custody and is not held (``CustodyStoreResult``).
    /// Nothing here pulls a carried frame's photo (ADR 2026-10.ym9y), so nothing reads ``CustodyStoreResult/held`` yet.
    public mutating func carry(_ frame: CarriedFrame, in store: some CustodyStore, now: Int64, authenticate: () -> Bool) -> Bool {
        guard admits(frame, in: store, now: now), authenticate() else {
            return false
        }
        return noted(store.store(frame, origin: .relayed, now: now), for: frame)
    }

    /// Takes a frame of ours into custody (ORIGIN_SELF): trivially authentic, and under the same quotas, the same byte cap
    /// and the same group gate as everyone's, so every node keeps the same newest frames. Answers whether custody changed,
    /// as ``carry(_:in:now:authenticate:)`` does. A refusal is the rules' answer before any write, never a thrown error, so
    /// the ratchet's store units that read it only to re-read the digest cue go on; the send itself still goes.
    public mutating func carryOwn(_ frame: CarriedFrame, in store: some CustodyStore, now: Int64) -> Bool {
        guard admits(frame, in: store, now: now) else {
            return false
        }
        return noted(store.store(frame, origin: .own, now: now), for: frame)
    }

    /// Counts and logs an oversize or a roster refusal (`ForwardRepository.store`'s, in Android's words), and answers whether
    /// custody changed. No other refusal is counted here: the dead and the future-dated are the clock's, and a failed write
    /// is the database's, which reports it. An oversize frame is counted as that alone, whatever its roster, as Android's
    /// cap comes first. The line names the id, the type and the length, never the payload.
    private mutating func noted(_ result: CustodyStoreResult, for frame: CarriedFrame) -> Bool {
        let envelope = frame.envelope
        switch result.refusal {
        case .oversize:
            oversizeRefusedCount += 1
            log?.log(
                .debug,
                "custody refused \(envelope.id.prefix(Self.idCharacters)) (\(envelope.type.rawValue)): "
                    + "\(frame.signed.count) signed bytes over the cap"
            )
        case .foreignRoster:
            groupRefusedCount += 1
            // Only a group frame is refused for its roster (`CustodyRules.admission`), so both stores' refusals name one.
            if let group = envelope.group {
                log?.log(
                    .debug,
                    "custody refused \(envelope.id.prefix(Self.idCharacters)) from \(envelope.senderId.prefix(Self.idCharacters)): "
                        + "roster of \(group.id) is not its own"
                )
            }
        case .deadOnArrival, .aheadOfWindow, .writeFailed, nil:
            break
        }
        return result.changed
    }

    /// How much of a frame or node id the log line names (`ID_CHARS`): enough to find it in a dump.
    private static let idCharacters = 8

    /// The most frames one reply round serves (ADR 2026-10.f5zs). Android serves every frame a digest omits at once
    /// (`ForwardSync.kt:136-163` at knit-next `e63f15f4`), so an empty digest of 15 bytes bought the whole custody; the
    /// cap is this port's rule alone, and no custody constant moves with it. Each 60 s digest answers the next slice.
    public static let roundFrames = 200

    /// The most bytes one reply round serves, keys ahead included, each counted as its encoded ``WireEnvelope``, as
    /// `LinkManager.send` writes it. The first pick always goes, so a round can pass it by that one frame.
    public static let roundBytes = 262_144 // 256 KiB

    /// What a neighbour's digest is answered with (`ForwardSync.onDigest`).
    public struct DigestReply: Sendable, Equatable {
        /// The senders whose key goes ahead of ``frames``, in the order of ``keys``.
        public var keysAhead: [NodeId]
        /// Each of ``keysAhead``'s keys, its signed profile from the pin store in the point-to-point wrapper it is served
        /// in (knit-next ADR 2026-09.g64k). Every one goes out before every frame.
        public var keys: [WireEnvelope]
        /// The live frames the digest omits that this round serves, profiles first.
        public var frames: [WireEnvelope]
        /// The bytes the round is charged: ``keys`` and ``frames``, each as encoded.
        public var bytes: Int
        /// Whether the round stopped at its budget with frames still to serve, which the next digest answers.
        public var isCapped: Bool

        /// Bundles a reply.
        public init(
            keysAhead: [NodeId] = [], keys: [WireEnvelope] = [], frames: [WireEnvelope] = [], bytes: Int = 0, isCapped: Bool = false
        ) {
            self.keysAhead = keysAhead
            self.keys = keys
            self.frames = frames
            self.bytes = bytes
            self.isCapped = isCapped
        }
    }

    /// One reply round to a neighbour's digest (`ForwardSync.onDigest`): the live frames it omits, at most
    /// ``roundFrames`` of them and ``roundBytes`` with the keys ahead, each in a fresh ``WireEnvelope`` around its
    /// verbatim bytes, with a full hop budget, and the senders' keys that go ahead of them.
    ///
    /// The round picks from ``CustodyStore/liveIndex(now:)``, which decodes nothing: profiles first, then newest received
    /// first, minus the digest's ids (by their bytes, ADR 2026-09.jc2x) and minus every frame `crossed` says crossed this
    /// link either way inside its window (`LinkCrossings`). It loads only the frames it serves, and each group frame to
    /// read its roster: one whose roster lacks the peer takes no slot and no bytes, and nothing caps those loads, so
    /// busy groups the peer is not in cannot starve the older frames it is owed. The digest meter bounds their cost
    /// (ADR 2026-10.f5zs). A frame the round served and the peer did not keep is skipped while its crossing lasts, so a
    /// peer that refuses a slice gets the next one at its next digest rather than the same slice again.
    ///
    /// **The round stops; it never skips.** The first pick always goes, whatever its size, and the round stops at the
    /// first later pick that would pass the budget, so a large profile is never passed over for its sender's chat.
    ///
    /// A frame the peer authored is served too when its digest lacks it: that is how a node whose custody was
    /// wiped gets its own frames back. A group frame goes only to a member of its roster.
    ///
    /// Profiles go first (knit-next ADR 2026-09.9xuu). The store reads newest-received first, which put a sender's
    /// profile, usually the oldest frame held of theirs, behind all of their chat, so a peer meeting that sender
    /// for the first time dropped the backlog for want of the key it was about to be handed.
    ///
    /// When custody holds no profile, the pin store does (knit-next ADR 2026-09.g64k): `key` answers it, the signed
    /// profile in its point-to-point wrapper. The per-sender quota evicts a chatty sender's profile, and the TTL takes a
    /// departed sender's up to a republish period before their last posts, so a carrier often serves frames whose author's
    /// profile it no longer carries. ``DigestReply/keysAhead`` names each sender of the frames this round serves whose key
    /// the peer may lack: not the peer itself, with no live profile in our custody, and with none of our live frames of
    /// theirs in the peer's digest. A peer that custodies one of their frames verified it, so it holds the key; that rule
    /// keeps two carriers of one chatty sender from trading the key on every reconcile. A key is charged to the round
    /// ahead of the frame that needs it, and a key `crossed` says the link carried is neither sent nor charged.
    public func missing(
        from theirIds: [String],
        for peer: NodeId,
        in store: some CustodyStore,
        now: Int64,
        crossed: (String) -> Bool = { _ in false },
        key: (NodeId) -> WireEnvelope? = { _ in nil }
    ) -> DigestReply {
        let held = Set(theirIds.map(ExactKey.init))
        let peerKey = ExactKey(peer.string)
        let index = store.liveIndex(now: now)
        // Senders whose key the peer holds or gets anyway: a live profile goes first or the peer has it, and a frame
        // the peer holds, it verified. Each sender of a served frame joins the set as it is served, so it is named once.
        let keyedEntries = index.filter { $0.type == .profile || held.contains(ExactKey($0.id)) }
        var keyed = Set(keyedEntries.map { ExactKey($0.senderId) })
        let picks = index.filter { $0.type == .profile } + index.filter { $0.type != .profile }
        var reply = DigestReply()
        for entry in picks {
            guard !held.contains(ExactKey(entry.id)), !(entry.frameKey.map(crossed) ?? false) else {
                continue
            }
            var loaded: CarriedFrame?
            if entry.groupId != nil {
                guard let frame = store.frame(entry.id, now: now), let members = frame.envelope.group?.members,
                    members.contains(where: { ExactKey($0) == peerKey })
                else {
                    continue
                }
                loaded = frame
            }
            let keyAhead =
                keyed.contains(ExactKey(entry.senderId)) ? nil : Self.keyAhead(of: entry.senderId, to: peer, crossed: crossed, key: key)
            let cost = entry.reservedBytes + (keyAhead?.wire.encoded.count ?? 0)
            if !reply.frames.isEmpty, reply.frames.count >= Self.roundFrames || reply.bytes + cost > Self.roundBytes {
                reply.isCapped = true
                break
            }
            guard let frame = loaded ?? store.frame(entry.id, now: now) else {
                continue
            }
            keyed.insert(ExactKey(entry.senderId))
            if let keyAhead {
                reply.keysAhead.append(keyAhead.sender)
                reply.keys.append(keyAhead.wire)
            }
            reply.frames.append(frame.reserved)
            reply.bytes += cost
        }
        return reply
    }

    /// The key that goes ahead of a frame from `senderId` to `peer`, if one goes: never the peer's own, none for a sender
    /// that is no node id, nor one the pin store lacks, and none the link already carried either way.
    private static func keyAhead(
        of senderId: String, to peer: NodeId, crossed: (String) -> Bool, key: (NodeId) -> WireEnvelope?
    ) -> (sender: NodeId, wire: WireEnvelope)? {
        guard let sender = NodeId(senderId), sender != peer, let wire = key(sender) else {
            return nil
        }
        if let frameKey = FrameKey.ofSigned(wire), crossed(frameKey) {
            return nil
        }
        return (sender, wire)
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
