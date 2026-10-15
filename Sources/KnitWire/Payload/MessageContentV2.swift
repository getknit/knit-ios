/// The v3 sealed plaintext (`MessageContentV2` in knit-next's `mesh/crypto/MessageContentV2.kt`, knit-next ADR 059):
/// the facts of a ``MessageContent`` laid out for a size-capped radio. Integer keys replace the named ones, and every
/// id, hash and key travels as its raw bytes: a 22-character frame id as 16, a 26-character node id as 16, a 64-hex
/// hash as 32. A v3 ``EncEnvelope`` carries this layout and a v2 one the named layout; both decode to one
/// ``MessageContent``.
///
/// **Canonical or not at all** (`:31-39`). ``encode(_:)`` answers `nil` for content it cannot carry exactly, and the
/// seal site then takes the named layout under v2 (``MessageContent/sealBytes(v3:)``), so this codec never loses or
/// changes a frame. That covers an id, hash or key whose bytes do not re-encode to the same text, any
/// ``MessageContent/gk`` or ``MessageContent/xf``, and a ``MessageContent/version`` other than 1 (`:53-60`,
/// `:102-108`).
///
/// Decoding follows kotlinx's `compactCbor` (`Crypto.kt:111-119`): unknown labels are skipped, the reserved 12 (`pad`)
/// and 13 (`gk`) included (`:157-163`), and a text key reads as the property it names. Kotlin also repairs an
/// attachment's name at this boundary (`MessageContent.normalized()`, `MessageContent.kt:95-99`). This port's named
/// decoder does not, so neither does this one: the two decoders agree, and delivery clips the name.
public enum MessageContentV2 {
    /// The compact layout's version this build writes, label 0, never written while it is the default (`VERSION`, `:47`).
    public static let version = 1
    /// The highest compact layout version this build reads; a higher one decodes to nothing (`MAX_SUPPORTED`, `:50`).
    public static let maxSupportedVersion = 1

    /// `content` in the compact layout, or `nil` when part of it has no canonical raw form (`encodeOrNull`, `:53-60`).
    public static func encode(_ content: MessageContent) -> [UInt8]? {
        guard content.version == MessageContent.currentVersion, content.gk == nil, content.xf == nil,
            let wire = try? Wire(content)
        else {
            return nil
        }
        return wire.cbor.encoded
    }

    /// The content in compact `bytes`, or `nil` when they are malformed, hold an id, hash or node id of the wrong width,
    /// or come from a newer compact layout (`decode`, `:110-150`).
    public static func decode(_ bytes: [UInt8]) -> MessageContent? {
        guard let item = try? CBOR.decode(bytes), let wire = try? Wire(cbor: item), wire.version <= maxSupportedVersion else {
            return nil
        }
        return try? wire.content()
    }
}

/// What a DM-form seal site hands the ratchet (`SealBytes`, `MessageContentV2.kt:255-263`): the plaintext, and the
/// ``EncEnvelope/Version`` it is laid out for.
public struct SealBytes: Sendable, Equatable {
    /// The plaintext to seal.
    public let plaintext: [UInt8]
    /// ``EncEnvelope/Version/compactRatchet`` for the compact layout, ``EncEnvelope/Version/ratchet`` for the named one.
    public let scheme: Int
}

extension MessageContent {
    /// The bytes to seal this content under toward a peer, and their scheme (`sealBytes`, `MessageContentV2.kt:265-274`):
    /// the compact v3 layout when the peer reads it (`v3`) and the content has a canonical compact form, else the named
    /// layout under v2. A seal site picks v3 only through this, so content the compact codec refuses falls back rather
    /// than being lost.
    public func sealBytes(v3: Bool) -> SealBytes {
        if v3, let compact = MessageContentV2.encode(self) {
            return SealBytes(plaintext: compact, scheme: EncEnvelope.Version.compactRatchet)
        }
        return SealBytes(plaintext: encoded, scheme: EncEnvelope.Version.ratchet)
    }
}

