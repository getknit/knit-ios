import KnitCrypto
import KnitMesh
public import KnitStore
import KnitWire

// A command's message, and the quote of a reply (ADR 2026-10.mn29), apart so `MeshControl` stays inside the lint's length.
extension MeshControl {
    /// Where a command's message goes.
    enum Destination {
        case room
        case direct(NodeId)
        case group(String)
    }

    /// Sends `text`, with `photo`, to `destination`, quoting the message `replyTo` names when it names one, and answers the
    /// sent message's reply. A `replyTo` this node does not hold sends nothing.
    func send(_ text: String, photo: OutgoingPhoto?, replyTo: String?, to destination: Destination) async -> Result<
        [String: JSONValue], ControlError
    > {
        var quoting: MessageReply?
        if let replyTo {
            guard let quote = await quote(of: replyTo) else {
                return .failure(.refused("no message \(replyTo) is held here to reply to"))
            }
            quoting = quote
        }
        let sending = await identified(photo)
        let record: MessageRecord?
        let refusal: String
        switch destination {
        case .room:
            record = await actions.postToRoom(text, photo: sending, replyTo: quoting)
            refusal = "a blank message, or a photo past 8 MiB, is not sent"
        case .direct(let recipient):
            record = await actions.sendDirectMessage(text, to: recipient, photo: sending, replyTo: quoting)
            refusal = "a blank message, a photo past 8 MiB, or one to ourselves, is not sent"
        case .group(let conversation):
            record = await actions.sendGroupMessage(text, to: conversation, photo: sending, replyTo: quoting)
            refusal = "a blank message, a photo past 8 MiB, or one to a group we are not in or nobody else is left in, is not sent"
        }
        guard let record else {
            return .failure(.refused(refusal))
        }
        return .success(Self.sent(record, reusing: sending))
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
}
