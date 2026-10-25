public import KnitStore
public import KnitWire

// The app's sends, kept out of the actor's body to hold it under 250 lines, and out of its file to hold that under 400.
extension Mesh {
    /// Posts to the Nearby room, with a photo if one is given, quoting the message it replies to if it replies and naming
    /// the people it mentions (``MeshEngine/postToRoom(_:photo:replyTo:mentions:)``).
    @discardableResult
    public func postToRoom(
        _ text: String, photo: OutgoingPhoto? = nil, replyTo: MessageReply? = nil, mentions: [MessageMention] = []
    ) -> MessageRecord? {
        defer { settle() }
        return engine.postToRoom(text, photo: photo, replyTo: replyTo, mentions: mentions)
    }

    /// Sends a DM, with a photo if one is given, quoting the message it replies to if it replies and naming the people it
    /// mentions (``MeshEngine/sendDirectMessage(_:to:photo:replyTo:mentions:)``).
    @discardableResult
    public func sendDirectMessage(
        _ text: String, to recipient: NodeId, photo: OutgoingPhoto? = nil, replyTo: MessageReply? = nil,
        mentions: [MessageMention] = []
    ) -> MessageRecord? {
        defer { settle() }
        return engine.sendDirectMessage(text, to: recipient, photo: photo, replyTo: replyTo, mentions: mentions)
    }

    /// Sends a message to a group, with a photo if one is given, quoting the message it replies to if it replies and
    /// naming the people it mentions (``MeshEngine/sendGroupMessage(_:to:photo:replyTo:mentions:)``).
    @discardableResult
    public func sendGroupMessage(
        _ text: String, to groupId: String, photo: OutgoingPhoto? = nil, replyTo: MessageReply? = nil,
        mentions: [MessageMention] = []
    ) -> MessageRecord? {
        defer { settle() }
        return engine.sendGroupMessage(text, to: groupId, photo: photo, replyTo: replyTo, mentions: mentions)
    }
}
