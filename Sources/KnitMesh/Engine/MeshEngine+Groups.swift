import KnitCrypto
public import KnitStore
public import KnitWire

/// Groups, sealed with v1 (ADR 2026-09.n393): one frame per message, its body key wrapped to each member, with the
/// roster in the clear beside it so every member can rebuild the group from any frame.
extension MeshEngine {
    // MARK: What we do

    /// Makes a group of `others` and us (`ContactsViewModel.createGroup`, `ContactsViewModel.kt:88-123`), or opens the
    /// one those people already share. Nothing is sent: the others learn of the group from its first message, which
    /// carries the roster. A group we left starts again as a fresh row, and the others take us back when our next
    /// frame lists us (`rejoinBy`).
    ///
    /// Answers `nil` for fewer than one other person or more than seven: the roster cap is eight, us included.
    @discardableResult
    public func createGroup(with others: [NodeId]) -> GroupRecord? {
        var seen = Set<NodeId>([nodeId])
        let people = others.filter { seen.insert($0).inserted }
        guard !people.isEmpty, people.count < GroupInfo.maxMembers else {
            return nil
        }
        // The roster in pick order, then us, as Android stores it.
        let members = (people + [nodeId]).map(\.string)
        let id = GroupId.derive(members)
        if let held = stores.groups.group(id), !held.hasLeft {
            return held
        }
        let now = clock.wallMilliseconds()
        let group = GroupRecord(id: id, createdBy: nodeId.string, createdAt: now, roster: members.map { GroupMember(nodeId: $0) })
        stores.groups.save(group)
        stores.messages.save(StatusNotices.groupCreated(id, by: nodeId, at: now))
        events.append(.groupChanged(id))
        return group
    }

    /// Sends `text` to group `groupId`, with `photo` sealed beside it if one is given, and `replyTo` and `mentions` sealed
    /// inside it (`MeshManager.sendChat`): sealed to each current member whose key is pinned, with the group's roster
    /// beside it. Only the mentions whose token the sent body holds go (``MessageMention/carried(_:in:)``, ADR
    /// 2026-10.nbhj). Members without a key are skipped, as on Android, and their keys are asked for. When nobody's key
    /// is pinned the message waits as `pendingKey`, mentions and all, and goes out once one pins, which Android never
    /// does. Answers the stored message, or `nil` for a blank message with no photo, a photo too heavy to send, a group
    /// we are not in, or one nobody else is left in.
    ///
    /// With the ratchet's switch on, it is stored waiting first and sealed in a send unit of its own, which clears the wait
    /// as it commits: in the group form when every other member can read it, else v1 as above (``sendGroupRatchet(_:in:)``,
    /// ADR 2026-10.5sk9, phase P6b).
    @discardableResult
    public func sendGroupMessage(
        _ text: String, to groupId: String, photo: OutgoingPhoto? = nil, replyTo: MessageReply? = nil,
        mentions: [MessageMention] = []
    ) -> MessageRecord? {
        let sentAt = clock.wallMilliseconds()
        guard let group = stores.groups.group(groupId), !group.hasLeft, hasOthers(group), let body = Self.messageBody(text, photo: photo),
            let attachment = sealing(photo, at: sentAt)
        else {
            return nil
        }
        let id = newFrameId()
        var record = MessageRecord(
            id: id,
            senderId: nodeId,
            recipientId: nil,
            conversationId: group.id,
            body: body,
            sentAt: sentAt,
            attachment: attachment,
            replyTo: replyTo,
            mentions: MessageMention.carried(mentions, in: body)
        )
        if configuration.ratchet {
            record.pendingKey = true
            stores.messages.save(record)
            let outcome = sendGroupRatchet(record, in: group)
            record.pendingKey = !outcome.sent
            for member in outcome.unkeyed {
                requestKey(member)
            }
            return record
        }
        let sealed = sealGroup(Self.content(of: record), id: id, sentAt: sentAt, in: group)
        record.pendingKey = sealed.envelope == nil
        stores.messages.save(record)
        if let envelope = sealed.envelope {
            originate(
                chatEnvelope(id: id, sentAt: sentAt, recipient: nil, group: group.info, content: Self.chat(envelope, carrying: record)))
        }
        for member in sealed.unkeyed {
            requestKey(member)
        }
        return record
    }

