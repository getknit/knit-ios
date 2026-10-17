import KnitStore
import KnitWire

/// What a DM ratchet frame that opened applies, inside its open's store unit, and the work it leaves for after the
/// commit (ADR 2026-10.5sk9, phase P5a): `handleCtlDm`, `applyCtlInTxn`, `applySealedReceipt`, `applySealedReaction`,
/// `applySealedProfile` and `persistWithInlineAcks` in knit-next's `InboundPipeline.kt` (at `cbf2a487`, `:1088-1235` and
/// `:1353-1438`).
///
/// A ctl is machinery: never a row, a notification or an acknowledgement. Inside the unit everything here reads and writes
/// stores and nothing else; the events, the drop counts, the photo's fetch and the acknowledgement wait in a
/// ``RatchetArrival`` until the unit commits.
extension MeshEngine {
    /// Applies what `content`, opened from `sender`'s `envelope`, carries, inside its open's unit, and answers the work
    /// for after the commit (`handleCtlDm`, `InboundPipeline.kt:1128-1195`, and `applyCtlInTxn`, `:1197-1235`):
    /// - a plain DM: its row, and the acks it carries inline (`CAP_INLINE_ACK`, `persistWithInlineAcks`, `:1088-1116`);
    /// - a receipt (5): our ticks flipped;
    /// - a reaction (6): applied last writer wins, at its first verdict;
    /// - a profile (8): its presentation, never its prekey, at its first verdict;
    /// - a reset (1): nothing beyond the open, whose own delta adopted it; at its first verdict, once the unit commits, our
    ///   unacked DMs to the sender are sealed again (phase P5b, ``resealRecentDirectMessages(to:)``) and our group seeds
    ///   go to it again, forced past its outbox's ack (phase P6b, ``flushPendingGroupKeys(for:force:)``);
    /// - a group key (2): its seeds adopted into the group form's store, joined to this unit, when the roster admits the
    ///   sender (phase P6a2, ``adoptGroupSeeds(_:from:)``), the ack and the custody replay after the commit;
    /// - a group key's ack (4): the seed outbox's row moved (``recordSeedAck(_:from:)``);
    /// - a key request (3): nothing beyond the chain's advance; at its first verdict, once the unit commits, our current
    ///   seeds go to the requester, floored (phase P6b, ``redistributeGroupKey(in:to:)``, `:1163-1165`);
    /// - every code this build does not know: nothing beyond the chain's advance, which still commits (`:1191-1196`).
    ///
    /// A group key and its ack apply at every origin, the start's replay included: an adoption goes by the sender's own
    /// `(epoch, mintedAt)` against the newest mint held, never a stamp of ours, so a seed opened again is acknowledged
    /// again with no chain moved, and an ack only ever raises the outbox's epoch.
    ///
    /// The start's replay (`origin`) applies no reaction and no profile, and commits only the chain's advance for them.
    /// Both are ordered by a stamp clamped to our clock at the first open (``clampFuture(_:)``), which a later open cannot
    /// reproduce: a reaction or presentation first opened from a peer running more than five minutes fast would apply
    /// again higher and outrank a newer one. Only one whose first verdict never committed is lost that way, as it is in
    /// Kotlin, which re-opens nothing from its own custody. Nor does it re-seal for a reset: that reset's first verdict,
    /// if it had one, came before the restart and re-sealed then, and the replay meets it again for a day.
    func arrival(
        of content: MessageContent, _ envelope: RelayEnvelope, from sender: NodeId, origin: RatchetInbound.Origin
    ) -> RatchetArrival {
        var arrival = RatchetArrival()
        guard let ctl = content.ctl else {
            arrival.message = storeDelivered(envelope, Self.delivered(content), sender: sender, recipient: nodeId)
            arrival.delivered = applySealedReceipts(RatchetInbound.acknowledged(ack: nil, acks: content.acks), from: sender)
            return arrival
        }
        switch ctl {
        case MessageContent.Control.receipt:
            arrival.delivered = applySealedReceipts(RatchetInbound.acknowledged(ack: content.ack, acks: content.acks), from: sender)
        case MessageContent.Control.reaction where origin == .firstVerdict:
            (arrival.reacted, arrival.refusedReaction) = applySealedReaction(content.rp, from: sender, sentAt: envelope.sentAt)
        case MessageContent.Control.profile where origin == .firstVerdict:
            arrival.presentation = applySealedPresentation(content.pr, from: sender)
        case MessageContent.Control.groupKey:
            arrival.seeds = adoptGroupSeeds(content.gk, from: sender)
        case MessageContent.Control.groupKeyAck:
            recordSeedAck(content.gk, from: sender)
        case MessageContent.Control.groupKeyRequest where origin == .firstVerdict:
            // Answered after the commit, never from the start's replay, whose request was answered before the restart.
            arrival.keyRequest = content.gk?.groupId
        case MessageContent.Control.sessionReset where origin == .firstVerdict:
            // However its open went: a root adopted, a race won or lost, or a marker under the session held
            // (`InboundPipeline.kt:1137-1148`). The re-seal is a send, so it waits for the commit.
            arrival.resealsUnacked = true
        default:
            break
        }
        return arrival
    }

