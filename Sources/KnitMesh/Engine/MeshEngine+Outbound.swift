import KnitCrypto
public import KnitStore
public import KnitWire

extension MeshEngine {
    // MARK: Messages we write

    /// Posts `text` to the Nearby room, with `photo` if one is given: stored, signed, flooded and carried
    /// (`MeshManager.sendChat`). A room post is cleartext and signed, and so is its photo, kept under its own hash for
    /// anyone who asks. Answers the stored message, or `nil` for a blank post with no photo, or a photo too heavy to
    /// send.
    @discardableResult
    public func postToRoom(_ text: String, photo: OutgoingPhoto? = nil) -> MessageRecord? {
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
            attachment: attachment
        )
        stores.messages.save(record)
        let content = ChatContent(body: body, attachmentHash: attachment?.hash.string, attachmentMime: attachment?.mime)
        originate(chatEnvelope(id: record.id, sentAt: sentAt, recipient: nil, group: nil, content: content))
        return record
    }

    /// Sends `text` to `recipient` as a v1 DM, with `photo` sealed beside it if one is given (`MeshManager.sendChat`).
    /// With no key pinned for the recipient it is stored as pending and sealed once their profile arrives. Answers the
    /// stored message, or `nil` for a blank message with no photo, a photo too heavy to send, or a message to
    /// ourselves.
    @discardableResult
    public func sendDirectMessage(_ text: String, to recipient: NodeId, photo: OutgoingPhoto? = nil) -> MessageRecord? {
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
            attachment: attachment
        )
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

    /// Keeps a room post's photo as it is, under its own hash, and answers what the message carries.
    func keepPhoto(_ photo: OutgoingPhoto, at now: Int64) -> MessageAttachment {
        let hash = BlobHash(of: photo.bytes)
        stores.blobs.insert(photo.bytes, hash: hash, mime: photo.mime, storedAt: now)
        return MessageAttachment(hash: hash, mime: photo.mime)
    }

    /// What a DM or a group message carries: nothing without a photo, or `photo` sealed and kept (``sealPhoto(_:at:)``).
    /// The outer `nil` is a photo that would not seal, which a send's `guard` stops at.
    func sealing(_ photo: OutgoingPhoto?, at now: Int64) -> MessageAttachment?? {
        guard let photo else {
            return .some(nil)
        }
        return sealPhoto(photo, at: now).map(Optional.some)
    }

    /// Seals a DM's or a group message's photo under a fresh key (`MeshManager.sealAttachment`), keeps the ciphertext
    /// under its own hash, and answers what the message carries: the ciphertext's hash, the type and the key, which
    /// travel sealed. `nil` only if sealing fails.
    func sealPhoto(_ photo: OutgoingPhoto, at now: Int64) -> MessageAttachment? {
        AttachmentCrypto.seal(photo.bytes).map { sealed in
            let hash = BlobHash(of: sealed.blob)
            stores.blobs.insert(sealed.blob, hash: hash, mime: photo.mime, storedAt: now)
            return MessageAttachment(hash: hash, mime: photo.mime, key: Base64.encode(sealed.key))
        }
    }

    /// The sealed content of one of our messages: its body, and its attachment's hash, type, key, and a file's name and
    /// size.
    static func content(of message: MessageRecord) -> MessageContent {
        let attachment = message.attachment
        return MessageContent(
            body: message.body,
            attachmentHash: attachment?.hash.string,
            attachmentMime: attachment?.mime,
            attachmentKey: attachment?.key,
            attachmentName: attachment?.name,
            attachmentSize: attachment?.size
        )
    }

    /// The chat frame's content for a sealed message: the envelope, and beside it in the clear only the ciphertext's
    /// hash, so a carrier blind to the sealed fields can still pull the blob. The type and the key stay sealed
    /// (`MeshManager.kt:1112-1128`).
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

    /// Seals `content` to `recipient`'s pinned key, or `nil` when none is pinned. v1 only: our capabilities never
    /// promise the ratchet, so Android seals v1 back (ADR 2026-09.qsd9).
    func seal(_ content: MessageContent, id: String, sentAt: Int64, to recipient: NodeId) -> EncEnvelope? {
        guard let peer = stores.peers.peer(recipient), let bundle = PublicKeyBundle(encoded: peer.publicKey) else {
            return nil
        }
        let header = MessageCrypto.header(id: id, senderId: nodeId.string, sentAt: sentAt, thread: recipient.string)
        return try? MessageCrypto.seal(content.encoded, header: header, to: [recipient: bundle])
    }

    /// Our messages that waited for `recipient`'s key, sealed and flooded under their original id and clock now that
    /// the key has pinned (`MeshManager.flushPendingFor`): DMs to them, and group messages in groups they are in. A DM
    /// to someone blocked waits on, as on Android, until an unblock and their next profile.
    func flushPending(to recipient: NodeId) {
        let waiting = isBlocked(recipient) ? [] : stores.messages.pendingKey(to: recipient)
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
        flushPendingGroups(for: recipient)
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

    /// Acknowledges a message delivered to us (`InboundPipeline.acknowledge`): a DM earns a receipt that floods
    /// and is carried, a room post or a group message a tick owed to its author.
    func acknowledge(_ envelope: RelayEnvelope, sender: NodeId) {
        if envelope.recipientId == nil {
            tickRoomPost(envelope.id, author: sender)
        } else {
            sendReceipt(for: envelope.id)
        }
    }

    /// Our receipt for a DM (`InboundPipeline.ackCleartext`): cleartext, since this build cannot seal one, with
    /// `sentAt` set so every carrier derives the same expiry. It then purges the DM from our own custody, the way it
    /// purges it from every carrier's.
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

    /// Owes the author of room post `id` a tick, and sends it now if the author is linked.
    func tickRoomPost(_ id: String, author: NodeId) {
        let now = clock.monotonicMilliseconds()
        guard ackSync.owe(id, author: author, me: nodeId, authorLinked: transport.isLinked(author), now: now) else {
            return
        }
        sendTick(for: id, to: author)
    }

    /// Sends every tick owed to `peer`, now that it is linked.
    func sendOwedTicks(to peer: NodeId) {
        for id in ackSync.linked(to: peer, now: clock.monotonicMilliseconds()) {
            sendTick(for: id, to: peer)
        }
    }

    /// A room tick (`AckSync.receipt`): signed, point to point, no `sentAt`, and a fresh id every time, so the
    /// author's seen set never swallows a retry.
    func sendTick(for ackId: String, to author: NodeId) {
        let tick = RelayEnvelope(type: .receipt, id: newFrameId(), senderId: nodeId.string, payload: ReceiptContent(ackId: ackId).encoded)
        if let wire = sign(tick, relay: false) {
            transport.send(wire, to: author)
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
