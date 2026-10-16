import KnitCrypto
public import KnitStore
public import KnitWire

extension MeshEngine {
    // MARK: Messages we write

    /// Posts `text` to the Nearby room, with `photo` if one is given, quoting `replyTo` if it replies and naming
    /// `mentions`: stored, signed, flooded and carried (`MeshManager.sendChat`). A room post is cleartext and signed, and
    /// so are its photo, kept under its own hash for anyone who asks, its quote and its mentions (`MeshManager.kt:1084-1090`).
    /// Only the mentions whose token the sent body holds go (``MessageMention/carried(_:in:)``, ADR 2026-10.nbhj).
    /// Answers the stored message, or `nil` for a blank post with no photo, or a photo too heavy to send.
    @discardableResult
    public func postToRoom(
        _ text: String, photo: OutgoingPhoto? = nil, replyTo: MessageReply? = nil, mentions: [MessageMention] = []
    ) -> MessageRecord? {
        guard let body = Self.messageBody(text, photo: photo) else {
            return nil
        }
        let sentAt = clock.wallMilliseconds()
        let attachment = photo.map { keepPhoto($0, at: sentAt) }
        let record = MessageRecord(
            id: newFrameId(),
            senderId: nodeId,
            recipientId: nil,
            conversationId: Conversations.nearby,
            body: body,
            sentAt: sentAt,
            attachment: attachment,
            replyTo: replyTo,
            mentions: MessageMention.carried(mentions, in: body)
        )
        stores.messages.save(record)
        let content = ChatContent(
            body: body,
            mentions: record.mentions.map(Self.wire),
            attachmentHash: attachment?.hash.string,
            attachmentMime: attachment?.mime,
            replyTo: replyTo.map(Self.wire)
        )
        originate(chatEnvelope(id: record.id, sentAt: sentAt, recipient: nil, group: nil, content: content))
        return record
    }

    /// Sends `text` to `recipient` as a DM, with `photo` sealed beside it if one is given, and `replyTo` and `mentions`
    /// sealed inside it (`MeshManager.sendChat`, `MeshManager.kt:1095-1106`). Only the mentions whose token the sent body
    /// holds go (``MessageMention/carried(_:in:)``, ADR 2026-10.nbhj). With no key pinned for the recipient it is stored
    /// as pending, mentions and all, and sealed once their profile arrives. Answers the stored message, or `nil` for a
    /// blank message with no photo, a photo too heavy to send, or a message to ourselves.
    ///
    /// It is sealed v1, as it always was, unless the ratchet's switch is on: then one read of the recipient's pinned row
    /// decides (``sendDirect(_:to:as:)``), and a DM to a peer whose profile carries `CAP_RATCHET` is stored waiting and
    /// sealed with the ratchet in a store unit of its own, which clears the wait as it commits (ADR 2026-10.5sk9, phase
    /// P5b).
    @discardableResult
    public func sendDirectMessage(
        _ text: String, to recipient: NodeId, photo: OutgoingPhoto? = nil, replyTo: MessageReply? = nil,
        mentions: [MessageMention] = []
    ) -> MessageRecord? {
        let sentAt = clock.wallMilliseconds()
        guard recipient != nodeId, let body = Self.messageBody(text, photo: photo), let attachment = sealing(photo, at: sentAt) else {
            return nil
        }
        let id = newFrameId()
        var record = MessageRecord(
            id: id,
            senderId: nodeId,
            recipientId: recipient,
            conversationId: recipient.string,
            body: body,
            sentAt: sentAt,
            attachment: attachment,
            replyTo: replyTo,
            mentions: MessageMention.carried(mentions, in: body)
        )
        if configuration.ratchet {
            return sendDirect(record, to: recipient, as: directScheme(for: record, to: stores.peers.peer(recipient)))
        }
        let sealed = seal(Self.content(of: record), id: id, sentAt: sentAt, to: recipient)
        record.pendingKey = sealed == nil
        stores.messages.save(record)
        if let sealed {
            originate(chatEnvelope(id: id, sentAt: sentAt, recipient: recipient, group: nil, content: Self.chat(sealed, carrying: record)))
        }
        return record
    }

    /// Accepts a message request, so the thread is a chat and its messages notify.
    public func accept(_ conversationId: String) {
        stores.conversations.accept(conversationId)
    }

