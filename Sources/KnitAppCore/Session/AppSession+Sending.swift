public import KnitMesh
public import KnitStore
public import KnitWire

// What a session sends: a message in any thread, with a photo and a quote if it has them.
extension AppSession {
    /// The quote a reply to message `id` carries, as Android's composer writes one (`ChatScreen.kt:1352-1388`, ADR
    /// 2026-10.mn29): the author's own name, ours included, never "You"; words the filter hides from us left out; a label
    /// for a GIF, a file or a voice note with no words. `nil` for a message not held, or a status line.
    public func quote(of id: String) -> MessageReply? {
        guard let parent = stores.messages.message(id), !parent.kind.isNotice else {
            return nil
        }
        return MessageReply.quoting(
            parent,
            authorName: directory.label(for: parent.senderId).name,
            hidesWords: parent.hidesWords(filtering: filtersContent, me: identity.nodeId),
            attachmentLabel: TextLimits.isBlank(parent.body) ? AttachmentKind.quoteLabel(of: parent.attachment) : nil
        )
    }

    /// The mention of `person` the composer writes: their node id, under this phone's clash-aware label, as Android writes
    /// `resolved.text` (ADR 2026-10.nbhj).
    public func mention(of person: NodeId) -> MessageMention {
        MessageMention(nodeId: person.string, name: directory.label(for: person).text)
    }

    /// Sends `text` in a thread, with `photo` if one is given, quoting `replyTo` if it replies, and mentioning `mentions`
    /// (ADR 2026-10.nbhj): the room, a group, or a DM to the node id the thread is named for. A photo may go with no words.
    /// Answers what was stored, or `nil` when there is nothing to send. The engine keeps the mentions the words carry.
    @discardableResult
    public func send(
        _ text: String, photo: OutgoingPhoto? = nil, replyTo: MessageReply? = nil, mentions: [MessageMention] = [],
        in conversationId: String
    ) async -> MessageRecord? {
        guard let body = Composer.body(of: text) ?? (photo == nil ? nil : "") else {
            return nil
        }
        let sent: MessageRecord?
        if conversationId == Conversations.nearby {
            sent = await mesh.postToRoom(body, photo: photo, replyTo: replyTo, mentions: mentions)
        } else if Conversations.isGroup(conversationId) {
            sent = await mesh.sendGroupMessage(body, to: conversationId, photo: photo, replyTo: replyTo, mentions: mentions)
        } else if let recipient = NodeId(conversationId), recipient != identity.nodeId {
            sent = await mesh.sendDirectMessage(body, to: recipient, photo: photo, replyTo: replyTo, mentions: mentions)
        } else {
            return nil
        }
        await measure(sent?.attachment.map { [$0] } ?? [])
        revision += 1
        return sent
    }
}
