import KnitCrypto
import KnitStore
import KnitWire

/// The group form received in the mesh, with the switch on (ADR 2026-10.5sk9, phase P6a2): `decryptAndDeliverGroup`,
/// `onGroupRatchetFailure` and `maybeRequestGroupKey` in knit-next's `InboundPipeline.kt` (at `cbf2a487`, `:1598-1730`),
/// and the custody replays of `MeshManager.kt` (`replayCustodiedGroupFrames` and `replayUndeliveredGroupCustody`,
/// `:1739-1770`).
///
/// A v2 frame addressed to a group opens through ``GroupRatchetSessions`` after its roster has been reconciled, in one
/// store unit together with what it carries: the message row, or a sealed group reaction (ctl 6), the one ctl the group
/// form applies. That unit is the outermost and fails closed, so nothing is announced, fetched or acknowledged before it
/// commits, and after a failure nothing is at all: the frame stays in custody, where the hourly replay opens it again.
///
/// Custody never reads group-ratchet state. A refusal and a failed unit change what we deliver, never what we carry, and
/// the replays read custody but never write it.
extension MeshEngine {
    /// A group-form frame from `sender` in the group `info` names (`decryptAndDeliverGroup`, `InboundPipeline.kt:1598-1663`),
    /// reconciled already, with no row yet. Malformed without its group header; our own frame, which custody serves back
    /// after a reinstall, opens nothing we hold and asks nobody; anything else opens in one unit with what it carries, and a
    /// refusal that means a missing seed feeds the key-request heuristic.
    func handleGroupRatchet(_ envelope: RelayEnvelope, _ enc: EncEnvelope, group info: GroupInfo, sender: NodeId, via hop: NodeId?) {
        // The group form's AAD names the group's id as its thread (`:1614`), the bytes the envelope carries.
        let aad = MessageCrypto.header(id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: info.id)
        // Group-only and header-required: anything else is malformed by construction (`:1607-1613`).
        guard let frame = GroupRatchetSessions.Frame(envelope: enc, aad: aad) else {
            drop(.groupRatchetBadHeader, envelope)
            return
        }
        // We hold send chains, never a receive chain of our own, so Kotlin's open finds no key and its request goes nowhere,
        // since we never pin ourselves (`:1702`). Dropped before the open here, under the reason Kotlin counts, and never
        // evidence for the heuristic.
        guard sender != nodeId else {
            drop(.groupRatchetNoKey, envelope)
            return
        }
        let now = clock.wallMilliseconds()
        let answer = groupRatchet.open(frame, in: info.id, from: sender, now: now) { opened -> RatchetArrival? in
            // Will not decode, or is newer than this build reads: dropped before the commit (`:1621-1629`), the chain
            // index unspent. The group form's plaintext is always the named layout.
            guard let content = RatchetInbound.content(of: opened.plaintext, v3: false) else {
                return nil
            }
            return groupArrival(of: content, envelope, from: sender)
        }
        switch answer {
        case .settled(.opened(_, let arrival)):
            finish(arrival, envelope, from: sender, via: hop)
        case .settled(.refused(let failure)):
            drop(GroupRatchetInbound.dropReason(for: failure), envelope)
            log.log(
                .info,
                "mesh group ratchet drop \(envelope.id) from \(envelope.senderId): \(failure) se=\(frame.header.se) n=\(frame.header.n)")
            if GroupRatchetInbound.asksForKey(failure) {
                requestGroupKeyIfDue(envelope, in: info.id, from: sender, now: now)
            }
        case .settled(.abandoned):
            drop(.cannotOpen, envelope)
        case .joined, .failed:
            // Nothing opens a unit around the inbound path, so a joined answer cannot happen here; were it to, its work could
            // not run before an outer commit this path never sees. The frame stays in custody for the hourly replay: custody
            // keeps a group frame's first bytes, which nobody seals twice.
            drop(.storeRefused, envelope)
            log.log(.warning, "mesh group frame \(envelope.id) from \(envelope.senderId) left for the replay: a store failed")
        }
    }

