import KnitCrypto
import KnitStore
import KnitWire

extension MeshEngine {
    /// Frame types whose missing key is never requested (`NO_KEY_REQUEST_TYPES`): a key request itself, a profile
    /// (its key is in-band, so a missing one is malformed), a typing cue, worthless a moment later, and a commons
    /// post, which never arrives by radio on purpose.
    static let noKeyRequestTypes: Set<FrameType> = [.keyRequest, .profile, .typing, .commons]

    /// Delivers one first-seen frame (`InboundPipeline.onDeliver`): verify it, carry it, then hand it to its
    /// type's handler. A frame that fails verification is not carried or shown, and the router still relays it.
    func deliver(_ frame: InboundFrame) {
        guard verify(frame) else {
            return
        }
        let envelope = frame.envelope
        // The custody entry rule (InboundPipeline.kt:236). A profile is carried even point to point, the way a
        // key request serves it, or the requester would pin the key and hold nothing (ADR 2026-09.7bu7).
        if envelope.type.isCustodial, frame.wire.relay || envelope.type == .profile {
            let carried = CarriedFrame(envelope: envelope, sig: frame.wire.sig, signed: frame.wire.signed)
            let now = clock.wallMilliseconds()
            if custody.carry(carried, in: stores.custody, now: now, authenticate: { isCarriable(envelope) }) {
                noteCustodyChanged()
            }
        }
        switch envelope.type {
        case .chat:
            handleChat(envelope, via: frame.from)
        case .profile:
            handleProfile(frame.wire, envelope)
        case .receipt:
            handleReceipt(envelope)
        case .keyRequest:
            handleKeyRequest(envelope, from: frame.from)
        case .groupUpdate:
            handleGroupUpdate(envelope)
        case .groupLeave:
            handleGroupLeave(envelope)
        case .blobRequest:
            handleBlobRequest(frame)
        case .blobHave:
            handleBlobHave(frame)
        case .blobHas:
            handleBlobHas(frame)
        case .blobProgress:
            handleBlobProgress(frame)
        case .blobCancel:
            handleBlobCancel(frame)
        case .reaction:
            handleReaction(envelope)
        case .typing:
            handleTyping(envelope)
        default:
            // Types this build has never heard of are carried and relayed where custodial, and shown nowhere.
            break
        }
    }

    /// Authenticates a frame (`InboundPipeline.verifyInbound`): its signature must verify, over the bytes as
    /// received, against a key that derives to its sender. A frame from a sender whose key is missing asks for it
    /// and is parked, so it lands once the key pins.
    func verify(_ frame: InboundFrame) -> Bool {
        let envelope = frame.envelope
        if envelope.type.isUnsignedPointToPoint {
            // The blob traffic is unsigned by design (`InboundPipeline.verifyInbound`, `InboundPipeline.kt:587`):
            // nothing in it is trusted but its hashes, and only to look up what we hold, so it never asks for a key.
            return true
        }
        guard let bundle = verifierBundle(for: envelope) else {
            drop(.noSenderKey, envelope)
            if !Self.noKeyRequestTypes.contains(envelope.type), let sender = NodeId(envelope.senderId) {
                requestKey(sender)
                if envelope.type.isReplayable {
                    _ = pendingInbound.hold(frame, now: clock.monotonicMilliseconds())
                }
            }
            return false
        }
        guard NodeId(envelope.senderId) == bundle.nodeId else {
            drop(.keyMismatch, envelope)
            return false
        }
        // The only other unsigned shape is the v3 live-link tick, which only the ratchet can open.
        guard !frame.wire.sig.isEmpty else {
            drop(.unsigned, envelope)
            return false
        }
        guard bundle.isValidSignature(frame.wire.sig, for: frame.wire.signed) else {
            drop(.badSignature, envelope)
            return false
        }
        return true
    }

    /// The key a frame must verify against (`InboundPipeline.verifierBundle`): ours for our own frame coming back,
    /// the in-band key for a profile, and the sender's pinned key for everything else.
    func verifierBundle(for envelope: RelayEnvelope) -> PublicKeyBundle? {
        let sender = NodeId(envelope.senderId)
        if sender == nodeId {
            return identity.bundle
        }
        if envelope.type == .profile {
            return (try? ProfileContent(decoding: envelope.payload))?.pubKey.flatMap(PublicKeyBundle.init(encoded:))
        }
        guard let sender, let peer = stores.peers.peer(sender) else {
            return nil
        }
        return PublicKeyBundle(encoded: peer.publicKey)
    }

    /// Whether a verified frame may be carried (`InboundPipeline.canCarry`): a DM travels only sealed, so a
    /// carrier holds it without reading it. The signature was checked by ``verify(_:)``.
    func isCarriable(_ envelope: RelayEnvelope) -> Bool {
        guard envelope.type == .chat else {
            return true
        }
        guard let chat = try? ChatContent(decoding: envelope.payload) else {
            return false
        }
        return envelope.isRoomPost || chat.enc != nil
    }

