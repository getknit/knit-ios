import KnitStore
import KnitWire

/// Delivering a message to us (`InboundPipeline.deliverChat`), in two halves: the row, which writes the message store and
/// nothing else, and the work after it. A DM opened with the ratchet writes its row inside the store unit its open
/// commits in, and runs the rest only once that unit has committed, so a unit that fails delivers and acknowledges
/// nothing (ADR 2026-10.5sk9, phase P5a). A v1 DM, a group message and a room post run both halves at once, as before.
extension MeshEngine {
    /// Stores a delivered message and acknowledges it (`InboundPipeline.deliverChat`). A re-served frame leaves the
    /// row as it was and is not announced again, and the receipt goes out every time. A photo the message carries is
    /// fetched at once unless its bytes are already here, as they are when they were carried for someone else: asked of
    /// its author first, then of `hop`, the neighbour the frame came from, which `nil` leaves unnamed (knit-next ADR
    /// 2026-10.f7gg).
    ///
    /// Someone else's words are stored waiting for the content filter (ADR 2026-10.e4kz). Android classifies them
    /// before the row is written (`InboundPipeline.inboundModeration`); here the app screens them as it hears the
    /// event, off this actor, and nothing shows them until it has.
    func deliverChat(_ envelope: RelayEnvelope, _ delivered: DeliveredChat, sender: NodeId, recipient: NodeId?, via hop: NodeId?) {
        announce(storeDelivered(envelope, delivered, sender: sender, recipient: recipient), envelope, sender: sender, via: hop)
    }

    /// The row half of ``deliverChat(_:_:sender:recipient:via:)``: the message stored unless its id is held, and what the
    /// work after it needs. It reads and writes the message store and nothing else, so it may run inside a store unit:
    /// nothing here sends, announces, or reads or writes a blob.
    func storeDelivered(_ envelope: RelayEnvelope, _ delivered: DeliveredChat, sender: NodeId, recipient: NodeId?) -> StoredDelivery {
        // A group's thread is the group; a DM's and the room's follow from who sent it to whom.
        let conversation = envelope.group?.id ?? Conversations.id(sender: sender, recipient: recipient, me: nodeId)
        let isNew = !stores.messages.contains(envelope.id)
        // Our own limit bounds what we send, not what a peer floods.
        let body = TextLimits.truncated(delivered.body, toUTF16: TextLimits.message)
        // A quote is someone's words too, and the filter reads them with the reply's (ADR 2026-10.mn29).
        let wordless = TextLimits.isBlank(body) && TextLimits.isBlank(delivered.replyTo?.snippet ?? "")
        let record = MessageRecord(
            id: envelope.id,
            senderId: sender,
            recipientId: recipient,
            conversationId: conversation,
            body: body,
            sentAt: clampFuture(envelope.sentAt),
            arrivedAt: sender == nodeId ? nil : clock.wallMilliseconds(),
            attachment: delivered.attachment,
            moderation: sender == nodeId || wordless ? .clear : .waiting,
            replyTo: delivered.replyTo,
            // Only the mentions the kept body still holds: that bounds a peer's list, where Android keeps any
            // (`InboundPipeline.kt:2660`, ADR 2026-10.nbhj).
            mentions: MessageMention.carried(delivered.mentions, in: body)
        )
        stores.messages.insertIfAbsent(record)
        return StoredDelivery(record: record, isNew: isNew)
    }

    /// The half of ``deliverChat(_:_:sender:recipient:via:)`` after the row: the sender's typing cue ends, a new message
    /// is announced, what it carries is fetched or held, and the frame is acknowledged. For a ratchet DM it runs only once
    /// the unit that stored the row has committed.
    func announce(_ stored: StoredDelivery, _ envelope: RelayEnvelope, sender: NodeId, via hop: NodeId?) {
        let conversation = stored.record.conversationId
        // Every delivery ends the sender's cue in the thread, a re-delivery too (`InboundPipeline.kt:2728`), and before
        // the message is announced, so no screen shows both.
        clearTyping(sender, in: conversation)
        if stored.isNew, sender != nodeId {
            events.append(.received(stored.record, isRequest: !isAccepted(conversation)))
        }
        if let attachment = stored.record.attachment {
            receiveAttachment(attachment, author: sender, via: hop)
        }
        acknowledge(envelope, sender: sender)
    }

    /// Fetches what a delivered message carries, unless its bytes are here already, when a sealed one learns its
    /// plaintext's name. A key-less picture, a room post's or one forwarded under its public name, is held from our own
    /// sealed copy instead when its author was party to the conversation that copy came through (ADR 2026-10.f3mv);
    /// this is the one door to that copy.
    private func receiveAttachment(_ attachment: MessageAttachment, author: NodeId, via hop: NodeId?) {
        let hash = attachment.hash
        if stores.blobs.contains(hash) {
            notePlainHash(hash)
        } else if attachment.key == nil, !transport.arrivingFileKeys.contains(hash), copyFromOwnStore(hash, author: author) {
            events.append(.attachmentArrived(hash))
            return
        }
        wantBlob(hash, author: author, via: hop, asker: nil)
    }
}

/// A message delivered to us and stored (``MeshEngine/storeDelivered(_:_:sender:recipient:)``): its row, and whether the
/// row is new, for the work after the unit that stored it commits.
internal struct StoredDelivery {
    /// The row as delivered.
    let record: MessageRecord
    /// Whether no row held its id before: only a new message is announced.
    let isNew: Bool
}