    /// What an opened group frame applies inside its unit (`decryptAndDeliverGroup`, `:1634-1662`): a message's row, or a
    /// sealed group reaction, last writer wins on the frame's signed `sentAt`, clamped. Every other ctl, group-key machinery
    /// that belongs on a pairwise DM or a code this build does not know, commits the chain's advance and nothing else. A
    /// reaction applies at every origin, unlike the DM form's at the start's replay: a group key is spent by its full key,
    /// and a chain is swept only after 48 hours unused, by when every frame it opened has left custody (a day past its
    /// stamp), so a frame whose reaction committed drops as `DUPLICATE` at every later open, and the one that applies is
    /// its first.
    private func groupArrival(of content: MessageContent, _ envelope: RelayEnvelope, from sender: NodeId) -> RatchetArrival {
        var arrival = RatchetArrival()
        guard let ctl = content.ctl else {
            arrival.message = storeDelivered(envelope, Self.delivered(content), sender: sender, recipient: nil)
            return arrival
        }
        if ctl == MessageContent.Control.reaction {
            (arrival.reacted, arrival.refusedReaction) = applySealedReaction(content.rp, from: sender, sentAt: envelope.sentAt)
        }
        return arrival
    }

    /// Asks `sender` for its seeds in `group` once the heuristic says so (`maybeRequestGroupKey`, `:1694-1730`): the
    /// facade's age gate and distinct-frame count, on the envelope's signed `sentAt` as it arrived; then the pinned peer
    /// with `CAP_RATCHET`, and a `CTL_GROUP_KEY_REQ` sealed through the DM ratchet, with the peer's prekey where no session
    /// is held, in a unit of its own; the floor is stamped once that unit commits. Outside any unit, as Kotlin runs it.
    private func requestGroupKeyIfDue(_ envelope: RelayEnvelope, in group: String, from sender: NodeId, now: Int64) {
        guard groupRatchet.noteUndecryptable(in: group, from: sender, frameId: envelope.id, sentAt: envelope.sentAt, now: now) else {
            return
        }
        let request = MessageContent(body: "", ctl: MessageContent.Control.groupKeyRequest, gk: GroupKeyPayload(groupId: group))
        let what = "key request for group \(group)"
        let sent = sendMachinery(request, to: sender, what: what) { GroupRatchetInbound.keyRequestPlan(to: stores.peers.peer(sender)) }
        guard let id = sent else {
            return
        }
        groupRatchet.markKeyRequested(in: group, from: sender, now: now)
        groupCounts.groupKeyRequestsSent += 1
        log.log(.info, "mesh sent \(sender) a \(what) as \(id)")
    }

    /// Delivers again the group frames our own custody holds with no row, oldest first, from senders other than us
    /// (`replayCustodiedGroupFrames`, `MeshManager.kt:1739-1764`): `group` and `sender` narrow it to one sender's frames in
    /// one group, the instant replay after that sender's seed landed, and `nil` takes every group frame, the start's and,
    /// with the switch on, the hourly net under the instant replays (`replayUndeliveredGroupCustody`, `:1766-1770`).
    ///
    /// A group frame that arrived before its seed is custodied by us, so our digest lists it and no neighbour serves it
    /// again: only this replay opens it once the seed lands. Each frame goes past the router, through the chat handler as it
    /// came but with no hop, since custody kept none, with its row read first in a unit of its own: one that exists is
    /// skipped, so it is not acknowledged again, and a read the store fails skips it until the next replay. It reads custody
    /// and writes nothing to it. A frame still keyless counts its refusal again, which is what feeds the key request.
    ///
    /// The start's and the hourly pass take our custodied `groupleave` and `groupupdate` frames from others too, in the same
    /// order as the chats (phase P7a), a deliberate difference from Kotlin, whose replay reads group chat alone: one whose
    /// unit failed stays in our custody and our digest, so nobody serves it to us again, and a departure lost that way would
    /// leave the leaver on our roster, seeded at our next mint. Neither has a row; each goes through its own handler as the
    /// start's replay (``handleGroupLeave(_:origin:)``, ``handleGroupUpdate(_:origin:)``), where one already applied
    /// changes nothing and opens no unit. A leave its sender's own newer frame in our custody, or newer row in the group's
    /// thread, outlives is not replayed (``isOutlived(_:by:under:)``). The instant replay stays chats only.
    func replayCustodiedGroupFrames(in group: String?, from sender: NodeId?) {
        let me = ExactKey(nodeId.string)
        let groupKey = group.map(ExactKey.init)
        let senderKey = sender.map { ExactKey($0.string) }
        let takesRosterFrames = group == nil && sender == nil
        let live = stores.custody.liveFrames(now: clock.wallMilliseconds()).reversed().filter { ExactKey($0.envelope.senderId) != me }
        let frames = live.filter { carried in
            let envelope = carried.envelope
            switch envelope.type {
            case .chat:
                guard let frameGroup = envelope.group else {
                    return false
                }
                let author = ExactKey(envelope.senderId)
                return (groupKey.map { $0 == ExactKey(frameGroup.id) } ?? true) && (senderKey.map { $0 == author } ?? true)
            case .groupLeave, .groupUpdate:
                return takesRosterFrames
            default:
                return false
            }
        }
        if group == nil {
            log.log(.debug, "mesh group custody replay: \(frames.count) frames")
        }
        let roster = GroupRoster(me: nodeId, maxClock: clampFuture(.max))
        for carried in frames {
            let envelope = carried.envelope
            switch envelope.type {
            case .groupLeave:
                if isOutlived(envelope, by: live.lazy.map(\.envelope), under: roster) {
                    log.log(.debug, "mesh replayed leave \(envelope.id) from \(envelope.senderId) is outlived by a newer act of theirs")
                    continue
                }
                handleGroupLeave(envelope, origin: .startReplay)
            case .groupUpdate:
                handleGroupUpdate(envelope, origin: .startReplay)
            default:
                replayUnread(carried)
            }
        }
    }