/// The top-level labels (`Wire`, `MessageContentV2.kt:169-200`). Append-only, and 12 and 13 stay reserved.
private enum WireLabel: UInt64, CBORLabel {
    // swiftlint:disable:next identifier_name - the Kotlin property's name, which kotlinx also reads as this key
    case v = 0
    case body = 1
    case mentions = 2
    case attachmentHash = 3
    case attachmentMime = 4
    case attachmentKey = 5
    case replyTo = 6
    case ctl = 7
    case ack = 8
    case acks = 9
    case rp = 10
    case pr = 11
    case attachmentName = 14
    case attachmentSize = 15
}

/// `MentionV2`'s labels (`:202-209`).
private enum MentionLabel: UInt64, CBORLabel {
    case nodeId = 1
    case name = 2
}

/// `ReplyRefV2`'s labels (`:211-224`).
private enum ReplyLabel: UInt64, CBORLabel {
    case messageId = 1
    case authorId = 2
    case author = 3
    case snippet = 4
    case hasAttachment = 5
}

/// `ReactionV2`'s labels (`:226-233`).
private enum ReactionLabel: UInt64, CBORLabel {
    case messageId = 1
    case emoji = 2
}

/// `ProfileV2`'s labels (`:235-252`).
private enum ProfileLabel: UInt64, CBORLabel {
    case name = 1
    case status = 2
    case avatarHash = 3
    case version = 4
    case openToChat = 5
    case loraNode = 6
    case loraKey = 7
}

/// The top-level layout (`Wire`, `:169-200`): every field defaulted, so an empty map is an empty message.
private struct Wire: CBORRepresentable {
    var version = MessageContentV2.version
    var body = ""
    var mentions: [MentionV2] = []
    var attachmentHash: [UInt8]?
    var attachmentMime: String?
    var attachmentKey: [UInt8]?
    var replyTo: ReplyRefV2?
    var ctl: Int?
    var ack: [UInt8]?
    var acks: [[UInt8]]?
    var rp: ReactionV2?
    var pr: ProfileV2?
    var attachmentName: String?
    var attachmentSize: Int64?

    /// `content`'s compact form (`wireOf`, `:65-91`).
    init(_ content: MessageContent) throws(NonCanonical) {
        body = content.body
        mentions = try content.mentions.map { mention throws(NonCanonical) in try MentionV2(mention) }
        attachmentHash = try content.attachmentHash.map(CanonicalText.hashBytes)
        attachmentMime = content.attachmentMime
        attachmentKey = try content.attachmentKey.map(CanonicalText.keyBytes)
        attachmentName = content.attachmentName
        attachmentSize = content.attachmentSize
        replyTo = try content.replyTo.map { reply throws(NonCanonical) in try ReplyRefV2(reply) }
        ctl = content.ctl
        ack = try content.ack.map(CanonicalText.frameIdBytes)
        acks = try content.acks.map { ids throws(NonCanonical) in try ids.map(CanonicalText.frameIdBytes) }
        rp = try content.rp.map { reaction throws(NonCanonical) in try ReactionV2(reaction) }
        pr = try content.pr.map { profile throws(NonCanonical) in try ProfileV2(profile) }
    }

