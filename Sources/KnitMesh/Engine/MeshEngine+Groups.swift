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

    /// Sends `text` to group `groupId`, with `photo` sealed beside it if one is given (`MeshManager.sendChat`): sealed
    /// to each current member whose key is pinned, with the group's roster beside it. Members without a key are
    /// skipped, as on Android, and their keys are asked for. When nobody's key is pinned the message waits as
    /// `pendingKey`, and goes out once one pins, which Android never does. Answers the stored message, or `nil` for a
    /// blank message with no photo, a photo too heavy to send, a group we are not in, or one nobody else is left in.
    @discardableResult
    public func sendGroupMessage(_ text: String, to groupId: String, photo: OutgoingPhoto? = nil) -> MessageRecord? {
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
            attachment: attachment
        )
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
        // The thread goes first: a crash between the two leaves an empty group still open, not old messages that a
        // later re-create would bring back.
        stores.messages.deleteMessages(in: groupId, at: now)
        group.hasLeft = true
        stores.groups.save(group)
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
    /// and delivered into the group's thread.
    func handleGroupChat(_ envelope: RelayEnvelope, group info: GroupInfo, sender: NodeId, via hop: NodeId?) {
        guard let chat = try? ChatContent(decoding: envelope.payload) else {
            drop(.undecodable, envelope)
            return
        }
        guard reconcile(info, from: sender, envelope) else {
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
        reconcile(info, from: sender, envelope)
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
        stores.groups.save(departure.group)
        stores.messages.save(departure.notice)
        events.append(.groupChanged(group.id))
    }

    /// Brings our row in line with a roster from `sender`'s frame, and writes the status lines it earns. Answers
    /// whether the group is ours and active, so a chat frame should be delivered.
    @discardableResult
    func reconcile(_ info: GroupInfo, from sender: NodeId, _ envelope: RelayEnvelope) -> Bool {
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
            if group != existing {
                stores.groups.save(group)
                events.append(.groupChanged(group.id))
            }
            for notice in notices {
                stores.messages.save(notice)
            }
            return true
        }
    }

    /// Delivers the group chats our own custody holds and our threads lack (`MeshManager.replayCustodiedGroupFrames`,
    /// `MeshManager.kt:1600-1632`), oldest first: those carried before this build showed groups, and any whose
    /// delivery was cut short. Each was verified when it was carried; one already delivered is skipped here, so it is
    /// not ticked again.
    func replayCustodiedGroupChats() {
        let frames = stores.custody.liveFrames(now: clock.wallMilliseconds()).reversed()
        for frame in frames where frame.envelope.type == .chat && frame.envelope.group != nil {
            if !stores.messages.contains(frame.envelope.id) {
                // Custody kept no hop, so the photo it carries is asked of its author first.
                handleChat(frame.envelope, via: nil)
            }
        }
    }
}