    /// The body we send: at most 2000 UTF-16 units, and `nil` when blank, unless a photo goes with it, which may go
    /// with no words at all. A photo heavier than ``OutgoingPhoto/maxBytes`` sends nothing.
    static func messageBody(_ text: String, photo: OutgoingPhoto?) -> String? {
        if let photo, photo.bytes.count > OutgoingPhoto.maxBytes {
            return nil
        }
        let body = TextLimits.truncated(text, toUTF16: TextLimits.message)
        guard TextLimits.isBlank(body) else {
            return body
        }
        return photo == nil ? nil : ""
    }

    /// Keeps a room post's photo as it is, under its own hash, and answers what the message carries. A picture held
    /// sealed goes to the room under its plaintext's name all the same, as on Android.
    func keepPhoto(_ photo: OutgoingPhoto, at now: Int64) -> MessageAttachment {
        let hash = BlobHash(of: photo.bytes)
        stores.blobs.insert(photo.bytes, hash: hash, mime: photo.mime, storedAt: now)
        return MessageAttachment(hash: hash, mime: photo.mime, sourceHash: photo.sourceHash)
    }

    /// What a DM or a group message carries: nothing without a photo, or `photo` sealed and kept (``sealPhoto(_:at:)``).
    /// The outer `nil` is a photo that would not seal, which a send's `guard` stops at.
    func sealing(_ photo: OutgoingPhoto?, at now: Int64) -> MessageAttachment?? {
        guard let photo else {
            return .some(nil)
        }
        return sealPhoto(photo, at: now).map(Optional.some)
    }

    /// What a DM's or a group message's photo goes as (`MeshManager.sealAttachment`): the blob this phone already holds
    /// it as, if its identity's blob is still here, so a picture is sealed once (ADR 2026-10.f3mv); otherwise sealed
    /// under a fresh key, the ciphertext kept under its own hash. A room post's picture goes as its key-less self. The
    /// message carries the blob's hash, the type and the key, which travel sealed, and remembers the plaintext's name and
    /// the picked bytes', which never leave this phone. `nil` only if sealing fails.
    func sealPhoto(_ photo: OutgoingPhoto, at now: Int64) -> MessageAttachment? {
        let plainHash = BlobHash(of: photo.bytes)
        if let held = photo.identity, stores.blobs.contains(held.hash) {
            return MessageAttachment(
                hash: held.hash,
                mime: photo.mime,
                key: held.key,
                plainHash: held.key == nil ? nil : plainHash,
                sourceHash: photo.sourceHash
            )
        }
        // No identity, or its blob went between the pick and the send: seal it afresh, from the bytes in hand.
        return AttachmentCrypto.seal(photo.bytes).map { sealed in
            let hash = BlobHash(of: sealed.blob)
            stores.blobs.insert(sealed.blob, hash: hash, mime: photo.mime, storedAt: now)
            return MessageAttachment(
                hash: hash,
                mime: photo.mime,
                key: Base64.encode(sealed.key),
                plainHash: plainHash,
                sourceHash: photo.sourceHash
            )
        }
    }

    /// The sealed content of one of our messages: its body and mentions, its attachment's hash, type, key, and a file's
    /// name and size, and the quote of the message it replies to, all inside the ciphertext (`MessageContent.mentions`,
    /// `MessageContent.replyTo`). A message that waited for a key is sealed from its stored row, so it keeps them
    /// (`MeshManager.resealAndFlood`, `MeshManager.kt:3268-3276`).
    static func content(of message: MessageRecord) -> MessageContent {
        let attachment = message.attachment
        return MessageContent(
            body: message.body,
            mentions: message.mentions.map(wire),
            attachmentHash: attachment?.hash.string,
            attachmentMime: attachment?.mime,
            attachmentKey: attachment?.key,
            attachmentName: attachment?.name,
            attachmentSize: attachment?.size,
            replyTo: message.replyTo.map(wire)
        )
    }

    /// A mention as the wire carries it (`Mention`, `Wire.kt:394-400`).
    static func wire(_ mention: MessageMention) -> Mention {
        Mention(nodeId: mention.nodeId, name: mention.name)
    }

