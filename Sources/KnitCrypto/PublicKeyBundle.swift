import Crypto
public import KnitWire

/// A device's published public keys (`PublicKeyBundle.kt`): an Ed25519 key that checks its signatures, and an
/// X25519 key that DM keys are wrapped to.
///
/// On the wire a bundle is ``encoded``, standard base64 of a ``PublicKeyBundleProto``. That text is what a
/// profile carries, what gets pinned, and what the node id is the hash of, so a received bundle keeps its text
/// exactly as it arrived, and two bundles are equal only when their text is.
public struct PublicKeyBundle: Hashable, Sendable {
    /// Both raw public keys are 32 bytes (RFC 8032, RFC 7748).
    public static let keyByteCount = 32

    /// The base64 text.
    public let encoded: String
    /// The raw Ed25519 public key.
    public let signingKey: [UInt8]
    /// The raw X25519 public key.
    public let agreementKey: [UInt8]
    /// The node id this bundle certifies.
    public let nodeId: NodeId

    /// Parses a bundle from a profile or the store, or returns `nil` if the text is not base64 of a proto that
    /// holds two 32-byte keys. knit-next accepts other key lengths here and fails later, when it verifies or
    /// seals; refusing them now reaches the same outcome sooner.
    public init?(encoded: String) {
        guard let bytes = Base64.decode(encoded), let proto = try? PublicKeyBundleProto(decoding: bytes),
            proto.sigPub.count == Self.keyByteCount, proto.hpkePub.count == Self.keyByteCount
        else {
            return nil
        }
        self.init(encoded: encoded, signingKey: proto.sigPub, agreementKey: proto.hpkePub)
    }

    /// Builds a bundle from two raw public keys (`PublicKeyBundle.fromRaw`), or returns `nil` if either is not
    /// 32 bytes. The text is byte-identical to what knit-next builds from the same keys.
    public init?(signingKey: [UInt8], agreementKey: [UInt8]) {
        guard signingKey.count == Self.keyByteCount, agreementKey.count == Self.keyByteCount else {
            return nil
        }
        self.init(checkedSigningKey: signingKey, agreementKey: agreementKey)
    }

    /// Builds a bundle from keys already known to be 32 bytes.
    init(checkedSigningKey signingKey: [UInt8], agreementKey: [UInt8]) {
        let text = Base64.encode(PublicKeyBundleProto(sigPub: signingKey, hpkePub: agreementKey).encoded)
        self.init(encoded: text, signingKey: signingKey, agreementKey: agreementKey)
    }

    private init(encoded: String, signingKey: [UInt8], agreementKey: [UInt8]) {
        self.encoded = encoded
        self.signingKey = signingKey
        self.agreementKey = agreementKey
        nodeId = NodeId(deriving: encoded)
    }

    /// Whether `signature` is this bundle's Ed25519 signature over `message` (`MessageCrypto.verify`). Any
    /// malformed input answers `false`, so an inbound frame can be dropped without stopping the relay.
    ///
    /// Verify signatures rather than comparing them: CryptoKit randomizes Ed25519, so two valid signatures over
    /// the same bytes can differ.
    public func isValidSignature(_ signature: [UInt8], for message: [UInt8]) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey) else {
            return false
        }
        return key.isValidSignature(signature, for: message)
    }
}
