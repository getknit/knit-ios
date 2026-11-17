import Crypto
public import KnitWire

/// One spool scope's three values (ADR 2026-11.adrq): the scope id a spool stores the blobs under, and the two keys of
/// its outer seal (`SealKeys`, knit-next `ScopeCrypto.kt:136-139`, with the id beside them). Derived by
/// ``ScopeCrypto/dmScope(pairwiseRoot:_:_:)`` and handed to the spool plane, which keys every per-scope state by
/// ``id``, never by peer: a pair's live and retiring scopes are two scopes.
///
/// The keys are secrets, so the value says nothing of itself: no description, no `Codable`, and an empty mirror, so
/// neither `String(describing:)`, `dump` nor a log line interpolating it can show a key.
public struct ScopeKeys: Sendable, CustomReflectable {
    /// The scope id, 32 bytes: the only one of the three a spool is given.
    public let id: [UInt8]
    /// The AES-256-GCM key of the outer seal. A secret.
    let sealKey: [UInt8]
    /// The key the seal's synthetic nonce derives under. A secret.
    let nonceKey: [UInt8]

    /// Nothing: the keys are never reflected.
    public var customMirror: Mirror {
        Mirror(self, children: [])
    }

    /// The three values as given, each 32 bytes, or `nil`: a scope taken whole, as §13's `Derivations` rows give one, for
    /// a fixture or a harness. A caller that holds a pairwise root and two node ids derives the scope instead
    /// (``ScopeCrypto/dmScope(pairwiseRoot:_:_:)``), which only reaches the scope the peer derives.
    public init?(id: [UInt8], sealKey: [UInt8], nonceKey: [UInt8]) {
        guard [id, sealKey, nonceKey].allSatisfy({ $0.count == ScopeCrypto.idByteCount }) else {
            return nil
        }
        self.init(checkedId: id, sealKey: sealKey, nonceKey: nonceKey)
    }

    /// The three values, already 32 bytes each.
    init(checkedId id: [UInt8], sealKey: [UInt8], nonceKey: [UInt8]) {
        self.id = id
        self.sealKey = sealKey
        self.nonceKey = nonceKey
    }
}

/// The DM half of the spool's scope crypto (`ScopeCrypto`, knit-next `mesh/crypto/scope/ScopeCrypto.kt` at `0832b8462`;
/// `docs/SPOOL_PROTOCOL.md` §3.1, §4.1–4.3 and §6.3; ADR 2026-11.adrq): a DM scope's id and keys from the session's
/// `pairwiseRoot`, the deterministic outer seal over a custody frame's `sig ‖ signed`, a blob's id, and a scope's digest.
/// Pure functions over raw bytes, pinned by §13's vectors (`spool-v1.json`).
///
/// Every HKDF is SHA-256 with a salt of 32 zero bytes, the input key material first, as Tink's `Hkdf.computeHkdf`
/// takes them (``RatchetCrypto``'s helper). Every label sits under `knit/scope/v1/`, apart from the ratchet's
/// `knit/dm/v2/` and HPKE's.
///
/// Left out: pair, group and commons scopes, attachment chunks, casts and sigs (ADR 2026-11.adrq).
public enum ScopeCrypto {
    /// A scope id's, a key's and a blob id's length (`SCOPE_ID_BYTES`, `KEY_BYTES`, `BLOB_ID_BYTES`, `:31-33`).
    public static let idByteCount = 32
    /// A frame signature's length, the sealed plaintext's fixed prefix (`SIG_BYTES`, `:38`).
    public static let signatureByteCount = 64
    /// The frame seal's version, a blob's first byte (`SEAL_VERSION`, `:41`, C-4.2-2); 2 is reserved for an epoch-keyed
    /// seal nobody sends.
    public static let sealVersion: UInt8 = 0x01
    /// The shortest blob that can open: the version, the nonce, a GCM tag, a signature and one byte of `signed`. Kotlin
    /// checks `> 1 + 12 + 64` (`:298`) and leaves a shorter body to `doFinal`'s tag check; here every slice and the
    /// `SealedBox` come after this check, since a hostile spool writes these bytes and a short slice traps.
    public static let minimumBlobByteCount = 1 + nonceByteCount + tagByteCount + signatureByteCount + 1
    /// The digest's wire form: 8 bytes, big-endian (`DIGEST_BYTES`, `:35`).
    public static let digestByteCount = 8

