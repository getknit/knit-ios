/// The CBOR inside a public key bundle (the private `PublicKeyBundle.Proto` in knit-next): the two raw public
/// keys, `sigPub` then `hpkePub`, as byte strings.
///
/// A profile carries the bundle as standard base64 of these bytes, and a node id is the hash of that base64
/// text, so the encoding is part of every identity. For 32-byte keys it is always 84 bytes. `KnitCrypto`
/// wraps this type with the keys' meaning; it lives here because every CBOR codec does.
public struct PublicKeyBundleProto: CBORRepresentable, Equatable {
    /// The raw Ed25519 public key (RFC 8032).
    public var sigPub: [UInt8]
    /// The raw X25519 public key that HPKE wraps DM keys to (RFC 7748, RFC 9180).
    public var hpkePub: [UInt8]

    /// Makes the proto from two raw keys.
    public init(sigPub: [UInt8], hpkePub: [UInt8]) {
        self.sigPub = sigPub
        self.hpkePub = hpkePub
    }

    /// Reads the proto from a decoded item. Like kotlinx, it takes keys of any length; the caller checks them.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "PublicKeyBundle")
        sigPub = try fields.required("sigPub", .bytes)
        hpkePub = try fields.required("hpkePub", .bytes)
    }

    /// The proto as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.bytes("sigPub", sigPub)
        writer.bytes("hpkePub", hpkePub)
        return writer.cbor
    }
}