    /// A quote as the wire carries it (`ReplyRef`).
    static func wire(_ reply: MessageReply) -> ReplyRef {
        ReplyRef(
            messageId: reply.messageId,
            authorId: reply.authorId,
            author: reply.author,
            snippet: reply.snippet,
            hasAttachment: reply.hasAttachment
        )
    }

    /// The chat frame's content for a sealed message: the envelope, and beside it in the clear only the ciphertext's
    /// hash, so a carrier blind to the sealed fields can still pull the blob. The type, the key, any quote and any
    /// mentions stay sealed, so the shell's body and mentions are empty (`MeshManager.kt:1112-1128`, `Wire.kt:171-193`).
    static func chat(_ sealed: EncEnvelope, carrying message: MessageRecord) -> ChatContent {
        ChatContent(attachmentHash: message.attachment?.hash.string, enc: sealed)
    }

    func chatEnvelope(id: String, sentAt: Int64, recipient: NodeId?, group: GroupInfo?, content: ChatContent) -> RelayEnvelope {
        RelayEnvelope(
            type: .chat,
            id: id,
            senderId: nodeId.string,
            sentAt: sentAt,
            recipientId: recipient?.string,
            group: group,
            payload: content.encoded
        )
    }

    /// Seals `content` to `recipient`'s pinned key with v1, or `nil` when none is pinned (ADR 2026-09.qsd9): every DM
    /// with the ratchet's switch off. With it on, the read that chose the scheme gives the bundle (``sendDirect(_:to:as:)``).
    func seal(_ content: MessageContent, id: String, sentAt: Int64, to recipient: NodeId) -> EncEnvelope? {
        guard let peer = stores.peers.peer(recipient), let bundle = PublicKeyBundle(encoded: peer.publicKey) else {
            return nil
        }
        let header = MessageCrypto.header(id: id, senderId: nodeId.string, sentAt: sentAt, thread: recipient.string)
        return try? MessageCrypto.seal(content.encoded, header: header, to: [recipient: bundle])
    }

    /// Our messages that waited for `recipient`'s key, sealed and flooded under their original id and clock now that
    /// the key has pinned (`MeshManager.flushPendingFor`): DMs to them, and group messages in groups they are in. A DM
    /// to someone blocked waits on, as on Android, until an unblock and their next profile; with the ratchet's switch on,
    /// one to a peer whose profile carries `CAP_RATCHET` goes at the first heal after the unblock instead
    /// (``retryWaitingDirectMessages()``), the frame Android sends at that peer's next profile.
    func flushPending(to recipient: NodeId) {
        flushPendingDirect(to: recipient)
        flushPendingGroups(for: recipient)
    }

    /// Our DMs to `recipient` still waiting, sealed and sent, each as ``sendDirectMessage(_:to:photo:replyTo:mentions:)``
    /// would seal it now: with the switch on, as one read of the peer's row decides (``flushWaitingDirect(_:to:)``,
    /// `resealAndFlood` through `sealEnvelopeFor`, `MeshManager.kt:3345-3352`), else v1 as before.
    func flushPendingDirect(to recipient: NodeId) {
        let waiting = isBlocked(recipient) ? [] : stores.messages.pendingKey(to: recipient)
        if configuration.ratchet {
            flushWaitingDirect(waiting, to: recipient)
            return
        }
        for message in waiting {
            if let sealed = seal(Self.content(of: message), id: message.id, sentAt: message.sentAt, to: recipient) {
                originate(
                    chatEnvelope(
                        id: message.id,
                        sentAt: message.sentAt,
                        recipient: recipient,
                        group: nil,
                        content: Self.chat(sealed, carrying: message)
                    )
                )
                stores.messages.clearPendingKey(message.id)
                events.append(.sent(messageId: message.id))
            }
        }
    }

    // MARK: Origination

    /// Signs and floods a frame of ours, and carries it (`MeshManager.originateSigned`).
    func originate(_ envelope: RelayEnvelope) {
        if let wire = sign(envelope, relay: true) {
            originate(SignedFrame(wire: wire, envelope: envelope))
        }
    }

    /// Floods a frame of ours already signed, and carries it (`MeshManager.originateWire`): marked seen, so its
    /// echo is ignored, and written to every neighbour at once.
    func originate(_ frame: SignedFrame) {
        router.markOwn(frame.envelope.id, now: clock.monotonicMilliseconds())
        transport.send(frame.wire, to: nil)
        carryOwn(frame)
    }