    init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORLabeledFields<WireLabel>(cbor, type: "MessageContentV2")
        version = try fields.optional(.v, .int32) ?? MessageContentV2.version
        body = try fields.optional(.body, .text) ?? ""
        mentions = try fields.optional(.mentions, .list(of: MentionV2.self)) ?? []
        attachmentHash = try fields.nullable(.attachmentHash, .bytes)
        attachmentMime = try fields.nullable(.attachmentMime, .text)
        attachmentKey = try fields.nullable(.attachmentKey, .bytes)
        replyTo = try fields.nullable(.replyTo, .object(ReplyRefV2.self))
        ctl = try fields.nullable(.ctl, .int32)
        ack = try fields.nullable(.ack, .bytes)
        acks = try fields.nullable(.acks, .byteStrings)
        rp = try fields.nullable(.rp, .object(ReactionV2.self))
        pr = try fields.nullable(.pr, .object(ProfileV2.self))
        attachmentName = try fields.nullable(.attachmentName, .text)
        attachmentSize = try fields.nullable(.attachmentSize, .int64)
    }

    /// The layout as kotlinx writes it: labels in declaration order, defaults left out. Label 0 never appears, because
    /// ``MessageContentV2/encode(_:)`` refuses every version but the default.
    var cbor: CBOR {
        var writer = CBORLabeledWriter<WireLabel>()
        if !body.isEmpty {
            writer.item(.body, .text(body))
        }
        if !mentions.isEmpty {
            writer.item(.mentions, .array(mentions.map(\.cbor)))
        }
        writer.item(.attachmentHash, optional: attachmentHash.map(CBOR.bytes))
        writer.item(.attachmentMime, optional: attachmentMime.map(CBOR.text))
        writer.item(.attachmentKey, optional: attachmentKey.map(CBOR.bytes))
        writer.item(.replyTo, optional: replyTo?.cbor)
        writer.item(.ctl, optional: ctl.map { CBOR(Int64($0)) })
        writer.item(.ack, optional: ack.map(CBOR.bytes))
        writer.item(.acks, optional: acks.map { .array($0.map(CBOR.bytes)) })
        writer.item(.rp, optional: rp?.cbor)
        writer.item(.pr, optional: pr?.cbor)
        writer.item(.attachmentName, optional: attachmentName.map(CBOR.text))
        writer.item(.attachmentSize, optional: attachmentSize.map { CBOR($0) })
        return writer.cbor
    }

    /// The domain content, every raw id, hash and node id back to its text at its exact width (`decode`, `:110-150`).
    func content() throws(NonCanonical) -> MessageContent {
        MessageContent(
            body: body,
            mentions: try mentions.map { mention throws(NonCanonical) in try mention.domain() },
            attachmentHash: try attachmentHash.map(CanonicalText.hashText),
            attachmentMime: attachmentMime,
            attachmentKey: attachmentKey.map(CanonicalText.keyText),
            attachmentName: attachmentName,
            attachmentSize: attachmentSize,
            replyTo: try replyTo?.domain(),
            ctl: ctl,
            ack: try ack.map(CanonicalText.frameIdText),
            rp: try rp?.domain(),
            pr: try pr?.domain(),
            acks: try acks.map { ids throws(NonCanonical) in try ids.map(CanonicalText.frameIdText) }
        )
    }
}

/// A mention, its node id raw (`MentionV2`, `:202-209`).
private struct MentionV2: CBORRepresentable {
    var nodeId: [UInt8]
    var name: String

    init(_ mention: Mention) throws(NonCanonical) {
        nodeId = try CanonicalText.nodeIdBytes(mention.nodeId)
        name = mention.name
    }

    init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORLabeledFields<MentionLabel>(cbor, type: "MentionV2")
        nodeId = try fields.required(.nodeId, .bytes)
        name = try fields.required(.name, .text)
    }

    var cbor: CBOR {
        var writer = CBORLabeledWriter<MentionLabel>()
        writer.item(.nodeId, .bytes(nodeId))
        writer.item(.name, .text(name))
        return writer.cbor
    }

    func domain() throws(NonCanonical) -> Mention {
        Mention(nodeId: try CanonicalText.nodeIdText(nodeId), name: name)
    }
}

/// A quoted reply's reference, its ids raw (`ReplyRefV2`, `:211-224`).
private struct ReplyRefV2: CBORRepresentable {
    var messageId: [UInt8]
    var authorId: [UInt8]
    var author: String
    var snippet: String
    var hasAttachment: Bool

    init(_ reply: ReplyRef) throws(NonCanonical) {
        messageId = try CanonicalText.frameIdBytes(reply.messageId)
        authorId = try CanonicalText.nodeIdBytes(reply.authorId)
        author = reply.author
        snippet = reply.snippet
        hasAttachment = reply.hasAttachment
    }

