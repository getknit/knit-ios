import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire

@testable import KnitAppCore

extension AppRig {
    /// Stores a group of `others` and us, as the engine would on first sight of a frame from `creator`, with its
    /// created line and a left line for each of `departed`.
    @discardableResult
    func group(_ others: [Person], name: String = "", createdBy creator: Person, departed: [Person] = []) async -> GroupRecord {
        let time: Int64 = 500
        let present = (others.map(\.nodeId) + [me]).map { GroupMember(nodeId: $0.string) }
        let gone = departed.map { GroupMember(nodeId: $0.nodeId.string, departed: true, leftAt: time) }
        let founding = (present + gone).map(\.nodeId)
        let group = GroupRecord(
            id: GroupId.derive(founding),
            name: name,
            createdBy: creator.nodeId.string,
            createdAt: time,
            roster: present + gone
        )
        stores.groups.save(group)
        stores.messages.save(StatusNotices.groupCreated(group.id, by: creator.nodeId, at: time))
        for person in departed {
            stores.messages.save(StatusNotices.memberLeft(group.id, member: person.nodeId, at: time))
        }
        await session.handle(.groupChanged(group.id))
        return group
    }

    /// Stores a message from `sender` in `group`, as the engine would on arrival.
    @discardableResult
    func receive(
        _ body: String,
        from sender: NodeId,
        in group: GroupRecord,
        sentAt: Int64 = 1000,
        pendingKey: Bool = false
    ) async -> MessageRecord {
        let record = MessageRecord(
            id: "\(group.id)-\(sentAt)-\(body)",
            senderId: sender,
            recipientId: nil,
            conversationId: group.id,
            body: body,
            sentAt: sentAt,
            arrivedAt: sender == me ? nil : sentAt,
            pendingKey: pendingKey
        )
        stores.messages.save(record)
        await session.handle(.received(record, isRequest: session.threads().isRequest(group.id)))
        return record
    }
}
