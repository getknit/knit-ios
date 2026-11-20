public import KnitStore
public import KnitWire

/// The round cutter of a paced digest answer (the `custody-carry-policy` contract, §1 and §2): which frames a round serves,
/// in which tiers, and the keys that go ahead of them. ``CustodyAnswers`` keeps when each round is due.
extension CustodySync {
    /// One frame a round released, and whether it is addressed to the asking peer: a frame in the round's second tier is
    /// never pending in the peer's memo and never marked (the contract, §6).
    public struct Release: Sendable, Equatable {
        /// The frame's id.
        public var id: String
        /// Whether its recipient is the asking peer.
        public var addressed: Bool

        /// A release.
        public init(id: String, addressed: Bool) {
            self.id = id
            self.addressed = addressed
        }
    }

    /// What one round of a neighbour's digest answer sends (`ForwardSync.onDigest`).
    public struct DigestReply: Sendable, Equatable {
        /// The senders whose key goes ahead of ``frames``, in the order of ``keys``.
        public var keysAhead: [NodeId]
        /// Each of ``keysAhead``'s keys, its signed profile from the pin store in the point-to-point wrapper it is served
        /// in (knit-next ADR 2026-09.g64k). Every one goes out before every frame.
        public var keys: [WireEnvelope]
        /// The live frames the round serves, in the tiers' order.
        public var frames: [WireEnvelope]
        /// The ids of ``frames``, in their order, each marked when addressed to the peer.
        public var released: [Release]
        /// The bytes the round is charged: ``keys`` and ``frames``, each as encoded.
        public var bytes: Int
        /// Whether the round stopped at its budget with frames still to serve, which the answer's next round serves.
        public var isCapped: Bool
        /// The envelopes the round loaded, whose rosters the engine remembers (the contract, §1, "classify again at its own
        /// pace").
        public var loaded: [RelayEnvelope]
        /// The ids the round's index listed: what custody holds, to which the answer's sets are trimmed.
        public var live: Set<ExactKey> = []
        /// The senders the round's index listed, to which the answer's keys sent are trimmed.
        public var senders: Set<ExactKey> = []

        /// Bundles a reply.
        public init(
            keysAhead: [NodeId] = [], keys: [WireEnvelope] = [], frames: [WireEnvelope] = [], released: [Release] = [],
            bytes: Int = 0, isCapped: Bool = false, loaded: [RelayEnvelope] = []
        ) {
            self.keysAhead = keysAhead
            self.keys = keys
            self.frames = frames
            self.released = released
            self.bytes = bytes
            self.isCapped = isCapped
            self.loaded = loaded
        }
    }

    /// One round to a neighbour whose digest listed `theirIds`, cut as the first round of a fresh answer with no memo: what
    /// ``round(_:memo:in:now:at:crossed:key:)`` serves when nothing else is known.
    public func missing(
        from theirIds: [String],
        for peer: NodeId,
        in store: some CustodyStore,
        now: Int64,
        crossed: (String) -> Bool = { _ in false },
        key: (NodeId) -> WireEnvelope? = { _ in nil }
    ) -> DigestReply {
        let answer = CustodyAnswers.Answer(peer: peer, listed: Set(theirIds.map(ExactKey.init)), arrivedAt: 0, due: 0)
        return round(answer, memo: false, in: store, now: now, at: 0, crossed: crossed, key: key)
    }