    init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORLabeledFields<ReplyLabel>(cbor, type: "ReplyRefV2")
        messageId = try fields.required(.messageId, .bytes)
        authorId = try fields.required(.authorId, .bytes)
        author = try fields.required(.author, .text)
        snippet = try fields.required(.snippet, .text)
        hasAttachment = try fields.optional(.hasAttachment, .bool) ?? false
    }

    var cbor: CBOR {
        var writer = CBORLabeledWriter<ReplyLabel>()
        writer.item(.messageId, .bytes(messageId))
        writer.item(.authorId, .bytes(authorId))
        writer.item(.author, .text(author))
        writer.item(.snippet, .text(snippet))
        if hasAttachment {
            writer.item(.hasAttachment, .bool(true))
        }
        return writer.cbor
    }

    func domain() throws(NonCanonical) -> ReplyRef {
        ReplyRef(
            messageId: try CanonicalText.frameIdText(messageId),
            authorId: try CanonicalText.nodeIdText(authorId),
            author: author,
            snippet: snippet,
            hasAttachment: hasAttachment
        )
    }
}

/// A sealed reaction, its frame id raw (`ReactionV2`, `:226-233`).
private struct ReactionV2: CBORRepresentable {
    var messageId: [UInt8]
    var emoji: String?

    init(_ reaction: ReactionContent) throws(NonCanonical) {
        messageId = try CanonicalText.frameIdBytes(reaction.messageId)
        emoji = reaction.emoji
    }

    init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORLabeledFields<ReactionLabel>(cbor, type: "ReactionV2")
        messageId = try fields.required(.messageId, .bytes)
        emoji = try fields.nullable(.emoji, .text)
    }

    var cbor: CBOR {
        var writer = CBORLabeledWriter<ReactionLabel>()
        writer.item(.messageId, .bytes(messageId))
        writer.item(.emoji, optional: emoji.map(CBOR.text))
        return writer.cbor
    }

    func domain() throws(NonCanonical) -> ReactionContent {
        ReactionContent(messageId: try CanonicalText.frameIdText(messageId), emoji: emoji)
    }
}

/// A sealed profile update, its hash and board key raw (`ProfileV2`, `:235-252`).
private struct ProfileV2: CBORRepresentable {
    var name: String
    var status: String
    var avatarHash: [UInt8]?
    var version: Int64
    var openToChat: Bool
    var loraNode: Int64?
    var loraKey: [UInt8]?

    init(_ profile: ProfilePayload) throws(NonCanonical) {
        name = profile.name
        status = profile.status
        avatarHash = try profile.avatarHash.map(CanonicalText.hashBytes)
        version = profile.version
        openToChat = profile.openToChat
        loraNode = profile.loraNode
        // Kotlin reads this one with `b64d` (`:88`), which neither checks it round-trips nor catches a malformed key.
        // This port refuses both here, as it refuses every other key, so the content takes the named layout instead.
        loraKey = try profile.loraKey.map(CanonicalText.keyBytes)
    }

    init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORLabeledFields<ProfileLabel>(cbor, type: "ProfileV2")
        name = try fields.required(.name, .text)
        status = try fields.required(.status, .text)
        avatarHash = try fields.nullable(.avatarHash, .bytes)
        version = try fields.optional(.version, .int64) ?? 0
        openToChat = try fields.optional(.openToChat, .bool) ?? false
        loraNode = try fields.nullable(.loraNode, .int64)
        loraKey = try fields.nullable(.loraKey, .bytes)
    }

    var cbor: CBOR {
        var writer = CBORLabeledWriter<ProfileLabel>()
        writer.item(.name, .text(name))
        writer.item(.status, .text(status))
        writer.item(.avatarHash, optional: avatarHash.map(CBOR.bytes))
        if version != 0 {
            writer.item(.version, CBOR(version))
        }
        if openToChat {
            writer.item(.openToChat, .bool(true))
        }
        writer.item(.loraNode, optional: loraNode.map { CBOR($0) })
        writer.item(.loraKey, optional: loraKey.map(CBOR.bytes))
        return writer.cbor
    }

    func domain() throws(NonCanonical) -> ProfilePayload {
        ProfilePayload(
            name: name,
            status: status,
            avatarHash: try avatarHash.map(CanonicalText.hashText),
            version: version,
            openToChat: openToChat,
            loraNode: loraNode,
            loraKey: loraKey.map(CanonicalText.keyText)
        )
    }
}
