import KnitCrypto
public import KnitStore
public import KnitWire

extension MeshEngine {
    // MARK: Messages we write

    /// Posts `text` to the Nearby room: stored, signed, flooded and carried (`MeshManager.sendChat`). A room post is
    /// cleartext and signed. Answers the stored message, or `nil` for a blank post.
    @discardableResult
    public func postToRoom(_ text: String) -> MessageRecord? {
        guard let body = Self.messageBody(text) else {
            return nil
        }
        let record = MessageRecord(
            id: newFrameId(),
            senderId: nodeId,
            recipientId: nil,
            conversationId: Conversations.nearby,
            body: body,
            sentAt: clock.wallMilliseconds()
        )
        stores.messages.save(record)
        originate(chatEnvelope(id: record.id, sentAt: record.sentAt, recipient: nil, group: nil, content: ChatContent(body: body)))
        return record
    }

    /// Sends `text` to `recipient` as a v1 DM (`MeshManager.sendChat`). With no key pinned for the recipient it is
    /// stored as pending and sealed once their profile arrives. Answers the stored message, or `nil` for a blank
    /// message or one to ourselves.
    @discardableResult
    public func sendDirectMessage(_ text: String, to recipient: NodeId) -> MessageRecord? {
        guard recipient != nodeId, let body = Self.messageBody(text) else {
            return nil
        }
        let id = newFrameId()
        let sentAt = clock.wallMilliseconds()
        let sealed = seal(body, id: id, sentAt: sentAt, to: recipient)
        let record = MessageRecord(
            id: id,
            senderId: nodeId,
            recipientId: recipient,
            conversationId: recipient.string,
            body: body,
            sentAt: sentAt,
            pendingKey: sealed == nil
        )
        stores.messages.save(record)
        if let sealed {
            originate(chatEnvelope(id: id, sentAt: sentAt, recipient: recipient, group: nil, content: ChatContent(enc: sealed)))
        }
        return record
    }

    /// Accepts a message request, so the thread is a chat and its messages notify.
    public func accept(_ conversationId: String) {
        stores.conversations.accept(conversationId)
    }

    /// The body we send: at most 2000 UTF-16 units, and `nil` when blank.
    static func messageBody(_ text: String) -> String? {
        let body = TextLimits.truncated(text, toUTF16: TextLimits.message)
        return TextLimits.isBlank(body) ? nil : body
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

    /// Seals `body` to `recipient`'s pinned key, or `nil` when none is pinned. v1 only: our capabilities never
    /// promise the ratchet, so Android seals v1 back (ADR 2026-09.qsd9).
    func seal(_ body: String, id: String, sentAt: Int64, to recipient: NodeId) -> EncEnvelope? {
        guard let peer = stores.peers.peer(recipient), let bundle = PublicKeyBundle(encoded: peer.publicKey) else {
            return nil
        }
        let header = MessageCrypto.header(id: id, senderId: nodeId.string, sentAt: sentAt, thread: recipient.string)
        return try? MessageCrypto.seal(MessageContent(body: body).encoded, header: header, to: [recipient: bundle])
    }

    /// Our messages that waited for `recipient`'s key, sealed and flooded under their original id and clock now that
    /// the key has pinned (`MeshManager.flushPendingFor`): DMs to them, and group messages in groups they are in.
    func flushPending(to recipient: NodeId) {
        for message in stores.messages.pendingKey(to: recipient) {
            if let sealed = seal(message.body, id: message.id, sentAt: message.sentAt, to: recipient) {
                originate(
                    chatEnvelope(
                        id: message.id, sentAt: message.sentAt, recipient: recipient, group: nil, content: ChatContent(enc: sealed)))
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
