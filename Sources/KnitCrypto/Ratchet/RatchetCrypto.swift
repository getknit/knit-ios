import Crypto
public import KnitWire

/// The DM ratchet's primitive layer (`RatchetCrypto` in knit-next's `mesh/crypto/ratchet/RatchetCrypto.kt`, at
/// `ac491f4c`): the X3DH bootstrap, each epoch's derivation, the forward-only message chain, v3's derived nonce and
/// header binding, the signed prekey's bytes, the root tag, and the AES-GCM the chain's keys seal with. Pure functions
/// over raw bytes, as the Kotlin's are, checked against knit-next's known answers (`ratchet-v1.json`) and an RFC 5869
/// HKDF built on HMAC alone.
///
/// Every HKDF here is HKDF-SHA256 called as Tink's `Hkdf.computeHkdf` takes it: the input key material first, then
/// the salt (`:27`, `:100`, `:127`). The zero salt is 32 zero bytes, and every label is ASCII under `knit/dm/v2/` or
/// `knit/dm/v3/`, apart from HPKE's, so the identity's X25519 key serves v1 and X3DH and the two never derive one key.
///
/// Nothing here seals or opens a frame yet: the ratchet is ported dark behind `MeshConfiguration.ratchet` (ADR
/// 2026-10.5sk9). The spool's exports (`exportRoot`, `exportEpochSeal`, `:176-186`) are left out with the spool.
public enum RatchetCrypto {
    /// A raw X25519 key's length, and a root, chain or message key's (`KEY_BYTES`, `:22`).
    public static let keyByteCount = 32
    /// An epoch's HKDF output: the chain key, then the export half (`EPOCH_SECRET_BYTES`, `:25`).
    public static let epochSecretByteCount = 64
    /// An AES-GCM nonce's length (`AesGcm.IV_BYTES`, `Crypto.kt:37`).
    public static let nonceByteCount = 12
    /// An AES-GCM tag's length; the tag ends a sealed body.
    public static let tagByteCount = 16
    /// The root tag's length: eight HKDF bytes, read as one big-endian `Int64` (`:195-198`).
    static let rootTagByteCount = 8

    /// The zero salt, as long as the hash (`ZERO_SALT`, `:29`).
    static let zeroSalt = [UInt8](repeating: 0, count: keyByteCount)
    /// X3DH's pad ahead of the three exchanges, which keeps the first HKDF block apart from any bare-DH construction.
    private static let x3dhPad = [UInt8](repeating: UInt8.max, count: keyByteCount)
    private static let labelX3DH = Array("knit/dm/v2/x3dh".utf8)
    private static let labelEpoch = Array("knit/dm/v2/epoch".utf8)
    private static let labelMessageKey = Array("knit/dm/v2/mk".utf8)
    private static let labelChainKey = Array("knit/dm/v2/ck".utf8)
    private static let labelSignedPrekey = Array("knit/dm/v2/spk".utf8)
    private static let labelRootTag = Array("knit/dm/v2/root-tag".utf8)
    private static let labelNonceV3 = Array("knit/dm/v3/nonce".utf8)
    private static let labelHeaderV3 = Array("knit/dm/v3/hdr".utf8)
    /// The epoch info's direction byte: `i` when the epoch's sender initiated the session, `r` when it responded.
    private static let initiatorDirection = UInt8(ascii: "i")
    private static let responderDirection = UInt8(ascii: "r")
    /// The header binding's last part opens with whether an init rides.
    private static let noInit: UInt8 = 0
    private static let withInit: UInt8 = 1

    /// An X25519 key pair as raw RFC 7748 bytes, the only shape the ratchet's wire carries (`KeyPair`, `:43-46`).
    public struct KeyPair: Sendable {
        /// The private scalar, as a store keeps it. Never log or send it.
        public let privateKey: [UInt8]
        /// The public value.
        public let publicKey: [UInt8]

        /// The pair for a stored private key, its public half recomputed (`publicFromPrivate`, `:53-54`): prekeys and
        /// epochs persist the private half alone. A key that is not 32 bytes is refused.
        public init(privateKey: [UInt8]) throws(RatchetCryptoError) {
            guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else {
                throw .invalidKey
            }
            self.init(key)
        }

        init(_ key: Curve25519.KeyAgreement.PrivateKey) {
            privateKey = Array(key.rawRepresentation)
            publicKey = Array(key.publicKey.rawRepresentation)
        }
    }

