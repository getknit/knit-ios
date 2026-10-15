/// The plaintext inside a v1 or v2 sealed message, in its named layout (`MessageContent` in knit-next's
/// `mesh/crypto/MessageContent.kt`). A v3 message carries the same facts in ``MessageContentV2``'s compact layout.
///
/// A message with a non-nil ``ctl`` is machinery (a receipt, a reaction, a key or profile update): it is never
/// rendered, notified or acknowledged. The group-key and profile payloads (``gk``, ``pr``) are typed, as kotlinx types
/// them, so a payload Android cannot decode fails here too; the transfer payload (``xf``) is kept as an undecoded
/// item, because this build carries it but never reads it (ADR 2026-10.5sk9).
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
    /// A group-key payload, for the group-key control codes.
    public var gk: GroupKeyPayload?
    /// The acknowledged frame id, for a sealed receipt.
    public var ack: String?
    /// A sealed reaction.
    public var rp: ReactionContent?
    /// A sealed profile update, for ``Control/profile``.
    public var pr: ProfilePayload?
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
        gk: GroupKeyPayload? = nil,
        ack: String? = nil,
        rp: ReactionContent? = nil,
        pr: ProfilePayload? = nil,
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
        gk = try fields.nullable("gk", .object(GroupKeyPayload.self))
        ack = try fields.nullable("ack", .text)
        rp = try fields.nullable("rp", .object(ReactionContent.self))
        pr = try fields.nullable("pr", .object(ProfilePayload.self))
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
        writer.object("gk", optional: gk)
        writer.text("ack", optional: ack)
        writer.object("rp", optional: rp)
        writer.object("pr", optional: pr)
        writer.texts("acks", optional: acks)
        writer.raw("xf", optional: xf)
        return writer.cbor
    }

    /// Whether this is machinery rather than a message a person wrote.
    public var isControl: Bool { ctl != nil }
}

/// A sealed profile update, ``MessageContent/pr`` under ``MessageContent/Control/profile`` (`ProfilePayload` in
/// knit-next's `Wire.kt:700-709`).
///
/// The presentation fields only. The key and the prekey ride the cleartext signed profile alone: a re-pin must be
/// authenticated by that frame, and a prekey starts the session this would ride (`Wire.kt:682-686`). ``version`` is
/// the sender's own profile version, the one number the sealed and the cleartext paths both order by.
public struct ProfilePayload: CBORRepresentable, Equatable {
    /// The display name.
    public var name: String
    /// The status line; may be empty, never absent.
    public var status: String
    /// The avatar's content hash.
    public var avatarHash: String?
    /// The sender's profile version, omitted while 0.
    public var version: Int64
    /// Whether the person is open to chat, omitted while off.
    public var openToChat: Bool
    /// A bound Meshtastic board's node number.
    public var loraNode: Int64?
    /// A bound Meshtastic board's signing key, base64.
    public var loraKey: String?

    /// Makes a profile update.
    public init(
        name: String,
        status: String,
        avatarHash: String? = nil,
        version: Int64 = 0,
        openToChat: Bool = false,
        loraNode: Int64? = nil,
        loraKey: String? = nil
    ) {
        self.name = name
        self.status = status
        self.avatarHash = avatarHash
        self.version = version
        self.openToChat = openToChat
        self.loraNode = loraNode
        self.loraKey = loraKey
    }

    /// Reads a profile update from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "ProfilePayload")
        name = try fields.required("name", .text)
        status = try fields.required("status", .text)
        avatarHash = try fields.nullable("avatarHash", .text)
        version = try fields.optional("version", .int64) ?? 0
        openToChat = try fields.optional("openToChat", .bool) ?? false
        loraNode = try fields.nullable("loraNode", .int64)
        loraKey = try fields.nullable("loraKey", .text)
    }

    /// The update as an item, defaults omitted.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("name", name)
        writer.text("status", status)
        writer.text("avatarHash", optional: avatarHash)
        writer.long("version", version, default: 0)
        writer.bool("openToChat", openToChat, default: false)
        writer.long("loraNode", optional: loraNode)
        writer.text("loraKey", optional: loraKey)
        return writer.cbor
    }
}

