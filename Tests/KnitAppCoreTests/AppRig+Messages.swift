import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire

@testable import KnitAppCore

extension AppRig {
    /// Stores a message from `sender` to `recipient` (the room when `nil`), as the engine would on arrival: someone else's
    /// words wait for the content filter, and a quote is judged against its original when that is held, else its words
    /// wait for the filter apart from the body's; then the replies waiting on this one settle (`MeshEngine+Quotes`,
    /// knit-next ADR 2026-10.gpa3).
    @discardableResult
    func receive(
        _ body: String,
        from sender: NodeId,
        to recipient: NodeId? = nil,
        id: String? = nil,
        sentAt: Int64 = 1000,
        arrivedAt: Int64 = 1000,
        replyTo: MessageReply? = nil,
        mentions: [MessageMention] = [],
        attachment: MessageAttachment? = nil
    ) async -> MessageRecord {
        var record = MessageRecord(
            id: id ?? "\(sender)-\(sentAt)-\(body)",
            senderId: sender,
            recipientId: recipient,
            conversationId: Conversations.id(sender: sender, recipient: recipient, me: me),
            body: body,
            sentAt: sentAt,
            arrivedAt: arrivedAt,
            attachment: attachment,
            moderation: sender == me || TextLimits.isBlank(body) ? .clear : .waiting,
            replyTo: replyTo,
            mentions: mentions
        )
        if let replyTo, sender != me {
            if let original = stores.messages.message(replyTo.messageId) {
                record = record.settled(with: MessageReply.settlement(of: record, against: original) { _ in nil })
            } else {
                record.quoteModeration = TextLimits.isBlank(replyTo.snippet) ? .clear : .waiting
            }
        }
        stores.messages.save(record)
        for waiting in stores.messages.repliesAwaiting(record.id, me: me, limit: 200) {
            stores.messages.settleQuote(waiting.id, MessageReply.settlement(of: waiting, against: record) { _ in nil })
        }
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
