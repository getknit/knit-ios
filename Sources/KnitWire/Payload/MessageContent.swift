/// The plaintext inside a v1 or v2 sealed message, in its named layout (`MessageContent` in knit-next's
/// `mesh/crypto/MessageContent.kt`).
///
/// A message with a non-nil ``ctl`` is machinery (a receipt, a reaction, a key or profile update): it is never
/// rendered, notified or acknowledged. The group-key, profile and transfer payloads (``gk``, ``pr``, ``xf``)
/// are kept as undecoded items, because this build carries them but does not act on them.
public struct MessageContent: CBORRepresentable, Equatable {
    /// Control codes (`MessageContent.CTL_*`). An unknown code is a silent no-op.
    public enum Control {
        /// A ratchet session reset.
        public static let sessionReset = 1
        /// A group key distribution.
        public static let groupKey = 2
        /// A group key request.
        public static let groupKeyRequest = 3
        /// A group key acknowledgement.
        public static let groupKeyAck = 4
        /// A sealed delivery receipt.
        public static let receipt = 5
        /// A sealed reaction.
        public static let reaction = 6
        /// A sealed profile update.
        public static let profile = 8
        /// A Wi-Fi Direct transfer offer or answer.
        public static let transfer = 9
    }

    /// The plaintext layout version, always 1 and never written.
    public static let currentVersion = 1

    /// The plaintext version (wire key `v`); a value above ``currentVersion`` is dropped locally.
    public var version: Int
    /// The message text; present even when empty.
    public var body: String
    /// The people the message mentions.
    public var mentions: [Mention]
    /// The attachment's content hash.
    public var attachmentHash: String?
    /// The attachment's type.
    public var attachmentMime: String?
    /// The attachment's key, base64 of 32 bytes.
    public var attachmentKey: String?
    /// A file attachment's name.
    public var attachmentName: String?
    /// A file attachment's size in bytes.
    public var attachmentSize: Int64?
    /// The quoted reply.
    public var replyTo: ReplyRef?
    /// The control code, for a machinery message.
    public var ctl: Int?
    /// A group-key payload, undecoded.
    public var gk: CBOR?
    /// The acknowledged frame id, for a sealed receipt.
    public var ack: String?
    /// A sealed reaction.
    public var rp: ReactionContent?
    /// A sealed profile update, undecoded.
    public var pr: CBOR?
    /// Batched acknowledgements, for a sealed receipt.
    public var acks: [String]?
    /// A transfer payload, undecoded.
    public var xf: CBOR?

    /// Makes plaintext content; only ``body`` is required.
    public init(
        version: Int = Self.currentVersion,
        body: String,
        mentions: [Mention] = [],
        attachmentHash: String? = nil,
        attachmentMime: String? = nil,
        attachmentKey: String? = nil,
        attachmentName: String? = nil,
        attachmentSize: Int64? = nil,
        replyTo: ReplyRef? = nil,
        ctl: Int? = nil,
        gk: CBOR? = nil,
        ack: String? = nil,
        rp: ReactionContent? = nil,
        pr: CBOR? = nil,
        acks: [String]? = nil,
        xf: CBOR? = nil
    ) {
        self.version = version
        self.body = body
        self.mentions = mentions
        self.attachmentHash = attachmentHash
        self.attachmentMime = attachmentMime
        self.attachmentKey = attachmentKey
        self.attachmentName = attachmentName
        self.attachmentSize = attachmentSize
        self.replyTo = replyTo
        self.ctl = ctl
        self.gk = gk
        self.ack = ack
        self.rp = rp
        self.pr = pr
        self.acks = acks
        self.xf = xf
    }

    /// Reads plaintext content from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "MessageContent")
        version = try fields.optional("v", .int32) ?? Self.currentVersion
        body = try fields.required("body", .text)
        mentions = try fields.optional("mentions", .list(of: Mention.self)) ?? []
        attachmentHash = try fields.nullable("attachmentHash", .text)
        attachmentMime = try fields.nullable("attachmentMime", .text)
        attachmentKey = try fields.nullable("attachmentKey", .text)
        attachmentName = try fields.nullable("attachmentName", .text)
        attachmentSize = try fields.nullable("attachmentSize", .int64)
        replyTo = try fields.nullable("replyTo", .object(ReplyRef.self))
        ctl = try fields.nullable("ctl", .int32)
        gk = try fields.nullable("gk", .raw)
        ack = try fields.nullable("ack", .text)
        rp = try fields.nullable("rp", .object(ReactionContent.self))
        pr = try fields.nullable("pr", .raw)
        acks = try fields.nullable("acks", .texts)
        xf = try fields.nullable("xf", .raw)
    }

    /// The content as an item, defaults omitted.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.int("v", version, default: Self.currentVersion)
        writer.text("body", body)
        writer.list("mentions", omittingEmpty: mentions)
        writer.text("attachmentHash", optional: attachmentHash)
        writer.text("attachmentMime", optional: attachmentMime)
        writer.text("attachmentKey", optional: attachmentKey)
        writer.text("attachmentName", optional: attachmentName)
        writer.long("attachmentSize", optional: attachmentSize)
        writer.object("replyTo", optional: replyTo)
        writer.int("ctl", optional: ctl)
        writer.raw("gk", optional: gk)
        writer.text("ack", optional: ack)
        writer.object("rp", optional: rp)
        writer.raw("pr", optional: pr)
        writer.texts("acks", optional: acks)
        writer.raw("xf", optional: xf)
        return writer.cbor
    }

    /// Whether this is machinery rather than a message a person wrote.
    public var isControl: Bool { ctl != nil }
}
