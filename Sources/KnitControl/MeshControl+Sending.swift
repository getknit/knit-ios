import KnitCrypto
import KnitMesh
public import KnitStore
public import KnitWire

// A command's message, the quote of a reply (ADR 2026-10.mn29) and the people it mentions (ADR 2026-10.nbhj), apart so
// `MeshControl` stays inside the lint's length.
extension MeshControl {
    /// Where a command's message goes.
    enum Destination {
        case room
        case direct(NodeId)
        case group(String)
    }

    /// Sends `text`, with `photo`, to `destination`, quoting the message `replyTo` names when it names one and mentioning
    /// `mentions`, and answers the sent message's reply. A `replyTo` this node does not hold sends nothing; a mention whose
    /// "@" and label the text doesn't carry is dropped, as the composer drops one.
    func send(
        _ text: String, photo: OutgoingPhoto?, replyTo: String?, mentions: [NodeId], to destination: Destination
    ) async -> Result<[String: JSONValue], ControlError> {
        var quoting: MessageReply?
        if let replyTo {
            guard let quote = await quote(of: replyTo) else {
                return .failure(.refused("no message \(replyTo) is held here to reply to"))
            }
            quoting = quote
        }
        var mentioning: [MessageMention] = []
        for person in mentions {
            mentioning.append(await mention(of: person))
        }
        let sending = await identified(photo)
        let record: MessageRecord?
        let refusal: String
        switch destination {
        case .room:
            record = await actions.postToRoom(text, photo: sending, replyTo: quoting, mentions: mentioning)
            refusal = "a blank message, or a photo past 8 MiB, is not sent"
        case .direct(let recipient):
            record = await actions.sendDirectMessage(text, to: recipient, photo: sending, replyTo: quoting, mentions: mentioning)
            refusal = "a blank message, a photo past 8 MiB, or one to ourselves, is not sent"
        case .group(let conversation):
            record = await actions.sendGroupMessage(text, to: conversation, photo: sending, replyTo: quoting, mentions: mentioning)
            refusal = "a blank message, a photo past 8 MiB, or one to a group we are not in or nobody else is left in, is not sent"
        }
        guard let record else {
            return .failure(.refused(refusal))
        }
        return .success(Self.sent(record, reusing: sending))
    }

    /// The mention of `person`: the actions' own, as the app's composer writes it under its label, or else one under the
    /// person's stored name, or their alias without one, which `knit-peer` runs with no labels.
    private func mention(of person: NodeId) async -> MessageMention {
        if let made = await actions.mention(of: person) {
            return made
        }
        let stored = person == nodeId ? stores.ownProfile.load().name : stores.peers.peer(person)?.name
        return MessageMention(nodeId: person.string, name: Alias.displayName(stored: stored, nodeId: person.string))
    }

    /// The quote a reply to message `id` carries: the actions' own, as the app's composer writes it, or else the one
    /// Android's composer would write, under the author's stored name, with no label and no filter, which `knit-peer` runs
    /// without. `nil` for a message not held, or a status line.
    private func quote(of id: String) async -> MessageReply? {
        if let made = await actions.quote(of: id) {
            return made
        }
        guard let parent = stores.messages.message(id), !parent.kind.isNotice else {
            return nil
        }
        let stored = parent.senderId == nodeId ? stores.ownProfile.load().name : stores.peers.peer(parent.senderId)?.name
        let name = Alias.displayName(stored: stored, nodeId: parent.senderId.string)
        return MessageReply.quoting(parent, authorName: name, hidesWords: false, attachmentLabel: nil)
    }
}

extension ControlActions {
    /// No quote of its own: the control surface writes the one Android's composer would.
    public func quote(of _: String) -> MessageReply? {
        nil
    }

    /// No mention of its own: the control surface writes one under the person's stored name.
    public func mention(of _: NodeId) -> MessageMention? {
        nil
    }
}
