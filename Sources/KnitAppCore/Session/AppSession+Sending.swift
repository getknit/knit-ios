public import KnitMesh
public import KnitStore
import KnitWire

// What a session sends: a message in any thread, with a photo and a quote if it has them.
extension AppSession {
    /// Sends `text` in a thread, with `photo` if one is given, quoting `replyTo` if it replies: the room, a group, or a DM
    /// to the node id the thread is named for. A photo may go with no words. Answers what was stored, or `nil` when there
    /// is nothing to send.
    @discardableResult
    public func send(
        _ text: String, photo: OutgoingPhoto? = nil, replyTo: MessageReply? = nil, in conversationId: String
    ) async -> MessageRecord? {
        guard let body = Composer.body(of: text) ?? (photo == nil ? nil : "") else {
            return nil
        }
        let sent: MessageRecord?
        if conversationId == Conversations.nearby {
            sent = await mesh.postToRoom(body, photo: photo, replyTo: replyTo)
        } else if Conversations.isGroup(conversationId) {
            sent = await mesh.sendGroupMessage(body, to: conversationId, photo: photo, replyTo: replyTo)
        } else if let recipient = NodeId(conversationId), recipient != identity.nodeId {
            sent = await mesh.sendDirectMessage(body, to: recipient, photo: photo, replyTo: replyTo)
        } else {
            return nil
        }
        await measure(sent?.attachment.map { [$0] } ?? [])
        revision += 1
        return sent
    }
}