    /// One round of `answer`, the digest answer to `peer` under way (the `custody-carry-policy` contract, §1 and §2): the
    /// live frames its latest digest lacks, less what the answer released, less what arrived from the peer since that
    /// digest, less, when `memo` (a proven link, §6), the ids the peer's memo withholds at `at` on the monotonic clock, and
    /// less every frame `crossed` says crossed this link either way inside its window (`LinkCrossings`). Each frame goes in a
    /// fresh ``WireEnvelope`` around its verbatim bytes, with a full hop budget, and the senders' keys go ahead of them.
    /// `now` is the wall clock the store reads.
    ///
    /// The round picks from ``CustodyStore/liveIndex(now:)``, which decodes nothing, in four tiers (§1):
    /// 1. profiles, newest received first (knit-next ADR 2026-09.9xuu), so a peer meeting a sender pins its key before the
    ///    backlog it is about to be handed;
    /// 2. frames addressed to the peer, by `(sentAt, id)`, never withheld by the memo: a recipient's own mail is never held
    ///    back on a memo's word;
    /// 3. group frames whose own remembered roster lists the peer (``CarryLedger/roster(of:)``), by `(sentAt, id)`, for any
    ///    group, ours or not: departed members do not count, and a row not classified orders in tier 4;
    /// 4. everything else, newest received first.
    ///
    /// Oldest first in tiers 2 and 3 because the key is frame-global, so every node and both platforms agree, a ratchet reads
    /// in sending order, and a group's seed (tier 2) lands before its posts (tier 3). No tier withholds a frame: a group frame
    /// goes to any peer that lacks it, member or not (knit-next ADR 2026-10.hr9f). It loads only the frames it sends.
    ///
    /// **The round stops; it never skips.** The first pick always goes, whatever its size, and the round stops at the
    /// first later pick that would pass ``roundBytes``, keys counted, so a large profile is never passed over for its
    /// sender's chat. A round with nothing to release sends nothing, a key included.
    ///
    /// When custody holds no profile, the pin store does (knit-next ADR 2026-09.g64k): `key` answers it, the signed profile
    /// in its point-to-point wrapper. ``DigestReply/keysAhead`` names each sender of the frames this round serves whose key
    /// the peer may lack: not the peer itself, with no live profile in our custody, with none of our live frames of theirs in
    /// the peer's digest, and not sent already in this answer, since the peer's digest never shows a key. A key is charged
    /// to the round ahead of the frame that needs it, and a key `crossed` says the link carried is neither sent nor charged.
    public func round(
        _ answer: CustodyAnswers.Answer,
        memo: Bool,
        in store: some CustodyStore,
        now: Int64,
        at monotonic: Int64,
        crossed: (String) -> Bool = { _ in false },
        key: (NodeId) -> WireEnvelope? = { _ in nil }
    ) -> DigestReply {
        let peer = answer.peer
        let index = store.liveIndex(now: now)
        // Senders whose key the peer holds or gets anyway: a live profile goes first or the peer has it, a frame the peer
        // holds it verified, and a key this answer sent. Each sender of a served frame joins the set as it is served.
        var reply = DigestReply()
        reply.live = Set(index.map { ExactKey($0.id) })
        reply.senders = Set(index.map { ExactKey($0.senderId) })
        let keyedEntries = index.filter { $0.type == .profile || answer.listed.contains(ExactKey($0.id)) }
        var keyed = Set(keyedEntries.map { ExactKey($0.senderId) }).union(answer.keysSent)
        for pick in picks(of: index, answer: answer, memo: memo, at: monotonic, crossed: crossed) {
            let entry = pick.entry
            let keyAhead =
                keyed.contains(ExactKey(entry.senderId)) ? nil : Self.keyAhead(of: entry.senderId, to: peer, crossed: crossed, key: key)
            let cost = entry.reservedBytes + (keyAhead?.wire.encoded.count ?? 0)
            if !reply.frames.isEmpty, reply.bytes + cost > Self.roundBytes {
                reply.isCapped = true
                break
            }
            guard let frame = store.frame(entry.id, now: now) else {
                continue
            }
            keyed.insert(ExactKey(entry.senderId))
            if let keyAhead {
                reply.keysAhead.append(keyAhead.sender)
                reply.keys.append(keyAhead.wire)
            }
            reply.frames.append(frame.reserved)
            reply.released.append(Release(id: entry.id, addressed: pick.addressed))
            reply.loaded.append(frame.envelope)
            reply.bytes += cost
        }
        return reply
    }

    /// Whether a round of `answer` cut now would release anything: the test behind `custodyAnswersCutShort`, kept here in one
    /// place. It reads the index alone and loads nothing, so a row whose bytes no longer decode counts as releasable.
    public func wouldRelease(
        _ answer: CustodyAnswers.Answer, memo: Bool, in store: some CustodyStore, now: Int64, at monotonic: Int64,
        crossed: (String) -> Bool = { _ in false }
    ) -> Bool {
        !picks(of: store.liveIndex(now: now), answer: answer, memo: memo, at: monotonic, crossed: crossed).isEmpty
    }

    /// One frame a round may serve, and whether it is addressed to the asking peer.
    private struct Pick {
        var entry: CustodyIndexEntry
        var addressed: Bool
    }

    /// The index entries a round of `answer` may serve, in the tiers' order (§1), each not skipped by the answer, the memo
    /// or the link's crossings.
    private func picks(
        of index: [CustodyIndexEntry], answer: CustodyAnswers.Answer, memo: Bool, at monotonic: Int64, crossed: (String) -> Bool
    ) -> [Pick] {
        let peer = answer.peer
        let asker = ExactKey(peer.string)
        var profiles: [Pick] = []
        var addressed: [CustodyIndexEntry] = []
        var grouped: [CustodyIndexEntry] = []
        var rest: [Pick] = []
        for entry in index {
            let id = ExactKey(entry.id)
            guard !answer.skips(id), !(entry.frameKey.map(crossed) ?? false) else {
                continue
            }
            let toPeer = entry.recipientId.map { ExactKey($0) == asker } ?? false
            if !toPeer, memo, ledger.withholds(id, from: peer, now: monotonic) {
                continue
            }
            if entry.type == .profile {
                profiles.append(Pick(entry: entry, addressed: toPeer))
            } else if toPeer {
                addressed.append(entry)
            } else if entry.groupId != nil, ledger.roster(of: id)?.contains(asker) == true {
                grouped.append(entry)
            } else {
                rest.append(Pick(entry: entry, addressed: false))
            }
        }
        let oldestFirst = { (lhs: CustodyIndexEntry, rhs: CustodyIndexEntry) -> Bool in
            lhs.sentAt != rhs.sentAt ? lhs.sentAt < rhs.sentAt : lhs.id.utf8.lexicographicallyPrecedes(rhs.id.utf8)
        }
        return profiles + addressed.sorted(by: oldestFirst).map { Pick(entry: $0, addressed: true) }
            + grouped.sorted(by: oldestFirst).map { Pick(entry: $0, addressed: false) } + rest
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
}
