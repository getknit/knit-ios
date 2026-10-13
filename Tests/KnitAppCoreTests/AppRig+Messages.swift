import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire

@testable import KnitAppCore

extension AppRig {
    /// Stores a message from `sender` to `recipient` (the room when `nil`), as the engine would on arrival: someone else's
    /// words wait for the content filter.
    @discardableResult
    func receive(
        _ body: String,
        from sender: NodeId,
        to recipient: NodeId? = nil,
        id: String? = nil,
        sentAt: Int64 = 1000,
        arrivedAt: Int64 = 1000
    ) async -> MessageRecord {
        let record = MessageRecord(
            id: id ?? "\(sender)-\(sentAt)-\(body)",
            senderId: sender,
            recipientId: recipient,
            conversationId: Conversations.id(sender: sender, recipient: recipient, me: me),
            body: body,
            sentAt: sentAt,
            arrivedAt: arrivedAt,
            moderation: sender == me || TextLimits.isBlank(body) ? .clear : .waiting
        )
        stores.messages.save(record)
        let isRequest = session.threads().isRequest(record.conversationId)
        await session.handle(.received(record, isRequest: isRequest))
        return record
    }

    /// Pins `person` under `name`.
    func pin(_ person: Person, name: String, verified: Bool = false) async {
        stores.peers.upsert(person.record(name: name, verified: verified))
        await session.handle(.peerUpdated(person.nodeId))
    }
}