    /// One epoch's two secrets (`EpochKeys`, `:103-107`): the chain key its message chain starts from, and the export
    /// half, which only knit-next's spool reads. This port keeps the export half because the derivation yields it and
    /// the vectors pin it, and stores nothing from it.
    public struct EpochKeys: Sendable {
        /// Chain key 0 of the epoch.
        public let chainKey: [UInt8]
        /// The export half.
        public let export: [UInt8]
    }

    /// A fresh pair from the system's generator, never an injected one (`generateKeyPair`, `:48-51`). Whatever mints a
    /// key takes a source that defaults to this, so a test or a vector can fix the pair, as Kotlin's
    /// `RatchetEngine(newKeyPair)` does.
    public static func generateKeyPair() -> KeyPair {
        KeyPair(Curve25519.KeyAgreement.PrivateKey())
    }

    /// The raw X25519 shared secret (`dh`, `:56-60`).
    ///
    /// Tink throws on a low-order public value, where swift-crypto and CryptoKit return zeros, so this refuses an
    /// all-zero result with ``RatchetCryptoError/lowOrderPoint``. The open path maps that error as Android maps Tink's:
    /// a bad `ek` is `BAD_HEADER`, a bad `init.eph` falls to the pipeline's catch-all, and neither counts toward a
    /// reset. Read as `AEAD_FAIL`, it would buy a reset Tink never would (`crypto.md`, "The envelope").
    public static func dh(_ privateKey: [UInt8], _ publicKey: [UInt8]) throws(RatchetCryptoError) -> [UInt8] {
        guard let ours = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey),
            let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        else {
            throw .invalidKey
        }
        // An exchange the library refuses outright counts as the zeros it would otherwise return: either way the
        // public value gives no secret, which is when Tink throws.
        guard let secret = try? ours.sharedSecretFromKeyAgreement(with: theirs), !secret.isAllZero else {
            throw .lowOrderPoint
        }
        return copiedBytes(secret)
    }

    /// The initiator's session root (`x3dhInitiate`, `:67-77`): DH1 binds our identity, DH2 the peer's, and DH3,
    /// ephemeral to prekey, is the forward secrecy no long-term key can rebuild once `ekPriv` and the prekey retire.
    /// The identity keys are the X25519 halves, `hpkePub` and its scalar.
    public static func x3dhInitiate(
        ikPriv: [UInt8],
        ekPriv: [UInt8],
        peerIkPub: [UInt8],
        peerSpkPub: [UInt8]
    ) throws(RatchetCryptoError) -> [UInt8] {
        x3dhRoot(try dh(ikPriv, peerSpkPub), try dh(ekPriv, peerIkPub), try dh(ekPriv, peerSpkPub))
    }

    /// The responder's mirror of ``x3dhInitiate(ikPriv:ekPriv:peerIkPub:peerSpkPub:)``, from the prekey the init names
    /// and the init's ephemeral (`x3dhRespond`, `:79-90`). Both sides derive the same root.
    public static func x3dhRespond(
        ikPriv: [UInt8],
        spkPriv: [UInt8],
        peerIkPub: [UInt8],
        peerEkPub: [UInt8]
    ) throws(RatchetCryptoError) -> [UInt8] {
        x3dhRoot(try dh(spkPriv, peerIkPub), try dh(ikPriv, peerEkPub), try dh(spkPriv, peerEkPub))
    }

    /// `HKDF(0xFF×32 ‖ DH1 ‖ DH2 ‖ DH3, zero salt, "knit/dm/v2/x3dh", 32)` (`:92-101`).
    private static func x3dhRoot(_ dh1: [UInt8], _ dh2: [UInt8], _ dh3: [UInt8]) -> [UInt8] {
        hkdf(x3dhPad + dh1 + dh2 + dh3, salt: zeroSalt, info: labelX3DH, count: keyByteCount)
    }

    /// One direction's epoch secret (`deriveEpoch`, `:109-129`): HKDF with the exchange as input key material and the
    /// session root as the salt, never the other way round. The root never changes, since custody leaves holes no chain
    /// of roots would survive, so every epoch derives from it on its own, and the info binds the direction and both
    /// epoch numbers so no two epochs of a session collide even when an exchange repeats. `senderIsInitiator` is the
    /// epoch sender's role in the session, not the caller's: both sides pass the same value for one epoch.
    public static func deriveEpoch(
        sessionRoot: [UInt8],
        dhShared: [UInt8],
        senderIsInitiator: Bool,
        senderEpoch: Int,
        baseEpoch: Int
    ) -> EpochKeys {
        let info = epochInfo(senderIsInitiator: senderIsInitiator, senderEpoch: senderEpoch, baseEpoch: baseEpoch)
        return EpochKeys(okm: hkdf(dhShared, salt: sessionRoot, info: info, count: epochSecretByteCount))
    }

    /// `"knit/dm/v2/epoch" ‖ dir ‖ u32be(se) ‖ u32be(pe)`, where `dir` is `i` when the epoch's sender initiated the
    /// session and `r` when it responded (`:123-126`).
    static func epochInfo(senderIsInitiator: Bool, senderEpoch: Int, baseEpoch: Int) -> [UInt8] {
        let direction = senderIsInitiator ? initiatorDirection : responderDirection
        return labelEpoch + [direction] + u32be(senderEpoch) + u32be(baseEpoch)
    }

    /// The AES-256-GCM key for chain index n, from chain key n (`messageKey`, `:131-132`). It seals or opens one frame.
    public static func messageKey(_ chainKey: [UInt8]) -> [UInt8] {
        hkdf(chainKey, salt: zeroSalt, info: labelMessageKey, count: keyByteCount)
    }

    /// Chain key n + 1 from chain key n (`nextChainKey`, `:134-135`): one way, so a spent key can be deleted.
    public static func nextChainKey(_ chainKey: [UInt8]) -> [UInt8] {
        hkdf(chainKey, salt: zeroSalt, info: labelChainKey, count: keyByteCount)
    }

    /// A v3 frame's AES-GCM nonce (`messageNonce`, `:137-149`): derived from the message key and the frame's bound AAD,
    /// never carried and never a counter (knit-next `dd68d9fd`). From the message key, not the chain key, so a stored
    /// skipped key still opens its frame; with the AAD, which carries the frame id, so a send chain a restored database
    /// rolled back cannot reuse a nonce under one key.
    public static func messageNonce(messageKey: [UInt8], aad: [UInt8]) -> [UInt8] {
        hkdf(messageKey, salt: zeroSalt, info: labelNonceV3 + aad, count: nonceByteCount)
    }

    /// What a v3 frame appends to its AAD to bind its ratchet header (`headerBindingBytes`, `:151-165`):
    /// `"knit/dm/v3/hdr" ‖ u32be(se) ‖ ek ‖ u32be(pe) ‖ u32be(n) ‖ u8(flags)`, then `00`, or `01 ‖ eph ‖ u32be(pkid) ‖
    /// u64be(at)` when an init rides: 60 or 104 bytes. An explicit layout rather than the header's CBOR, so it never
    /// depends on an encoder reproducing those bytes. It binds `flags` and `init.at`, which the derived key does not,
    /// because the v3 tick has no signature to cover them.
    public static func headerBindingBytes(_ header: RatchetHeader) -> [UInt8] {
        var bytes = labelHeaderV3 + u32be(header.se) + header.ek + u32be(header.pe) + u32be(header.n)
        bytes.append(UInt8(truncatingIfNeeded: header.flags))
        guard let initial = header.initial else {
            bytes.append(noInit)
            return bytes
        }
        bytes.append(withInit)
        return bytes + initial.eph + u32be(initial.pkid) + u64be(initial.at)
    }

    /// The bytes a signed prekey's Ed25519 signature covers (`spkSigningBytes`, `:167-174`): `"knit/dm/v2/spk" ‖
    /// u32be(id) ‖ pub`, 50 bytes for a 32-byte key. Detached from the profile's own signature, so a prekey stored apart
    /// from its frame stays verifiable.
    public static func spkSigningBytes(id: Int, pub: [UInt8]) -> [UInt8] {
        labelSignedPrekey + u32be(id) + pub
    }

    /// The tag a session root's receive state carries (`rootTag`, `:188-198`; knit-next ADR 2026-10.gcrd): eight HKDF
    /// bytes read as one big-endian, signed `Int64`. A reset restarts the resetter's epoch numbers, so a peer and an
    /// epoch number can name two eras, and the tag keeps each root's receive rows and skipped keys apart. One way, so no
    /// row holds the root it came from. Local storage only, never on the wire.
    public static func rootTag(_ sessionRoot: [UInt8]) -> Int64 {
        let bytes = hkdf(sessionRoot, salt: zeroSalt, info: labelRootTag, count: rootTagByteCount)
        return Int64(bitPattern: bytes.reduce(0) { $0 << UInt64(UInt8.bitWidth) | UInt64($1) })
    }

    /// AES-256-GCM under a message key (`AesGcm.encrypt`, `Crypto.kt:53-65`): the ciphertext, then its tag. A v2 frame's
    /// nonce is 12 bytes from the system's generator, carried in its envelope; a v3 frame's is
    /// ``messageNonce(messageKey:aad:)`` over the AAD with the header bound in (`RatchetEngine.kt:280-289`). A message
    /// key seals one frame, and never twice under one nonce.
    public static func seal(_ plaintext: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) throws(RatchetCryptoError) -> [UInt8] {
        guard key.count == keyByteCount, nonce.count == nonceByteCount,
            let box = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        else {
            throw .sealing
        }
        return Array(box.ciphertext) + Array(box.tag)
    }

    /// The plaintext of a body ``seal(_:key:nonce:aad:)`` sealed, or `nil` for a wrong key, nonce or AAD, a bad tag, or a
    /// body shorter than its tag (`AesGcm.decrypt`, `Crypto.kt:67-80`). The open path reads `nil` as `AEAD_FAIL`
    /// (`RatchetEngine.kt:819-822`).
    public static func open(_ sealed: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) -> [UInt8]? {
        guard key.count == keyByteCount, nonce.count == nonceByteCount, sealed.count >= tagByteCount,
            let box = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: sealed.dropLast(tagByteCount),
                tag: sealed.suffix(tagByteCount)
            ),
            let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        else {
            return nil
        }
        return Array(plaintext)
    }

    /// HKDF-SHA256 with Tink's argument order (`Hkdf.computeHkdf(MAC, ikm, salt, info, size)`): the input key material,
    /// then the salt. Swapped, it still derives the right number of bytes, just not Android's, and every frame of the
    /// pair would fail; `RatchetCryptoTests` and the vectors pin the order.
    static func hkdf(_ inputKeyMaterial: [UInt8], salt: [UInt8], info: [UInt8], count: Int) -> [UInt8] {
        copiedBytes(
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: inputKeyMaterial), salt: salt, info: info, outputByteCount: count)
        )
    }

    /// `value`'s low 32 bits, most significant byte first, as Kotlin's `u32be` takes an `Int` (`:200-207`).
    static func u32be(_ value: Int) -> [UInt8] {
        bigEndian(UInt64(UInt32(truncatingIfNeeded: value)), byteCount: MemoryLayout<UInt32>.size)
    }

    /// `value`'s eight bytes, most significant first (`u64be`, `:209-210`).
    static func u64be(_ value: Int64) -> [UInt8] {
        bigEndian(UInt64(bitPattern: value), byteCount: MemoryLayout<UInt64>.size)
    }

    private static func bigEndian(_ value: UInt64, byteCount: Int) -> [UInt8] {
        (0..<byteCount).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * UInt8.bitWidth)) }
    }
}

extension RatchetCrypto.EpochKeys {
    /// The two halves of an epoch's 64-byte HKDF output.
    init(okm: [UInt8]) {
        chainKey = Array(okm.prefix(RatchetCrypto.keyByteCount))
        export = Array(okm.dropFirst(RatchetCrypto.keyByteCount))
    }
}

/// Why a ratchet primitive produced nothing. A later phase maps each case as Android maps the Tink exception behind
/// it, so the pair reads one failure the same way.
public enum RatchetCryptoError: Error, Sendable, Equatable {
    /// A raw X25519 key was not 32 bytes, which Tink refuses too (`InvalidKeyException`).
    case invalidKey
    /// An exchange came to all zeros: the public value is a low-order point, which Tink refuses before it multiplies
    /// (`RatchetCrypto.kt:56-60`). A bad `ek` maps to `BAD_HEADER`, a bad `init.eph` to the pipeline's catch-all, and
    /// neither to `AEAD_FAIL`, which counts toward a reset.
    case lowOrderPoint
    /// AES-GCM would not seal: a key or nonce of the wrong length.
    case sealing
}
