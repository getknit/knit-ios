/// A chat frame's payload (`ChatContent` in knit-next's `Wire.kt`).
///
/// A Nearby room post carries its text in the clear here. A DM or group message leaves ``body`` and
/// ``mentions`` empty and carries everything inside ``enc``.
public struct ChatContent: CBORRepresentable, Equatable {
    /// The message text, for a room post.
    public var body: String
    /// The people a room post mentions.
    public var mentions: [Mention]
    /// A room post's attachment hash.
    public var attachmentHash: String?
    /// A room post's attachment type.
    public var attachmentMime: String?
    /// The sealed content of a DM or group message.
    public var enc: EncEnvelope?
    /// A room post's quoted reply; a sealed message carries its quote inside ``enc``.
    public var replyTo: ReplyRef?

    /// Makes chat content; the defaults are an empty room post.
    public init(
        body: String = "",
        mentions: [Mention] = [],
        attachmentHash: String? = nil,
        attachmentMime: String? = nil,
        enc: EncEnvelope? = nil,
        replyTo: ReplyRef? = nil
    ) {
        self.body = body
        self.mentions = mentions
        self.attachmentHash = attachmentHash
        self.attachmentMime = attachmentMime
        self.enc = enc
        self.replyTo = replyTo
    }

    /// Reads chat content from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "ChatContent")
        body = try fields.optional("body", .text) ?? ""
        mentions = try fields.optional("mentions", .list(of: Mention.self)) ?? []
        attachmentHash = try fields.nullable("attachmentHash", .text)
        attachmentMime = try fields.nullable("attachmentMime", .text)
        enc = try fields.nullable("enc", .object(EncEnvelope.self))
        replyTo = try fields.nullable("replyTo", .object(ReplyRef.self))
    }

    /// The content as an item, defaults omitted.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("body", body, default: "")
        writer.list("mentions", omittingEmpty: mentions)
        writer.text("attachmentHash", optional: attachmentHash)
        writer.text("attachmentMime", optional: attachmentMime)
        writer.object("enc", optional: enc)
        writer.object("replyTo", optional: replyTo)
        return writer.cbor
    }
}

/// A mention of one person in a message (`Mention` in knit-next's `Wire.kt`).
public struct Mention: CBORRepresentable, Equatable {
    /// The mentioned person's node id.
    public var nodeId: String
    /// The name the sender saw for them.
    public var name: String

    /// Makes a mention.
    public init(nodeId: String, name: String) {
        self.nodeId = nodeId
        self.name = name
    }

    /// Reads a mention from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "Mention")
        nodeId = try fields.required("nodeId", .text)
        name = try fields.required("name", .text)
    }

    /// The mention as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("nodeId", nodeId)
        writer.text("name", name)
        return writer.cbor
    }
}

/// A quoted reply's reference to the message it answers (`ReplyRef` in knit-next's `Wire.kt`).
public struct ReplyRef: CBORRepresentable, Equatable {
    /// The quoted message's frame id.
    public var messageId: String
    /// The quoted message's author.
    public var authorId: String
    /// The author's name as the replier saw it.
    public var author: String
    /// A short excerpt of the quoted text.
    public var snippet: String
    /// Whether the quoted message had an attachment.
    public var hasAttachment: Bool

    /// Makes a reply reference.
    public init(messageId: String, authorId: String, author: String, snippet: String, hasAttachment: Bool = false) {
        self.messageId = messageId
        self.authorId = authorId
        self.author = author
        self.snippet = snippet
        self.hasAttachment = hasAttachment
    }

    /// Reads a reply reference from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "ReplyRef")
        messageId = try fields.required("messageId", .text)
        authorId = try fields.required("authorId", .text)
        author = try fields.required("author", .text)
        snippet = try fields.required("snippet", .text)
        hasAttachment = try fields.optional("hasAttachment", .bool) ?? false
    }

    /// The reference as an item, defaults omitted.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("messageId", messageId)
        writer.text("authorId", authorId)
        writer.text("author", author)
        writer.text("snippet", snippet)
        writer.bool("hasAttachment", hasAttachment, default: false)
        return writer.cbor
    }
}