    /// A chat frame (`InboundPipeline.handleChat` and `decryptAndDeliver`): a room post, a DM addressed to us, or a
    /// group message (``handleGroupChat(_:group:sender:)``). Someone else's DM is only relayed.
    func handleChat(_ envelope: RelayEnvelope, via hop: NodeId?) {
        guard let sender = NodeId(envelope.senderId) else {
            return
        }
        // A block stops delivery here and nothing else: the frame was carried above and the router relays it, and a
        // parked or replayed frame comes through this door too (`InboundPipeline.handleChat:662-676`, ADR 2026-10.5wgg).
        if isBlocked(sender) {
            dropBlocked(envelope, sender: sender)
            return
        }
        // A group message names no recipient, so it is told apart before the DM check would take it for the room.
        if let group = envelope.group {
            handleGroupChat(envelope, group: group, sender: sender, via: hop)
            return
        }
        let recipient = envelope.recipientId.flatMap(NodeId.init)
        if envelope.recipientId != nil {
            // A DM from us to us is the residue of the self-pin knit-next once had; nothing sends one on purpose.
            guard recipient == nodeId, sender != nodeId else {
                return
            }
        }
        guard let chat = try? ChatContent(decoding: envelope.payload) else {
            drop(.undecodable, envelope)
            return
        }
        guard let enc = chat.enc else {
            guard recipient == nil else {
                // Android always seals a DM; one in the clear would read as private and is not.
                drop(.cleartextDirect, envelope)
                return
            }
            deliverChat(envelope, Self.delivered(chat), sender: sender, recipient: nil, via: hop)
            return
        }
        // Custody re-serves the same ciphertext routinely; once the row exists, only the receipt is owed.
        if stores.messages.contains(envelope.id) {
            acknowledge(envelope, sender: sender)
            return
        }
        // A control message is machinery: never shown, notified or acknowledged.
        guard let content = open(enc, envelope), content.ctl == nil else {
            return
        }
        deliverChat(envelope, Self.delivered(content), sender: sender, recipient: recipient, via: hop)
    }