    /// Renames group `groupId` (`GroupDetailsViewModel.renameGroup`, `:157-166`): the name is normalized to one line
    /// and cut to 32 units, stored, and flooded at once in a `groupupdate`, so members converge without waiting for a
    /// message. Any member may rename, and the newest frame wins. No status line here: only receivers write one.
    /// Answers the renamed group, or `nil` for a blank name or a group we are not in.
    @discardableResult
    public func renameGroup(_ groupId: String, to text: String) -> GroupRecord? {
        guard var group = stores.groups.group(groupId), !group.hasLeft, let name = TextLimits.outgoingGroupName(text) else {
            return nil
        }
        let now = clock.wallMilliseconds()
        group.name = name
        group.nameUpdatedAt = now
        stores.groups.save(group)
        // The roster rides in `group`; the payload is empty, but present, as the wire requires (`MeshManager.kt:1979`).
        originate(RelayEnvelope(type: .groupUpdate, id: newFrameId(), senderId: nodeId.string, sentAt: now, group: group.info, payload: []))
        events.append(.groupChanged(groupId))
        return group
    }

    /// Leaves group `groupId` (`GroupDetailsViewModel.leaveGroup` and `GroupRepository.leave`): floods our signed
    /// `groupleave`, which carries no roster, then deletes the thread and keeps the row as a tombstone, so no frame
    /// can bring the group back. Answers whether we were in it.
    @discardableResult
    public func leaveGroup(_ groupId: String) -> Bool {
        guard var group = stores.groups.group(groupId), !group.hasLeft else {
            return false
        }
        let now = clock.wallMilliseconds()
        let leave = RelayEnvelope(
            type: .groupLeave,
            id: newFrameId(),
            senderId: nodeId.string,
            sentAt: now,
            payload: GroupLeaveContent(groupId: groupId).encoded
        )
        originate(leave)
        group.hasLeft = true
        // One unit, so the thread, the tombstone and the group form's state go together (`GroupRepository.leave`,
        // `GroupRepository.kt:180-194`): every receive chain, stored key and outbox row of the group, and our send chains
        // retired rather than deleted, since the same people put together again are the same group and its next mint must
        // number past what the others hold (knit-next ADR 2026-10.xgwj). On a store the switch never wrote to, the purge
        // writes nothing. A unit that fails leaves us in the group, with the leave already on the air.
        let left = group
        let unit = stores.transactor.atomically { () -> Void? in
            stores.messages.deleteMessages(in: groupId, at: now)
            stores.groups.save(left)
            stores.groupRatchet.purgeGroup(groupId)
            return ()
        }
        guard case .committed = unit else {
            log.log(.warning, "mesh left group \(groupId) on the air but not here: a store failed")
            return false
        }
        events.append(.groupChanged(groupId))
        return true
    }

    /// Seals `content` to each current member of `group` but us whose key is pinned (`recipientBundles`,
    /// `MeshManager.kt:1933-1952`), under the header whose thread is the group's id. Answers `nil` in place of the
    /// envelope when no member is keyed, and the members skipped for want of a key either way.
    func sealGroup(_ content: MessageContent, id: String, sentAt: Int64, in group: GroupRecord) -> (
        envelope: EncEnvelope?, unkeyed: [NodeId]
    ) {
        var bundles: [NodeId: PublicKeyBundle] = [:]
        var unkeyed: [NodeId] = []
        for member in group.members {
            // A member whose id does not parse is kept on the roster, since the group's id hashes it, but no key can
            // ever be pinned for it.
            guard let peer = NodeId(member), peer != nodeId else {
                continue
            }
            if let record = stores.peers.peer(peer), let bundle = PublicKeyBundle(encoded: record.publicKey) {
                bundles[peer] = bundle
            } else {
                unkeyed.append(peer)
            }
        }
        let header = MessageCrypto.header(id: id, senderId: nodeId.string, sentAt: sentAt, thread: group.id)
        let sealed = try? MessageCrypto.seal(content.encoded, header: header, to: bundles)
        return (sealed, unkeyed)
    }

    /// Whether anyone but us is still in `group`.
    func hasOthers(_ group: GroupRecord) -> Bool {
        group.members.contains { ExactKey($0) != ExactKey(nodeId.string) }
    }