    /// Whether the replayed leave `envelope` is outlived by its sender's own later act, its stamp bounded as
    /// ``handleGroupLeave(_:origin:)`` bounds it: a newer roster-carrying frame of theirs among `frames`, our custody
    /// (``GroupRoster/outlives(_:leftAt:in:by:)``), or a row of theirs in the group's thread newer than the leave
    /// (``GroupRoster/actedAfter(_:leftAt:among:)``). The row is the durable half: custody trims a busy group's bucket
    /// oldest first, and a leave, whose envelope names no group, sits in no group bucket, so the frame that outlives it
    /// can leave our custody before it does (the crypto review of P7a).
    ///
    /// Asked only of a leave that would depart someone (``GroupRoster/depart(_:at:from:)`` answers a departure): a group
    /// we hold and have not left, its sender not blocked and an active member, and the leave newer than their rejoin.
    /// Anything else changes nothing in ``handleGroupLeave(_:origin:)``, so no scan runs for it, and a self-signed leave
    /// for a group that does not exist costs one row read (the blobs review of P7a). A thread the store cannot read holds the
    /// leave back, as if outlived, until the next replay.
    private func isOutlived(_ envelope: RelayEnvelope, by frames: some Sequence<RelayEnvelope>, under roster: GroupRoster) -> Bool {
        guard let leave = try? GroupLeaveContent(decoding: envelope.payload), let leaver = NodeId(envelope.senderId),
            !isBlocked(leaver), let group = stores.groups.group(leave.groupId)
        else {
            return false
        }
        let leftAt = clampFuture(envelope.sentAt)
        guard GroupRoster.depart(leaver, at: leftAt, from: group) != nil else {
            return false
        }
        if roster.outlives(leaver, leftAt: leftAt, in: group.id, by: frames) {
            return true
        }
        // The thread in a unit of its own, as ``replayUnread(_:)`` reads a row: a read the store fails answers no rows, which
        // would depart a member who acted after the leave, so it holds the leave back until a replay that can read (both
        // reviews of P7a's fixes).
        let thread = stores.transactor.atomically { () -> [MessageRecord]? in stores.messages.messages(in: group.id) }
        guard case .committed(let rows) = thread else {
            log.log(.warning, "mesh replayed leave \(envelope.id) from \(envelope.senderId) held back: a store failed")
            return true
        }
        return roster.actedAfter(leaver, leftAt: leftAt, among: rows)
    }

    /// Opens `carried`, a frame from our own custody, again unless its row exists, read in a store unit of its own first: a
    /// read the store fails skips it, so a frame delivered before is never acknowledged again on the store's fallback. Past
    /// the router, with no hop, as the start's replay is (``RatchetInbound/Origin/startReplay``).
    func replayUnread(_ carried: CarriedFrame) {
        let envelope = carried.envelope
        // The body answers the frame to open, or none once its row exists, never `nil`, which would abandon the unit.
        let unread = stores.transactor.atomically { () -> CarriedFrame?? in .some(stores.messages.contains(envelope.id) ? nil : carried) }
        switch unread {
        case .committed(let frame?):
            handleChat(frame.envelope, via: nil, signed: !frame.sig.isEmpty, origin: .startReplay)
        case .committed(nil):
            return
        case .joined, .abandoned, .failed:
            log.log(.warning, "mesh custody replay of \(envelope.id) skipped: a store failed")
        }
    }
}