/// The group-key payload, ``MessageContent/gk`` under the group-key control codes (`GroupKeyPayload` in knit-next's
/// `Wire.kt:649-656`).
///
/// A distribution (``MessageContent/Control/groupKey``) carries one or more ``keys``; a request
/// (``MessageContent/Control/groupKeyRequest``) carries ``groupId`` with ``keys`` empty; an adoption ack
/// (``MessageContent/Control/groupKeyAck``) echoes ``groupId`` and ``ackEpoch``. ``group`` is the founding roster, so a
/// member holding no row for the group can pin it from the seed itself (`Wire.kt:640-647`).
public struct GroupKeyPayload: CBORRepresentable, Equatable {
    /// The group the seeds are for.
    public var groupId: String
    /// The sender's epoch seeds, omitted while empty.
    public var keys: [GroupSeed]
    /// The sender's epoch this acknowledges adopting.
    public var ackEpoch: Int?
    /// The spool's shared group root (`GroupRootPayload`), kept exactly as received and never sent: this port has no
    /// spool (ADR 2026-10.5sk9). It must read as a ``GroupRootPayload``, as kotlinx types it, or the payload fails.
    public var gr: CBOR?
    /// The group's founding roster: its id, members, departed, founder and name, never its photo.
    public var group: GroupInfo?

    /// Makes a group-key payload.
    public init(groupId: String, keys: [GroupSeed] = [], ackEpoch: Int? = nil, gr: CBOR? = nil, group: GroupInfo? = nil) {
        self.groupId = groupId
        self.keys = keys
        self.ackEpoch = ackEpoch
        self.gr = gr
        self.group = group
    }

    /// Reads a group-key payload from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "GroupKeyPayload")
        groupId = try fields.required("groupId", .text)
        keys = try fields.optional("keys", .list(of: GroupSeed.self)) ?? []
        ackEpoch = try fields.nullable("ackEpoch", .int32)
        gr = try fields.nullable("gr", .checked(as: GroupRootPayload.self))
        group = try fields.nullable("group", .object(GroupInfo.self))
    }

    /// The payload as an item, defaults omitted.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("groupId", groupId)
        writer.list("keys", omittingEmpty: keys)
        writer.int("ackEpoch", optional: ackEpoch)
        writer.raw("gr", optional: gr)
        writer.object("group", optional: group)
        return writer.cbor
    }
}

/// One group send-epoch seed (`GroupSeed` in knit-next's `Wire.kt:604-609`): the sender's epoch number, the raw
/// 32-byte seed its chain derives from, and the stamp receivers key their rows by.
public struct GroupSeed: CBORRepresentable, Equatable {
    /// The sender's group epoch.
    public var epoch: Int
    /// The raw seed.
    public var seed: [UInt8]
    /// When the sender minted it, in epoch milliseconds: adoption orders by `(epoch, mintedAt)`.
    public var mintedAt: Int64

    /// Makes a seed record.
    public init(epoch: Int, seed: [UInt8], mintedAt: Int64) {
        self.epoch = epoch
        self.seed = seed
        self.mintedAt = mintedAt
    }

    /// Reads a seed record from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "GroupSeed")
        epoch = try fields.required("epoch", .int32)
        seed = try fields.required("seed", .bytes)
        mintedAt = try fields.required("mintedAt", .int64)
    }

    /// The seed record as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.int("epoch", epoch)
        writer.bytes("seed", seed)
        writer.long("mintedAt", mintedAt)
        return writer.cbor
    }
}

/// The spool's shared group root (`GroupRootPayload` in knit-next's `Wire.kt:622-627`). This port has no spool, so it
/// only checks that ``GroupKeyPayload/gr`` has this shape, and never sends one (ADR 2026-10.5sk9).
public struct GroupRootPayload: CBORRepresentable, Equatable {
    /// The raw 32-byte root.
    public var root: [UInt8]
    /// Its version, which is also the spool scope's epoch.
    public var version: Int
    /// The member who minted it.
    public var minter: String

    /// Makes a root record.
    public init(root: [UInt8], version: Int, minter: String) {
        self.root = root
        self.version = version
        self.minter = minter
    }

    /// Reads a root record from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "GroupRootPayload")
        root = try fields.required("root", .bytes)
        version = try fields.required("version", .int32)
        minter = try fields.required("minter", .text)
    }

    /// The root record as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.bytes("root", root)
        writer.int("version", version)
        writer.text("minter", minter)
        return writer.cbor
    }
}