    /// The work an opened frame left, once its unit has committed: the ticks it flipped and the reaction it applied are
    /// announced, a refused reaction counted, a moved profile's photo fetched or let go, a message delivered as
    /// ``deliverChat(_:_:sender:recipient:via:)``'s second half delivers one, its acknowledgement included, a reset's
    /// first verdict answered with our unacked DMs sealed again and our group seeds sent again (`handleCtlDm`'s follow-up,
    /// `InboundPipeline.kt:1140-1148`), a key request answered (`:1163-1165`), and a seed worth acknowledging acknowledged,
    /// then the sender's frames in that group our custody holds opened again (`:1150-1156`). The group facade's floor moved
    /// before this ran (``settleSeeds(_:)``).
    func finish(_ arrival: RatchetArrival, _ envelope: RelayEnvelope, from sender: NodeId, via hop: NodeId?) {
        for id in arrival.delivered {
            events.append(.delivered(messageId: id))
        }
        if let reacted = arrival.reacted {
            events.append(.reacted(reacted))
        }
        if arrival.refusedReaction {
            drop(.reactionRefused, envelope)
        }
        if let presentation = arrival.presentation {
            followPresentation(presentation, of: sender)
        }
        if let message = arrival.message {
            announce(message, envelope, sender: sender, via: hop)
        }
        if arrival.resealsUnacked {
            resealRecentDirectMessages(to: sender)
            // A ctl is never a row, so the re-seal cannot bring back a seed the wiped peer lost: forced, since its outbox
            // row's ack predates the wipe (`InboundPipeline.kt:1144-1148`).
            flushPendingGroupKeys(for: sender, force: true)
        }
        if let group = arrival.keyRequest {
            redistributeGroupKey(in: group, to: sender)
        }
        if let seeds = arrival.seeds, let epoch = seeds.ackEpoch {
            acknowledgeSeeds(epoch, in: seeds.group, to: sender)
            // The seed, or its re-distribution, may open frames we already carry, which nobody serves us again.
            replayCustodiedGroupFrames(in: seeds.group, from: sender)
        }
    }

    /// Sealed receipts, inside the unit (`applySealedReceipt`, `InboundPipeline.kt:1408-1418`): each id flips our tick
    /// only under the forged-ack guard (``isOurs(_:acknowledgedBy:)``), and the ids whose tick moved are answered. A sealed
    /// receipt purges nothing, here or anywhere: a carrier cannot read it, so the delivered DM leaves every custody, ours
    /// included, on its TTL (ADR 2026-09.p6nb, amended).
    private func applySealedReceipts(_ ids: [String], from sender: NodeId) -> [String] {
        ids.filter { isOurs($0, acknowledgedBy: sender.string) && stores.messages.markDelivered($0) }
    }

    /// A sealed reaction in DM form, inside the unit (`applySealedReaction`, `InboundPipeline.kt:1426-1438`): applied last
    /// writer wins on the frame's signed `sentAt`, clamped, with the authenticated sender as the reactor, under the rule
    /// the cleartext frame meets here, one emoji of at most 32 UTF-16 units (ADR 2026-10.ehe6), which the chain's advance
    /// never waits on. Answers the reaction to announce, for a held message, and whether it was refused.
    func applySealedReaction(_ payload: ReactionContent?, from sender: NodeId, sentAt: Int64) -> (ReactionRecord?, Bool) {
        guard let payload else {
            return (nil, false)
        }
        if let emoji = payload.emoji, !TextLimits.isAcceptedReaction(emoji) {
            return (nil, true)
        }
        let reaction = ReactionRecord(messageId: payload.messageId, reactor: sender, emoji: payload.emoji, updatedAt: clampFuture(sentAt))
        guard stores.messages.applyReaction(reaction), stores.messages.message(payload.messageId)?.kind == .message else {
            return (nil, false)
        }
        return (reaction, false)
    }

