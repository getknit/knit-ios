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
            handleChat(envelope, via: frame.from, signed: !frame.wire.sig.isEmpty, origin: .firstVerdict)
        case .profile:
            handleProfile(frame.wire, envelope)
        case .receipt:
            handleReceipt(envelope)
        case .keyRequest:
            handleKeyRequest(envelope, from: frame.from)
        case .groupUpdate:
            handleGroupUpdate(envelope, origin: .firstVerdict)
        case .groupLeave:
            handleGroupLeave(envelope, origin: .firstVerdict)
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
        guard !frame.wire.sig.isEmpty else {
            // The other unsigned shape (`InboundPipeline.kt:664-667`), with the ratchet on: the v3 live-link tick, judged
            // here by its shape alone. Its AEAD authenticates it, so nothing acts on it before it opens as a receipt, and
            // its sender's pinned key is still required above: the session that key names is what opens it.
            if configuration.ratchet, isUnsignedTickShape(frame) {
                return true
            }
            drop(.unsigned, envelope)
            return false
        }
        guard bundle.isValidSignature(frame.wire.sig, for: frame.wire.signed) else {
            drop(.badSignature, envelope)
            return false
        }
        return true
    }

    /// The one frame that may arrive unsigned, with the ratchet on (`isUnsignedTickShape`, `InboundPipeline.kt:592-598`,
    /// knit-next ADR 059): a `relay = false` chat in DM form, addressed to us by someone else. Whatever a flooded frame's
    /// signature protects is fixed by this shape or bound into the tick's AEAD (the id, sender, `sentAt`, recipient and
    /// ratchet header), so the shape and an open as a receipt are the whole check. It is never carried, since it is
    /// point to point, and never relayed, since it is ours.
    func isUnsignedTickShape(_ frame: InboundFrame) -> Bool {
        let envelope = frame.envelope
        let me = ExactKey(nodeId.string)
        return envelope.type == .chat && !frame.wire.relay && envelope.group == nil
            && envelope.recipientId.map(ExactKey.init) == me && ExactKey(envelope.senderId) != me
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
    /// group message (``handleGroupChat(_:group:sender:via:origin:)``). Someone else's DM is only relayed. `signed` is false only for
    /// the v3 live-link tick ``verify(_:)`` admitted unsigned: its AEAD is what authenticates it, so it takes no branch
    /// before its open. `origin` is the ratchet's alone: whether a DM-form frame's open is its first verdict, or the
    /// start's replay out of our own custody (``RatchetInbound/Origin``).
    func handleChat(_ envelope: RelayEnvelope, via hop: NodeId?, signed: Bool, origin: RatchetInbound.Origin) {
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
            handleGroupChat(envelope, group: group, sender: sender, via: hop, origin: origin)
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
        // The unsigned door's second half (`decryptAndDeliver`, `InboundPipeline.kt:933-941`): ahead of the clear branch
        // and the exists-gate, or anyone who overheard a DM's id on the air could make us acknowledge it.
        guard signed || RatchetInbound.admitsUnsigned(chat.enc) else {
            drop(.unsigned, envelope)
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
        receiveSealed(envelope, enc, sender: sender, route: RatchetInbound.Route(hop: hop, signed: signed, origin: origin))
    }

    /// A sealed chat that is no group's: a DM to us, or a sealed room post, which nothing opens (`decryptAndDeliver`,
    /// `InboundPipeline.kt:942-984`).
    private func receiveSealed(_ envelope: RelayEnvelope, _ enc: EncEnvelope, sender: NodeId, route: RatchetInbound.Route) {
        let recipient = envelope.recipientId.flatMap(NodeId.init)
        // Custody re-serves the same ciphertext routinely; once the row exists, only the receipt is owed. A signed frame's
        // only (`:950`): this gate never opens, so it is what lets the ratchet delete a spent key, and an unsigned frame
        // proves nothing until it opens.
        if route.signed, stores.messages.contains(envelope.id) {
            acknowledge(envelope, sender: sender)
            return
        }
        // With the ratchet's switch on, DM-form v2 and v3 frames to us open through it (`:966-971`); off, they drop in
        // `open` below as they always have (ADR 2026-10.5sk9).
        if configuration.ratchet, recipient == nodeId, RatchetInbound.isDirectRatchet(enc) {
            handleRatchetDirect(envelope, enc, sender: sender, route: route)
            return
        }
        // A control message is machinery: never shown, notified or acknowledged.
        guard let content = open(enc, envelope), content.ctl == nil else {
            return
        }
        deliverChat(envelope, Self.delivered(content), sender: sender, recipient: recipient, via: route.hop)
    }

    /// Opens a v1 envelope addressed to us (`InboundPipeline.decrypt`). Every v2 and v3 that reaches here is carried and
    /// relayed, and dropped here: all of them with the ratchet's switch off; with it on, a sealed room post, and a v3 group
    /// frame, refused as `RATCHET_BAD_HEADER` since v3 is the DM form by rule and its DM arm refuses one addressed to a group
    /// (`InboundPipeline.kt:966-971`, `:1017-1022`). A v2 group frame takes the group form's arm before this with the switch
    /// on (phase P6a2).
    func open(_ enc: EncEnvelope, _ envelope: RelayEnvelope) -> MessageContent? {
        guard enc.version == EncEnvelope.Version.staticKeys else {
            let toGroupAsV3 = configuration.ratchet && envelope.group != nil && enc.version == EncEnvelope.Version.compactRatchet
            drop(toGroupAsV3 ? .ratchetBadHeader : .cannotOpen, envelope)
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