    static let nonceByteCount = 12
    static let tagByteCount = 16
    /// The seal's HKDF output, split into the seal key and the nonce key (`SEAL_OKM_BYTES`, `:87`).
    static let sealOutputByteCount = 64

    private static let labelDMId = Array("knit/scope/v1/dm/id".utf8)
    private static let labelSeal = Array("knit/scope/v1/seal".utf8)
    private static let labelNonce = Array("knit/scope/v1/nonce".utf8)
    private static let aadPrefix = Array("knit/scope/v1".utf8)
    private static let separator = UInt8(ascii: "|")
    // FNV-1a-64 (§6.3), the custody fold's constants over raw bytes rather than an id's UTF-8 (`:129-133`).
    private static let fnvOffsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01B3

    /// A DM pair's scope (`dmScopeId` and `dmSealKeys`, `:164-175`; §3.1): `HKDF(pairwiseRoot, "knit/scope/v1/dm/id" ‖ ctx,
    /// 32)` for the id, `HKDF(pairwiseRoot, "knit/scope/v1/seal" ‖ ctx, 64)` split into the seal key and the nonce key,
    /// with `ctx = idLow ‖ "|" ‖ idHigh ‖ "|"`. Symmetric, so both members derive one scope, and keyed by a root only they
    /// hold, so a spool that knows both node ids derives nothing. `pairwiseRoot` is ``RatchetCrypto/exportRoot(_:)`` of a
    /// session root.
    public static func dmScope(pairwiseRoot: [UInt8], _ one: NodeId, _ other: NodeId) -> ScopeKeys {
        dmScope(pairwiseRoot: pairwiseRoot, idText: one.string, other.string)
    }

    /// ``dmScope(pairwiseRoot:_:_:)`` over the ids' text, as Kotlin takes them, for §13's fixtures, whose ids have a node
    /// id's shape but not its canonical last character. Internal: a caller deriving from text it read off a record could
    /// reach a scope its peer never derives, so outside this module only node ids derive one.
    ///
    /// Kotlin sorts the two strings with `minOf` and `maxOf`, by UTF-16 code unit (`dmContext`, `:533-540`); this sorts by
    /// UTF-8 byte. A node id is lowercase base32, ASCII alone, where the two orders agree, as ``NodeId``'s `<` does.
    static func dmScope(pairwiseRoot: [UInt8], idText one: String, _ other: String) -> ScopeKeys {
        let (low, high) = one.utf8.lexicographicallyPrecedes(other.utf8) ? (one, other) : (other, one)
        let context = Array(low.utf8) + [separator] + Array(high.utf8) + [separator]
        let id = RatchetCrypto.hkdf(pairwiseRoot, salt: RatchetCrypto.zeroSalt, info: labelDMId + context, count: idByteCount)
        let okm = RatchetCrypto.hkdf(pairwiseRoot, salt: RatchetCrypto.zeroSalt, info: labelSeal + context, count: sealOutputByteCount)
        return ScopeKeys(checkedId: id, sealKey: Array(okm.prefix(idByteCount)), nonceKey: Array(okm.dropFirst(idByteCount)))
    }

