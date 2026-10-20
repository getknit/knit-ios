/// The body of a contact card (the private `ContactCard.Body` in knit-next, `ContactCard.kt:55-62`): an identity, its
/// presentation and its relay hints, as definite-length CBOR with text keys in declaration order, `v`, `id`, `pk`,
/// `name`, `sp`, `iat`, and every field equal to its default left out (docs/CONTACT_CARD.md §2).
///
/// A card's signature covers these bytes exactly as they arrived, so a reader verifies the bytes it was given and
/// never these re-encoded. `KnitCrypto`'s `ContactCard` gives the fields their meaning; the layout lives here because
/// every CBOR codec does.
public struct ContactCardBody: CBORRepresentable, Equatable {
    /// The card's layout version, `v`, a Kotlin `Int`.
    public var version: Int
    /// The node id's text, `id`.
    public var nodeId: String
    /// The two raw public keys, `sigPub ‖ hpkePub`, `pk`.
    public var keys: [UInt8]
    /// The owner's display name, `name`, or `nil` for none.
    public var name: String?
    /// The relays the owner uses, `sp`, or `nil` for none.
    public var spools: [String]?
    /// When the card was issued, epoch milliseconds, `iat`; 0 is the default and is left out.
    public var issuedAt: Int64

    /// Makes a body.
    public init(version: Int, nodeId: String, keys: [UInt8], name: String? = nil, spools: [String]? = nil, issuedAt: Int64 = 0) {
        self.version = version
        self.nodeId = nodeId
        self.keys = keys
        self.name = name
        self.spools = spools
        self.issuedAt = issuedAt
    }

    /// Reads a body as kotlinx does: `v`, `id` and `pk` required, `name` and `sp` nullable, `iat` defaulting to 0 and
    /// never `null`, unknown keys ignored.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "ContactCard.Body")
        version = try fields.required("v", .int32)
        nodeId = try fields.required("id", .text)
        keys = try fields.required("pk", .bytes)
        name = try fields.nullable("name", .text)
        spools = try fields.nullable("sp", .texts)
        issuedAt = try fields.optional("iat", .int64) ?? 0
    }

    /// The body as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.int("v", version)
        writer.text("id", nodeId)
        writer.bytes("pk", keys)
        writer.text("name", optional: name)
        writer.texts("sp", optional: spools)
        writer.long("iat", issuedAt, default: 0)
        return writer.cbor
    }
}

/// A contact card's outer wrapper (the private `ContactCard.Signed`, `ContactCard.kt:67-70`): the body's bytes, opaque,
/// and the raw Ed25519 signature over `"knit/card/v1" ‖ body`.
public struct ContactCardSigned: CBORRepresentable, Equatable {
    /// The body's CBOR, kept as received.
    public var body: [UInt8]
    /// The 64-byte Ed25519 signature.
    public var sig: [UInt8]

    /// Makes a wrapper.
    public init(body: [UInt8], sig: [UInt8]) {
        self.body = body
        self.sig = sig
    }

    /// Reads a wrapper: both fields required byte strings, unknown keys ignored.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "ContactCard.Signed")
        body = try fields.required("body", .bytes)
        sig = try fields.required("sig", .bytes)
    }

    /// The wrapper as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.bytes("body", body)
        writer.bytes("sig", sig)
        return writer.cbor
    }
}