    /// Takes a frame of ours into custody, under the same quotas as everyone's (ORIGIN_SELF).
    func carryOwn(_ frame: SignedFrame) {
        let carried = CarriedFrame(envelope: frame.envelope, sig: frame.wire.sig, signed: frame.wire.signed)
        if custody.carryOwn(carried, in: stores.custody, now: clock.wallMilliseconds()) {
            noteCustodyChanged()
        }
    }

    // MARK: Receipts

    /// Acknowledges a message delivered to us (`InboundPipeline.acknowledge`, `InboundPipeline.kt:2831-2859`): a DM earns a
    /// receipt that floods and is carried, a room post or a group message a tick owed to its author. Only a group's tick
    /// may go into custody, for an absent author who could read a sealed one (`escalatable`); a room's never does. Kotlin
    /// lets a commons post's escalate too, and no radio delivers one (``FrameType/commons``).
    ///
    /// With the ratchet's switch on, a DM's receipt goes sealed toward an author who can read one, and purges nothing
    /// (``sendSealedReceipt(for:to:)``, phase P5d). Toward any other author, and when the facade cannot seal, it is the
    /// cleartext receipt, which purges the DM here as at every carrier. A store that fails sends neither, and purges
    /// nothing, as Kotlin's throw does. Kotlin's LoRa hold of a DM's receipt (`DmAckCoalescer`, `:2836-2845`) is not this
    /// port's: every receipt goes at once. It runs only in a delivery's second half, after the unit that stored the row, as
    /// a group open in a unit must keep it (phase P6).
    func acknowledge(_ envelope: RelayEnvelope, sender: NodeId) {
        if envelope.recipientId == nil {
            tickPost(envelope.id, author: sender, escalatable: envelope.group != nil)
        } else if sendSealedReceipt(for: envelope.id, to: sender) == .unsealed {
            sendReceipt(for: envelope.id)
        }
    }

    /// Our cleartext receipt for a DM (`InboundPipeline.ackCleartext`, `InboundPipeline.kt:2868-2890`): what an author who
    /// cannot read a sealed one gets, and every author with the ratchet's switch off, with `sentAt` set so every carrier
    /// derives the same expiry. It then purges the DM from our own custody, the way it purges it from every carrier's.
    func sendReceipt(for ackId: String) {
        let receipt = RelayEnvelope(
            type: .receipt,
            id: newFrameId(),
            senderId: nodeId.string,
            sentAt: clock.wallMilliseconds(),
            payload: ReceiptContent(ackId: ackId).encoded
        )
        originate(receipt)
        if custody.acknowledge(ackId, from: nodeId.string, in: stores.custody, now: clock.wallMilliseconds()) {
            noteCustodyChanged()
        }
    }

    // MARK: Key requests

    /// Wants `sender`'s key, and asks every neighbour for it unless we asked within the cooldown.
    func requestKey(_ sender: NodeId) {
        guard keyExchange.want(sender, me: nodeId, now: clock.monotonicMilliseconds()) else {
            return
        }
        sendKeyRequests(for: [sender], to: neighborIds)
    }

    /// Asks `peers` for every key still missing, cooldown or not.
    func askForMissingKeys(to peers: [NodeId]) {
        sendKeyRequests(for: keyExchange.missingIds, to: peers)
    }

    /// Signed, point-to-point key requests for `ids`, at most 128 each (`KeyExchange.keyRequest`), to each of `peers`.
    func sendKeyRequests(for ids: [NodeId], to peers: [NodeId]) {
        guard !peers.isEmpty else {
            return
        }
        for chunk in KeyExchange.chunked(ids) {
            let request = RelayEnvelope(
                type: .keyRequest,
                id: newFrameId(),
                senderId: nodeId.string,
                payload: KeyRequestContent(nodeIds: chunk.map(\.string)).encoded
            )
            if let wire = sign(request, relay: false) {
                for peer in peers {
                    transport.send(wire, to: peer)
                }
            }
        }
    }
}

/// A frame of ours, signed.
internal struct SignedFrame {
    var wire: WireEnvelope
    var envelope: RelayEnvelope
}