    /// Our messages in each group `member` is in that waited for a key, sealed and flooded under their original id and
    /// clock now that `member`'s key has pinned. Each was never signed, so its id is still signed once.
    func flushPendingGroups(for member: NodeId) {
        let key = ExactKey(member.string)
        for group in stores.groups.groups() where !group.hasLeft && group.members.contains(where: { ExactKey($0) == key }) {
            if configuration.ratchet {
                // Each in a send unit of its own, in the form one read of the members' rows decides now (phase P6b).
                for message in stores.messages.pendingKey(in: group.id) {
                    sendGroupRatchet(message, in: group)
                }
                continue
            }
            for message in stores.messages.pendingKey(in: group.id) {
                // A key that pins is one we can seal to; only a key no exchange can use would leave it waiting.
                if let envelope = sealGroup(Self.content(of: message), id: message.id, sentAt: message.sentAt, in: group).envelope {
                    let info = group.info
                    originate(
                        chatEnvelope(
                            id: message.id,
                            sentAt: message.sentAt,
                            recipient: nil,
                            group: info,
                            content: Self.chat(envelope, carrying: message)
                        )
                    )
                    stores.messages.clearPendingKey(message.id)
                    events.append(.sent(messageId: message.id))
                }
            }
        }
    }

    // MARK: What arrives

    /// A group chat (`InboundPipeline.handleChat`, `:675-683`, and `decryptAndDeliver`). The roster is reconciled
    /// first, so a member's verified frame makes the group even when we cannot open it, then the message is opened
    /// and delivered into the group's thread: v1 here, and with the ratchet's switch on, the group form through its own
    /// arm (``handleGroupRatchet(_:_:group:sender:via:)``, `InboundPipeline.kt:961-966`, phase P6a2).
    func handleGroupChat(_ envelope: RelayEnvelope, group info: GroupInfo, sender: NodeId, via hop: NodeId?) {
        guard let chat = try? ChatContent(decoding: envelope.payload) else {
            drop(.undecodable, envelope)
            return
        }
        guard reconcile(info, from: sender, envelope, seedPinning: nil) else {
            return
        }
        guard let enc = chat.enc else {
            // Android always seals a group message; one in the clear would read as private and is not.
            drop(.cleartextGroup, envelope)
            return
        }
        // Custody re-serves the same ciphertext routinely; once the row exists, only the tick is owed.
        if stores.messages.contains(envelope.id) {
            acknowledge(envelope, sender: sender)
            return
        }
        // v2 addressed to a group is the group form whatever headers it carries; off, it drops in `open` as it always has.
        if configuration.ratchet, enc.version == EncEnvelope.Version.ratchet {
            handleGroupRatchet(envelope, enc, group: info, sender: sender, via: hop)
            return
        }
        guard let content = open(enc, envelope), content.ctl == nil else {
            return
        }
        deliverChat(envelope, Self.delivered(content), sender: sender, recipient: nil, via: hop)
    }

    /// A standalone roster frame, such as a rename (`handleGroupUpdate`, `:1976-1979`): reconciled, with no message to
    /// store or tick.
    func handleGroupUpdate(_ envelope: RelayEnvelope) {
        guard let info = envelope.group, let sender = NodeId(envelope.senderId) else {
            return
        }
        reconcile(info, from: sender, envelope, seedPinning: nil)
    }

    /// A member's departure (`handleGroupLeave`, `:1989-1995`). The frame is signed by the key its sender derives
    /// from, so a member can only take themselves off the roster. A leave for a group we do not hold yet is lost, as on
    /// Android, and so is a blocked member's, whose place on the roster stays as it was.
    func handleGroupLeave(_ envelope: RelayEnvelope) {
        guard let leave = try? GroupLeaveContent(decoding: envelope.payload) else {
            drop(.undecodable, envelope)
            return
        }
        if let sender = NodeId(envelope.senderId), isBlocked(sender) {
            drop(.blocked, envelope)
            return
        }
        guard let sender = NodeId(envelope.senderId), let group = stores.groups.group(leave.groupId),
            let departure = GroupRoster.depart(sender, at: clampFuture(envelope.sentAt), from: group)
        else {
            return
        }
        // The leave rekey, in one unit with the roster's shrink (`recordDeparture`, `GroupRepository.kt:127-134`): our send
        // chains retired, every key gone and the newest number kept, so the next send mints an epoch numbered past it for
        // the members who remain (knit-next ADR 2026-10.xgwj), and the leaver's outbox row dropped. Its receive chains
        // drain through the sweep, since its frames from before the leave may still be served. On a store the switch never
        // wrote to, both write nothing.
        let unit = stores.transactor.atomically { () -> Void? in
            stores.groups.save(departure.group)
            stores.messages.save(departure.notice)
            stores.groupRatchet.retireSendChains(group.id)
            stores.groupRatchet.deleteKeySend(group.id, member: sender)
            return ()
        }
        guard case .committed = unit else {
            drop(.storeRefused, envelope)
            log.log(.warning, "mesh leave \(envelope.id) from \(sender) not recorded: a store failed")
            return
        }
        events.append(.groupChanged(group.id))
    }

