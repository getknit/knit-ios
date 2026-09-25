import Crypto
public import KnitWire

/// This device's long-term identity (`IdentityKeyStore.kt`): an Ed25519 key that signs every frame it sends,
/// and an X25519 key that other devices wrap DM keys to.
///
/// The node id is derived from the public halves, so these keys are the identity: lose them and the device
/// comes back as someone new. Keep them in a ``SecretStore``, and never log or send the private halves.
public struct IdentityKeys: Sendable {
    /// Each raw private key is 32 bytes: the Ed25519 seed (RFC 8032) and the X25519 scalar (RFC 7748).
    public static let privateKeyByteCount = 32

    private let signing: Curve25519.Signing.PrivateKey
    /// The X25519 private key, which ``MessageCrypto`` unwraps DM keys with.
    let agreement: Curve25519.KeyAgreement.PrivateKey
    /// The public bundle this device publishes in its profile.
    public let bundle: PublicKeyBundle

    /// This device's node id.
    public var nodeId: NodeId { bundle.nodeId }
    /// The raw Ed25519 seed, for the key store.
    public var signingSeed: [UInt8] { Array(signing.rawRepresentation) }
    /// The raw X25519 scalar, for the key store.
    public var agreementScalar: [UInt8] { Array(agreement.rawRepresentation) }

    /// Keys restored from their raw private halves, or `nil` if either is not 32 bytes.
    public init?(signingSeed: [UInt8], agreementScalar: [UInt8]) {
        guard let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingSeed),
            let agreementKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementScalar)
        else {
            return nil
        }
        self.init(signing: signingKey, agreement: agreementKey)
    }

    private init(signing: Curve25519.Signing.PrivateKey, agreement: Curve25519.KeyAgreement.PrivateKey) {
        self.signing = signing
        self.agreement = agreement
        bundle = PublicKeyBundle(
            checkedSigningKey: Array(signing.publicKey.rawRepresentation),
            agreementKey: Array(agreement.publicKey.rawRepresentation)
        )
    }

    /// New keys from the system's secure random source.
    public static func generate() -> Self {
        Self(signing: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey())
    }

    /// This device's 64-byte Ed25519 signature over `message` (`MessageCrypto.signRaw`).
    ///
    /// CryptoKit randomizes Ed25519 signatures, so signing the same bytes twice gives two different signatures,
    /// both valid. Sign each frame once and keep the result: custody treats a frame id as one set of bytes.
    public func signature(for message: [UInt8]) throws(CryptoFailure) -> [UInt8] {
        do {
            return try Array(signing.signature(for: message))
        } catch {
            throw .signing
        }
    }
}

// MARK: - Storage

extension IdentityKeys {
    /// How ``load(from:)`` came by its keys.
    public enum Origin: Sendable, Equatable {
        /// Read from the store.
        case stored
        /// Generated, because the store held nothing.
        case created
        /// Generated, because what the store held was not an identity. The old node id is gone for good, as
        /// it is on Android when `identity.key` is unreadable.
        case replacedUnreadable
    }

    /// Keys and where they came from.
    public struct Loaded: Sendable {
        /// The identity.
        public let keys: IdentityKeys
        /// How it was obtained.
        public let origin: Origin
    }

    private static let signingSeedKey = "signingSeed"
    private static let agreementScalarKey = "agreementScalar"

    /// The identity in `store`, generated and stored on first use (`IdentityKeyStore.keys()`).
    ///
    /// A store that cannot answer throws, and nothing is generated: a Keychain read before the first unlock
    /// after a reboot must not mint a new identity.
    public static func load(from store: some SecretStore) throws(SecretStoreError) -> Loaded {
        let existing = try store.read()
        if let existing, let keys = IdentityKeys(storedForm: existing) {
            return Loaded(keys: keys, origin: .stored)
        }
        let keys = generate()
        try store.write(keys.storedForm)
        return Loaded(keys: keys, origin: existing == nil ? .created : .replacedUnreadable)
    }

    /// The private keys as a store keeps them: the CBOR map `{signingSeed, agreementScalar}`. The ratchet's
    /// signed prekeys will join it as a third key, which an older build ignores.
    public var storedForm: [UInt8] {
        CBOR.map([
            CBOR.Entry(key: .text(Self.signingSeedKey), value: .bytes(signingSeed)),
            CBOR.Entry(key: .text(Self.agreementScalarKey), value: .bytes(agreementScalar)),
        ])
        .encoded
    }

    /// Keys read back from ``storedForm``, or `nil` if the bytes are not that map.
    public init?(storedForm bytes: [UInt8]) {
        guard case .map(let entries) = try? CBOR.decode(bytes),
            let seed = Self.bytes(Self.signingSeedKey, in: entries),
            let scalar = Self.bytes(Self.agreementScalarKey, in: entries)
        else {
            return nil
        }
        self.init(signingSeed: seed, agreementScalar: scalar)
    }

    private static func bytes(_ key: String, in entries: [CBOR.Entry]) -> [UInt8]? {
        guard case .bytes(let value) = entries.last(where: { $0.key == .text(key) })?.value else {
            return nil
        }
        return value
    }
}
