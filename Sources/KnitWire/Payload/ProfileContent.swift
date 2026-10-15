/// A profile frame's payload (`ProfileContent` in knit-next's `Wire.kt`).
///
/// ``name`` and ``status`` have no default and must always be written, even empty: a profile Android cannot
/// decode is dropped without a word, and then our key is never pinned. Every other field is kept exactly as
/// received, including the ones this build does not use, so a profile carried for someone else is never
/// thinned.
public struct ProfileContent: CBORRepresentable, Equatable {
    /// The display name; blank means "show the alias".
    public var name: String
    /// The status line; may be empty, never absent.
    public var status: String
    /// The avatar's content hash.
    public var avatarHash: String?
    /// The public key bundle, base64. Effectively required: a profile without it is dropped.
    public var pubKey: String?
    /// A soft per-device tag, 16 hex characters.
    public var deviceTag: String?
    /// The sender's protocol version.
    public var protoVersion: Int?
    /// The signed capability bits, the copy every send-time gate reads.
    public var capabilities: Int64?
    /// The v2 signed prekey. This build publishes one only with the ratchet's switch on (ADR 2026-10.5sk9).
    public var prekey: PrekeyInfo?
    /// The edit clock: last writer wins on it.
    public var version: Int64?
    /// Whether the person is open to chat.
    public var openToChat: Bool
    /// A bound Meshtastic board's node number.
    public var loraNode: Int64?
    /// A bound Meshtastic board's public key, base64.
    public var loraKey: String?

    /// Makes profile content.
    public init(
        name: String,
        status: String,
        avatarHash: String? = nil,
        pubKey: String? = nil,
        deviceTag: String? = nil,
        protoVersion: Int? = nil,
        capabilities: Int64? = nil,
        prekey: PrekeyInfo? = nil,
        version: Int64? = nil,
        openToChat: Bool = false,
        loraNode: Int64? = nil,
        loraKey: String? = nil
    ) {
        self.name = name
        self.status = status
        self.avatarHash = avatarHash
        self.pubKey = pubKey
        self.deviceTag = deviceTag
        self.protoVersion = protoVersion
        self.capabilities = capabilities
        self.prekey = prekey
        self.version = version
        self.openToChat = openToChat
        self.loraNode = loraNode
        self.loraKey = loraKey
    }

    /// Reads profile content from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "ProfileContent")
        name = try fields.required("name", .text)
        status = try fields.required("status", .text)
        avatarHash = try fields.nullable("avatarHash", .text)
        pubKey = try fields.nullable("pubKey", .text)
        deviceTag = try fields.nullable("deviceTag", .text)
        protoVersion = try fields.nullable("protoVersion", .int32)
        capabilities = try fields.nullable("capabilities", .int64)
        prekey = try fields.nullable("prekey", .object(PrekeyInfo.self))
        version = try fields.nullable("version", .int64)
        openToChat = try fields.optional("openToChat", .bool) ?? false
        loraNode = try fields.nullable("loraNode", .int64)
        loraKey = try fields.nullable("loraKey", .text)
    }

    /// The content as an item, defaults omitted.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("name", name)
        writer.text("status", status)
        writer.text("avatarHash", optional: avatarHash)
        writer.text("pubKey", optional: pubKey)
        writer.text("deviceTag", optional: deviceTag)
        writer.int("protoVersion", optional: protoVersion)
        writer.long("capabilities", optional: capabilities)
        writer.object("prekey", optional: prekey)
        writer.long("version", optional: version)
        writer.bool("openToChat", openToChat, default: false)
        writer.long("loraNode", optional: loraNode)
        writer.text("loraKey", optional: loraKey)
        return writer.cbor
    }
}

/// A v2 signed prekey (`PrekeyInfo` in knit-next's `Wire.kt`). Decoded so profiles round-trip, and pinned once its
/// signature verifies; published only with the ratchet's switch on (ADR 2026-10.5sk9).
public struct PrekeyInfo: CBORRepresentable, Equatable {
    /// The prekey's id, counting up from 1.
    public var id: Int
    /// The X25519 public key, 32 bytes.
    public var pub: [UInt8]
    /// Ed25519 over `"knit/dm/v2/spk" ‖ u32be(id) ‖ pub`, 64 bytes.
    public var sig: [UInt8]

    /// Makes a prekey record.
    public init(id: Int, pub: [UInt8], sig: [UInt8]) {
        self.id = id
        self.pub = pub
        self.sig = sig
    }

    /// Reads a prekey record from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "PrekeyInfo")
        id = try fields.required("id", .int32)
        pub = try fields.required("pub", .bytes)
        sig = try fields.required("sig", .bytes)
    }

    /// The record as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.int("id", id)
        writer.bytes("pub", pub)
        writer.bytes("sig", sig)
        return writer.cbor
    }
}