    /// Brings our row in line with a roster from `sender`'s frame, and writes the status lines it earns, in one unit.
    /// Answers whether the group is ours and active, so a chat frame should be delivered: not when the unit failed. A chat
    /// frame then waits in custody for the start's replay, and a rename is lost, as on Android. A sender's own frame that
    /// brings it back retires our send chains in that unit (`rejoinRekeyDue`, `InboundPipeline.kt:2308-2321`; phase P6b):
    /// with the ratchet's switch on at most once an hour per group and member, a floor held in memory and stamped once the
    /// unit commits, and with it off at every rejoin, which writes nothing on a store the switch never wrote to.
    ///
    /// With the ratchet's switch on, a roster that lands then lets in the seeds that waited for it
    /// (`reconcileGroup`'s second half, `InboundPipeline.kt:2167-2178`, phase P6a2): the parked seeds whose sender the row
    /// now admits open again, and at a group's first sight the ratchet DMs our custody holds from its roster open again
    /// too, all but `seedPinning`, the seed whose own roster is making the row and is still being handled.
    @discardableResult
    func reconcile(_ info: GroupInfo, from sender: NodeId, _ envelope: RelayEnvelope, seedPinning: String?) -> Bool {
        let existing = stores.groups.group(info.id)
        if isBlockedGroupFrame(info, from: sender, existing: existing) {
            drop(.blocked, envelope)
            return false
        }
        let roster = GroupRoster(me: nodeId, maxClock: clampFuture(.max))
        let verdict = roster.reconcile(info, from: sender, at: clampFuture(envelope.sentAt), existing: existing)
        switch verdict {
        case .ignored:
            return false
        case .refused:
            drop(.rosterRefused, envelope)
            return false
        case .accepted(let group, let notices):
            // Whatever the switch says, as a departure's retire: a chain minted while it was on and reused across a rejoin
            // seen while it was off would reach the rejoiner with every frame it missed. The floor is the switch's alone.
            let monotonic = clock.monotonicMilliseconds()
            let rekey =
                GroupRoster.rejoined(sender, from: existing, to: group)
                && (!configuration.ratchet || groupFloors.rekeyDue(in: group.id, for: sender, now: monotonic))
            guard store(group, over: existing, notices: notices, retiring: rekey) else {
                drop(.storeRefused, envelope)
                log.log(.warning, "mesh roster of \(group.id) from \(envelope.id) not stored: a store failed")
                return false
            }
            if rekey, configuration.ratchet {
                groupFloors.rekeyed(in: group.id, for: sender, now: monotonic)
            }
            if group != existing {
                events.append(.groupChanged(group.id))
            }
            if configuration.ratchet {
                seedsMayLand(in: group, firstSight: existing == nil, except: seedPinning)
            }
            return true
        }
    }

    /// Writes what a reconciled roster changed in one unit, and answers whether it stood: the row when it moved, the status
    /// lines it earned, and with `retiring` our send chains retired, the rejoin rekey (`recordRejoin`, `GroupRepository.kt:156-168`),
    /// so the next send mints an epoch for the roster as it now stands and the rejoiner reads nothing sealed while it was
    /// out. A frame that changes nothing opens no unit.
    private func store(_ group: GroupRecord, over existing: GroupRecord?, notices: [MessageRecord], retiring: Bool) -> Bool {
        guard group != existing || !notices.isEmpty || retiring else {
            return true
        }
        let unit = stores.transactor.atomically { () -> Void? in
            if group != existing {
                stores.groups.save(group)
            }
            for notice in notices {
                stores.messages.save(notice)
            }
            if retiring {
                stores.groupRatchet.retireSendChains(group.id)
            }
            return ()
        }
        guard case .committed = unit else {
            return false
        }
        return true
    }
}