    /// Opens a v1 envelope addressed to us (`InboundPipeline.decrypt`). Versions 2 and 3 need the ratchet: they are
    /// carried and relayed, and dropped here.
    func open(_ enc: EncEnvelope, _ envelope: RelayEnvelope) -> MessageContent? {
        guard enc.version == EncEnvelope.Version.staticKeys else {
            drop(.cannotOpen, envelope)
            return nil
        }
        let thread = envelope.group?.id ?? envelope.recipientId ?? ""
        let header = MessageCrypto.header(id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: thread)
        guard let content = MessageCrypto.open(enc, header: header, as: identity), content.version <= MessageContent.currentVersion else {
            drop(.cannotOpen, envelope)
            return nil
        }
        return content
    }

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
        // A group's thread is the group; a DM's and the room's follow from who sent it to whom.
        let conversation = envelope.group?.id ?? Conversations.id(sender: sender, recipient: recipient, me: nodeId)
        let attachment = delivered.attachment
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
            attachment: attachment,
            moderation: sender == nodeId || wordless ? .clear : .waiting,
            replyTo: delivered.replyTo,
            // Only the mentions the kept body still holds: that bounds a peer's list, where Android keeps any
            // (`InboundPipeline.kt:2660`, ADR 2026-10.nbhj).
            mentions: MessageMention.carried(delivered.mentions, in: body)
        )
        stores.messages.insertIfAbsent(record)
        // Every delivery ends the sender's cue in the thread, a re-delivery too (`InboundPipeline.kt:2728`), and before
        // the message is announced, so no screen shows both.
        clearTyping(sender, in: conversation)
        if isNew, sender != nodeId {
            events.append(.received(record, isRequest: !isAccepted(conversation)))
        }
        if let attachment {
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

    /// The longest text an attachment's type, key or file name keeps: a peer's frame bounds nothing on its own.
    static let attachmentTextLimit = 256

    /// What a room post says, carries, quotes and mentions, from its cleartext.
    static func delivered(_ chat: ChatContent) -> DeliveredChat {
        DeliveredChat(
            body: chat.body,
            attachment: attachment(of: chat),
            replyTo: chat.replyTo.map(reply),
            mentions: chat.mentions.map(mention)
        )
    }

    /// What a sealed message says, carries, quotes and mentions, from its opened content. A quote or a mention beside the
    /// envelope in the clear is no part of it (`InboundPipeline.plaintextContent`, `InboundPipeline.kt:948-960`).
    static func delivered(_ content: MessageContent) -> DeliveredChat {
        DeliveredChat(
            body: content.body,
            attachment: attachment(of: content),
            replyTo: content.replyTo.map(reply),
            mentions: content.mentions.map(mention)
        )
    }

    /// A mention as its sender wrote it. ``deliverChat(_:_:sender:recipient:via:)`` keeps it only while the body holds
    /// its token, which bounds the name by the body's own limit.
    static func mention(_ mention: Mention) -> MessageMention {
        MessageMention(nodeId: mention.nodeId, name: mention.name)
    }

    /// The quote a delivered message carries, as the replier wrote it: nothing checks that the message it names is held,
    /// or is in this thread, as nothing does on Android (`InboundPipeline.deliverChat`). Only the name and the words are
    /// clipped, which a peer's frame bounds no more than an attachment's text.
    static func reply(_ ref: ReplyRef) -> MessageReply {
        MessageReply(
            messageId: ref.messageId,
            authorId: ref.authorId,
            author: TextLimits.truncated(ref.author, toUTF16: attachmentTextLimit),
            snippet: TextLimits.truncated(ref.snippet, toUTF16: attachmentTextLimit),
            hasAttachment: ref.hasAttachment
        )
    }

    /// What a room post carries: its photo's hash and type, from the cleartext. A hash that is not 64 lowercase hex
    /// digits names no blob, so the post carries nothing.
    static func attachment(of chat: ChatContent) -> MessageAttachment? {
        chat.attachmentHash.flatMap { BlobHash($0) }.map { MessageAttachment(hash: $0, mime: clipped(chat.attachmentMime)) }
    }

    /// What a sealed message carries, from its opened content: the ciphertext's hash, the type, the key that opens it,
    /// and a file's name and size. The cleartext beside the envelope repeats only the hash, and the sealed one wins.
    static func attachment(of content: MessageContent) -> MessageAttachment? {
        content.attachmentHash.flatMap { BlobHash($0) }.map { hash in
            MessageAttachment(
                hash: hash,
                mime: clipped(content.attachmentMime),
                key: clipped(content.attachmentKey),
                name: clipped(content.attachmentName),
                size: content.attachmentSize
            )
        }
    }

    private static func clipped(_ text: String?) -> String? {
        text.map { TextLimits.truncated($0, toUTF16: attachmentTextLimit) }
    }

    /// Whether a conversation is accepted rather than a message request (`InboundPipeline.isAccepted`). A group is
    /// also accepted once someone we know writes in it.
    func isAccepted(_ conversation: String) -> Bool {
        Conversations.isAccepted(
            conversation,
            accepted: stores.conversations.acceptedConversations(),
            verified: stores.peers.verifiedNodeIds(),
            authored: stores.messages.conversations(authoredBy: nodeId),
            groupSenders: Conversations.isGroup(conversation) ? stores.messages.senders(in: conversation) : []
        )
    }

    /// A delivery receipt (`InboundPipeline.handleReceipt`). It flips ✓✓ on one of our messages only if it is a room
    /// post or a group message, which any signed member's tick flips, or the receipt comes from the DM's recipient:
    /// the forged-ack guard. The custody purge applies the same guard on its own.
    func handleReceipt(_ envelope: RelayEnvelope) {
        guard let receipt = try? ReceiptContent(decoding: envelope.payload) else {
            drop(.undecodable, envelope)
            return
        }
        if isOurs(receipt.ackId, acknowledgedBy: envelope.senderId), stores.messages.markDelivered(receipt.ackId) {
            events.append(.delivered(messageId: receipt.ackId))
        }
        if custody.acknowledge(receipt.ackId, from: envelope.senderId, in: stores.custody, now: clock.wallMilliseconds()) {
            noteCustodyChanged()
        }
    }

    /// Whether `ackId` is one of our messages that `sender` may acknowledge: any room post or group message of ours,
    /// or a DM of ours addressed to `sender`. A status line is no message, so nothing ticks one.
    func isOurs(_ ackId: String, acknowledgedBy sender: String) -> Bool {
        guard let message = stores.messages.message(ackId), message.senderId == nodeId, message.kind == .message else {
            return false
        }
        return message.recipientId == nil || message.recipientId == NodeId(sender)
    }

    /// A neighbour asked for keys (`KeyExchange.onRequest`): serve what we hold, and ask on its behalf for the rest.
    func handleKeyRequest(_ envelope: RelayEnvelope, from neighbor: NodeId) {
        guard let request = try? KeyRequestContent(decoding: envelope.payload) else {
            drop(.undecodable, envelope)
            return
        }
        let answer = keyExchange.onRequest(request.nodeIds, from: neighbor, me: nodeId, now: clock.monotonicMilliseconds())
        for wire in answer.serve {
            transport.send(wire, to: neighbor)
        }
        sendKeyRequests(for: answer.ask, to: neighborIds)
    }
}

/// What a message delivered to us says and carries.
internal struct DeliveredChat {
    /// Its text.
    var body: String
    /// Its photo or file, or `nil`.
    var attachment: MessageAttachment?
    /// The message it replies to, as its author quoted it, or `nil`.
    var replyTo: MessageReply?
    /// The people it mentions, as its author named them, before ``MessageMention/carried(_:in:)`` keeps those the body
    /// holds.
    var mentions: [MessageMention]
}