    /// A sealed profile, inside the unit (`applySealedProfile`, `InboundPipeline.kt:1353-1396`): the presentation alone,
    /// on the presentation's watermark, the sender's own `version` clamped, which a re-served stale one cannot undo. It
    /// never touches the pinned key, the prekey, the device tag or the capabilities, which move only on the cleartext
    /// profile, the one that certifies itself, and it never makes a row for a sender nobody pinned. An unversioned one
    /// cannot be ordered, so it is ignored. Answers the row before and after, when it moved.
    private func applySealedPresentation(_ payload: ProfilePayload?, from sender: NodeId) -> RatchetArrival.Presentation? {
        guard let payload, let existing = stores.peers.peer(sender) else {
            return nil
        }
        let version = clampFuture(payload.version)
        guard version > 0, version >= existing.updatedAt else {
            return nil
        }
        var record = existing
        // Our own limits bound what we send, not what a peer does.
        record.name = TextLimits.truncated(payload.name, toUTF16: TextLimits.displayName)
        record.status = TextLimits.truncated(payload.status, toUTF16: TextLimits.status)
        record.openToChat = payload.openToChat
        (record.advertisedAvatarHash, record.avatarHash) = photo(advertised: payload.avatarHash, over: existing)
        record.updatedAt = version
        guard record != existing else {
            return nil
        }
        stores.peers.upsert(record)
        return RatchetArrival.Presentation(before: existing, after: record)
    }

    /// The photo a sealed profile leaves its sender with, by the rule a cleartext one meets (`photoFrom`, and
    /// `resolveAvatarHash`, `InboundPipeline.kt:3416-3425`): the hash it advertises, and the photo shown, which follows it
    /// once its bytes are held and otherwise stays. None clears both, and a hash that is not one leaves the shown photo.
    private func photo(advertised text: String?, over existing: PeerRecord) -> (advertised: BlobHash?, shown: BlobHash?) {
        guard let text else {
            return (nil, nil)
        }
        guard let hash = BlobHash(text) else {
            return (nil, existing.avatarHash)
        }
        return (hash, stores.blobs.contains(hash) ? hash : existing.avatarHash)
    }

    /// After the commit, what a moved presentation earns, as a cleartext profile's does (``handleProfile(_:_:)``): the
    /// peer is announced, a photo it advertises and we lack is asked of someone other than a linked sender, who pushes its
    /// own, and the photo it replaced is let go.
    private func followPresentation(_ presentation: RatchetArrival.Presentation, of sender: NodeId) {
        events.append(.peerUpdated(sender))
        let after = presentation.after
        if let advertised = after.advertisedAvatarHash, after.avatarHash != advertised, !transport.isLinked(sender) {
            wantBlob(advertised, author: sender, via: nil, asker: nil)
        }
        if let replaced = presentation.before.avatarHash, replaced != after.avatarHash {
            releaseBlob(replaced)
        }
    }
}

/// What a DM ratchet frame that opened leaves for after its unit commits: everything the engine does that is not a store
/// write, gathered inside the unit, where nothing may happen yet.
internal struct RatchetArrival {
    /// A sealed profile's presentation, the row before and after.
    struct Presentation {
        /// The row before.
        let before: PeerRecord
        /// The row after.
        let after: PeerRecord
    }

    /// The message it was, stored: announced and acknowledged after the commit. `nil` for a ctl.
    var message: StoredDelivery?
    /// Our messages whose tick a receipt, or the message's inline acks, flipped.
    var delivered: [String] = []
    /// A reaction applied to a message we hold, to announce.
    var reacted: ReactionRecord?
    /// Whether a reaction was refused, to count.
    var refusedReaction = false
    /// The presentation a sealed profile moved.
    var presentation: Presentation?
    /// Whether it was a reset's first verdict, which has us seal our unacked DMs to its sender again and send it our
    /// group seeds again.
    var resealsUnacked = false
    /// The group a key request's first verdict asks our seeds for, answered once the unit commits (phase P6b).
    var keyRequest: String?
    /// The seeds a group key adopted, joined to the unit, whose floor settles and whose ack goes once it commits.
    var seeds: SeedAdoption?
}

/// What one `CTL_GROUP_KEY` adopted inside its DM's unit (phase P6a2), for after that unit commits.
internal struct SeedAdoption {
    /// The group its seeds are for, as the payload names it.
    let group: String
    /// The highest epoch worth acknowledging, or `nil` for none: a seed refused as stale or past the floor earns no ack.
    let ackEpoch: Int?
    /// How many chains were freshly adopted, to count.
    let freshChains: Int
    /// The group facade's floor, moved once the unit commits.
    let settlement: GroupRatchetSessions.Settlement
}