    /// A custody frame sealed for a scope, and the blob's id (`seal` and `blobId`, `:268-284`, `:413`; §4.3):
    /// `pt = sig ‖ signed`, `nonce = HKDF(nonceKey, "knit/scope/v1/nonce" ‖ SHA-256(pt), 12)`, `blob = 0x01 ‖ nonce ‖
    /// AES-256-GCM(sealKey, nonce, pt, aad = "knit/scope/v1" ‖ scopeId)`, `blobId = SHA-256(blob)`.
    ///
    /// Deterministic (C-4.3-1): any member sealing one frame into one scope makes the same bytes, so a spool dedups them
    /// by id and every member's digest folds the same set. The nonce is keyed (C-4.3-2), so a spool that holds a frame's
    /// bytes cannot recompute it and tie the frame to the scope. `signed` is the frame's signed bytes verbatim, and the
    /// relay's `ttl`, `hops` and `relay` stay outside.
    ///
    /// `nil` for a signature that is not 64 bytes or an empty `signed`, which no custody frame has, where Kotlin's
    /// `require` throws.
    public static func seal(_ keys: ScopeKeys, sig: [UInt8], signed: [UInt8]) -> (blob: [UInt8], blobId: [UInt8])? {
        let plaintext = sig + signed
        let nonce = RatchetCrypto.hkdf(
            keys.nonceKey, salt: RatchetCrypto.zeroSalt, info: labelNonce + Array(SHA256.hash(data: plaintext)), count: nonceByteCount)
        guard sig.count == signatureByteCount, !signed.isEmpty,
            let box = try? AES.GCM.seal(
                plaintext, using: SymmetricKey(data: keys.sealKey), nonce: AES.GCM.Nonce(data: nonce), authenticating: aadPrefix + keys.id)
        else {
            return nil
        }
        let blob = [sealVersion] + nonce + Array(box.ciphertext) + Array(box.tag)
        return (blob, blobId(of: blob))
    }

    /// The frame a blob from this scope seals, or `nil` (`open`, `:292-309`; C-4.4-1's first three steps). In order: the
    /// blob hashes to `blobId`; it is at least ``minimumBlobByteCount`` long, before any byte of it is read; its version is
    /// `0x01`; the AEAD opens under this scope's key and aad, so a blob replanted from another scope fails; and the
    /// plaintext splits into the 64-byte signature and `signed`.
    ///
    /// Every failure answers `nil`, and nothing traps, whatever a spool sends. The caller still decodes the envelope,
    /// checks its id's shape and the frame-set rule, and verifies the signature against the pinned key (§4.4).
    public static func open(_ keys: ScopeKeys, blobId: [UInt8], blob: [UInt8]) -> (sig: [UInt8], signed: [UInt8])? {
        guard self.blobId(of: blob) == blobId, blob.count >= minimumBlobByteCount, blob[0] == sealVersion else {
            return nil
        }
        let body = blob.dropFirst()
        guard
            let box = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: body.prefix(nonceByteCount)),
                ciphertext: body.dropFirst(nonceByteCount).dropLast(tagByteCount),
                tag: body.suffix(tagByteCount)
            ),
            let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: keys.sealKey), authenticating: aadPrefix + keys.id)
        else {
            return nil
        }
        // The length check above leaves at least 65 plaintext bytes, so `signed` is never empty, as Kotlin requires (`:307`).
        let opened = Array(plaintext)
        return (Array(opened.prefix(signatureByteCount)), Array(opened.dropFirst(signatureByteCount)))
    }

    /// A blob's content address, SHA-256 over all of it (`blobId`, `:413`).
    public static func blobId(of blob: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: blob))
    }

    /// A scope's digest (`scopeDigest`, `:502`; §6.3): the XOR of ``fnv64(_:)`` over the raw blob ids, 0 for none. Order
    /// does not matter and each id cancels itself, so adding or removing one is one XOR. KnitWire's `StoreDigest` folds
    /// an id's UTF-8 text, so it is not this function.
    public static func digest(of blobIds: some Sequence<[UInt8]>) -> UInt64 {
        blobIds.reduce(0) { $0 ^ fnv64($1) }
    }

    /// FNV-1a-64 over raw bytes (`fnv64`, `:505-512`).
    public static func fnv64(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(fnvOffsetBasis) { ($0 ^ UInt64($1)) &* fnvPrime }
    }

    /// A digest's wire form, 8 bytes big-endian (`digestBytes`, `:515`), as a `digest` record's `digest` carries it.
    public static func digestBytes(_ digest: UInt64) -> [UInt8] {
        (0..<digestByteCount).reversed().map { UInt8(truncatingIfNeeded: digest >> UInt64($0 * UInt8.bitWidth)) }
    }

    /// The fold value of a digest's wire form, or `nil` when it is not 8 bytes (`digestValue`, `:518-521`).
    public static func digestValue(_ bytes: [UInt8]) -> UInt64? {
        guard bytes.count == digestByteCount else {
            return nil
        }
        return bytes.reduce(0) { $0 << UInt64(UInt8.bitWidth) | UInt64($1) }
    }
}
