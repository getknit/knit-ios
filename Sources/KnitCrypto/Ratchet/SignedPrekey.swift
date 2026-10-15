public import KnitWire

/// One of this device's ratchet prekeys (`SignedPrekey` and `StoredPrekey` in knit-next's
/// `data/crypto/IdentityKeyStore.kt:28-38`, `:233-243`): an X25519 pair with its id, the identity's Ed25519 signature
/// over it, and when it was minted. A profile publishes ``info``, and a peer's first DM starts a session from it by
/// X3DH (`crypto.md`, "Keys and the signed prekey"). This port publishes none while the ratchet's switch is off (ADR
/// 2026-10.5sk9).
///
/// The signature is made once, at ``mint(id:signedBy:createdAt:keyPair:)``, and kept. Tink's Ed25519 is deterministic,
/// so Android signs again each time it reads a prekey (`IdentityKeyStore.kt:209-217`); CryptoKit's is randomized, so
/// signing again here would give one prekey a different signature every time.
public struct SignedPrekey: Sendable {
    /// The prekey's id: the newest id plus 1, counting from 1.
    public let id: Int
    /// The X25519 private scalar, for the key store. Never log or send it.
    public let privateKey: [UInt8]
    /// The X25519 public value, 32 bytes.
    public let publicKey: [UInt8]
    /// The identity's Ed25519 signature over ``RatchetCrypto/spkSigningBytes(id:pub:)``, 64 bytes.
    public let signature: [UInt8]
    /// When it was minted, in epoch milliseconds: a prekey rotates once the newest is a week old.
    public let createdAt: Int64

    /// A new prekey (`IdentityKeyStore.mint`, `:189-202`): a pair from `keyPair`, the system's generator unless a test or
    /// a vector fixes one, signed once by `identity`.
    public static func mint(
        id: Int,
        signedBy identity: IdentityKeys,
        createdAt: Int64,
        keyPair: () -> RatchetCrypto.KeyPair = RatchetCrypto.generateKeyPair
    ) throws(CryptoFailure) -> Self {
        let pair = keyPair()
        let signed = try identity.signature(for: RatchetCrypto.spkSigningBytes(id: id, pub: pair.publicKey))
        return Self(id: id, privateKey: pair.privateKey, publicKey: pair.publicKey, signature: signed, createdAt: createdAt)
    }

    /// The record a profile publishes as its `prekey` (`PrekeyInfo`, `Wire.kt:576-581`).
    public var info: PrekeyInfo {
        PrekeyInfo(id: id, pub: publicKey, sig: signature)
    }
}

/// A peer's prekey, verified against the peer's own key: what X3DH starts a session against (`RatchetEngine.PeerPrekey`,
/// `RatchetEngine.kt:118-122`, which the engine takes already verified).
public struct PeerPrekey: Sendable, Equatable {
    /// The prekey's id, which the init names.
    public let id: Int
    /// Its X25519 public value, 32 bytes.
    public let publicKey: [UInt8]

    /// The prekey a profile publishes, or `nil` unless its signature verifies against the bundle in that same profile
    /// and its public value is 32 bytes (`InboundPipeline.verifiedPrekey`, `InboundPipeline.kt:3353-3368`). `nil` counts
    /// as no prekey: a bad one never blocks the rest of the profile, and a newer profile with a bad one clears the pin.
    public init?(verifying info: PrekeyInfo, signedBy bundle: PublicKeyBundle) {
        guard info.pub.count == RatchetCrypto.keyByteCount,
            bundle.isValidSignature(info.sig, for: RatchetCrypto.spkSigningBytes(id: info.id, pub: info.pub))
        else {
            return nil
        }
        id = info.id
        publicKey = info.pub
    }
}
