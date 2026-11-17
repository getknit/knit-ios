import Crypto
import KnitWire
import Testing

@testable import KnitCrypto

/// The DM half of knit-next's `ScopeCryptoTest` (`mesh/crypto/scope/`, at `0832b8462`; ADR 2026-11.adrq): every
/// derivation against the RFC 5869 HKDF built on HMAC alone, the seal's determinism and scope binding, the digest's fold,
/// and every way a hostile spool's blob is refused without a trap. §13's bytes are pinned in ``ScopeVectorTests``.
///
/// Left out with what they test: `groupDerivationsBindGroupIdAndRootVersion`, `pairScopeIdIsSymmetric…`, the attachment
/// and chunk cases (`attachmentId…`, `chunkSeal…`, `chunkNonce…`, `frameAndChunkSealsCannotBeFedToEachOther`), and the
/// commons and chunk halves of `malformedInputsAreRefusedBeforeAnyCipherRuns`.
@Suite struct ScopeCryptoTests {
    // Valid-shape fixtures, Kotlin's: 26 characters of base32, not canonical node ids.
    static let nodeA = "aaaaabbbbbcccccdddddeeeeef"
    static let nodeB = "zzzzzyyyyyxxxxxwwwwwvvvvvu"

    /// knit-next's `deterministicBytes(seed, n)`: `(31 i + 131 seed) & 0xFF`.
    static func bytes(_ seed: Int, count: Int = 32) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 * 31 + seed * 131) }
    }

    static func keys(_ seed: Int = 1) -> ScopeKeys {
        ScopeCrypto.dmScope(pairwiseRoot: bytes(seed), idText: nodeA, nodeB)
    }

    static func sealed(_ keys: ScopeKeys = keys()) throws -> (blob: [UInt8], blobId: [UInt8]) {
        try #require(ScopeCrypto.seal(keys, sig: bytes(4, count: 64), signed: bytes(5, count: 40)))
    }

    // MARK: Derivations

    @Test func theDMScopeIdIsTheReferenceAndOrderInsensitive() {
        let root = Self.bytes(1)
        let keys = ScopeCrypto.dmScope(pairwiseRoot: root, idText: Self.nodeA, Self.nodeB)
        let info = Array("knit/scope/v1/dm/id".utf8) + Array("\(Self.nodeA)|\(Self.nodeB)|".utf8)
        #expect(keys.id == referenceHKDF(ikm: root, salt: zeroSalt, info: info, count: 32))
        #expect(ScopeCrypto.dmScope(pairwiseRoot: root, idText: Self.nodeB, Self.nodeA).id == keys.id)
        #expect(keys.id.count == ScopeCrypto.idByteCount)
    }

    @Test func theDMSealKeysAreTheReferenceAndDifferFromTheScopeId() {
        let root = Self.bytes(1)
        let keys = ScopeCrypto.dmScope(pairwiseRoot: root, idText: Self.nodeB, Self.nodeA)
        let info = Array("knit/scope/v1/seal".utf8) + Array("\(Self.nodeA)|\(Self.nodeB)|".utf8)
        let okm = referenceHKDF(ikm: root, salt: zeroSalt, info: info, count: 64)
        #expect(keys.sealKey == Array(okm.prefix(32)))
        #expect(keys.nonceKey == Array(okm.suffix(32)))
        #expect(keys.sealKey != keys.id)
        #expect(keys.sealKey != keys.nonceKey)
    }

    /// The typed form sorts node ids as the text form does, whichever side asks: the ids' ASCII order, which is Kotlin's
    /// UTF-16 `minOf` (a digit sorts before a letter, where the raw bytes might not).
    @Test func nodeIdsDeriveTheScopeTheirTextDoesFromEitherSide() throws {
        let root = Self.bytes(2)
        for _ in 0..<16 {
            let one = IdentityKeys.generate().nodeId
            let other = IdentityKeys.generate().nodeId
            let ours = ScopeCrypto.dmScope(pairwiseRoot: root, one, other)
            let theirs = ScopeCrypto.dmScope(pairwiseRoot: root, other, one)
            let (low, high) = one < other ? (one, other) : (other, one)
            let text = ScopeCrypto.dmScope(pairwiseRoot: root, idText: low.string, high.string)
            #expect(ours.id == theirs.id && ours.sealKey == theirs.sealKey && ours.nonceKey == theirs.nonceKey)
            #expect(ours.id == text.id && ours.sealKey == text.sealKey && ours.nonceKey == text.nonceKey)
        }
        let digitFirst = try #require(NodeId("2aaaaaaaaaaaaaaaaaaaaaaaaa"))
        let letterFirst = try #require(NodeId("aaaaaaaaaaaaaaaaaaaaaaaaaa"))
        let info = Array("knit/scope/v1/dm/id".utf8) + Array("\(digitFirst.string)|\(letterFirst.string)|".utf8)
        #expect(
            ScopeCrypto.dmScope(pairwiseRoot: root, letterFirst, digitFirst).id
                == referenceHKDF(ikm: root, salt: zeroSalt, info: info, count: 32))
    }

    @Test func theDerivationsStayApartFromTheRatchetsExport() {
        let root = Self.bytes(3)
        let keys = ScopeCrypto.dmScope(pairwiseRoot: root, idText: Self.nodeA, Self.nodeB)
        #expect(keys.id != RatchetCrypto.exportRoot(root))
        #expect(keys.sealKey != RatchetCrypto.exportRoot(root))
    }

    /// The keys are secrets: nothing that describes or reflects the value shows one.
    @Test func scopeKeysShowNoKey() {
        let keys = Self.keys()
        #expect(Mirror(reflecting: keys).children.isEmpty)
        var dumped = ""
        dump(keys, to: &dumped)
        for text in [String(describing: keys), String(reflecting: keys), "\(keys)", dumped] {
            for secret in [keys.sealKey, keys.nonceKey] {
                #expect(!text.contains(Hex.encode(secret)))
                #expect(!text.contains(String(secret[0])))
            }
        }
    }

    // MARK: The seal

    @Test func theSealIsDeterministicAndRoundTrips() throws {
        let keys = Self.keys()
        let sealed = try Self.sealed(keys)
        let again = try Self.sealed(keys)
        #expect(again.blob == sealed.blob && again.blobId == sealed.blobId)
        #expect(sealed.blobId == ScopeCrypto.blobId(of: sealed.blob))
        let opened = try #require(ScopeCrypto.open(keys, blobId: sealed.blobId, blob: sealed.blob))
        #expect(opened.sig == Self.bytes(4, count: 64))
        #expect(opened.signed == Self.bytes(5, count: 40))
    }

    @Test func theSealedNonceIsTheReferenceDerivation() throws {
        let keys = Self.keys()
        let sealed = try Self.sealed(keys)
        let hash = Array(SHA256.hash(data: Self.bytes(4, count: 64) + Self.bytes(5, count: 40)))
        let nonce = referenceHKDF(ikm: keys.nonceKey, salt: zeroSalt, info: Array("knit/scope/v1/nonce".utf8) + hash, count: 12)
        #expect(sealed.blob.first == ScopeCrypto.sealVersion)
        #expect(Array(sealed.blob[1..<13]) == nonce)
        #expect(sealed.blob.count == 1 + 12 + 64 + 40 + 16)
    }

    /// The smallest frame a seal takes, one byte of `signed`, makes the smallest blob that opens.
    @Test func theShortestFrameMakesTheShortestBlobAndOpens() throws {
        let keys = Self.keys()
        let sealed = try #require(ScopeCrypto.seal(keys, sig: Self.bytes(4, count: 64), signed: [7]))
        #expect(sealed.blob.count == ScopeCrypto.minimumBlobByteCount)
        let opened = try #require(ScopeCrypto.open(keys, blobId: sealed.blobId, blob: sealed.blob))
        #expect(opened.signed == [7])
    }

    /// A seal takes a raw 64-byte signature over a non-empty body, as Kotlin's `require`s do.
    @Test func aSealRefusesAShortSignatureOrAnEmptyBody() {
        let keys = Self.keys()
        #expect(ScopeCrypto.seal(keys, sig: Self.bytes(4, count: 63), signed: Self.bytes(5, count: 40)) == nil)
        #expect(ScopeCrypto.seal(keys, sig: Self.bytes(4, count: 65), signed: Self.bytes(5, count: 40)) == nil)
        #expect(ScopeCrypto.seal(keys, sig: Self.bytes(4, count: 64), signed: []) == nil)
    }

    // MARK: Opening what a spool sends

    /// `openRejectsTamperWrongScopeAndWrongVersion`, widened to every byte: a flip anywhere fails the AEAD even with the id
    /// recomputed over the flipped blob, and fails the hash check under the original id.
    @Test func aFlipAnywhereIsRefused() throws {
        let keys = Self.keys()
        let sealed = try Self.sealed(keys)
        for index in sealed.blob.indices {
            var tampered = sealed.blob
            tampered[index] ^= 0x01
            #expect(ScopeCrypto.open(keys, blobId: ScopeCrypto.blobId(of: tampered), blob: tampered) == nil, "byte \(index)")
            #expect(ScopeCrypto.open(keys, blobId: sealed.blobId, blob: tampered) == nil, "byte \(index)")
        }
    }

    /// A blob replanted from another scope fails the aad, and the seal key of another root fails the key.
    @Test func anotherScopeOpensNothing() throws {
        let sealed = try Self.sealed()
        #expect(ScopeCrypto.open(Self.keys(2), blobId: sealed.blobId, blob: sealed.blob) == nil)
        let mine = Self.keys()
        let otherId = try #require(ScopeKeys(id: Self.keys(2).id, sealKey: mine.sealKey, nonceKey: mine.nonceKey))
        #expect(ScopeCrypto.open(otherId, blobId: sealed.blobId, blob: sealed.blob) == nil, "the aad binds the scope id")
    }

    @Test func anIdThatIsNotTheBlobsHashIsRefused() throws {
        let keys = Self.keys()
        let sealed = try Self.sealed(keys)
        var wrong = sealed.blobId
        wrong[31] ^= 0x80
        #expect(ScopeCrypto.open(keys, blobId: wrong, blob: sealed.blob) == nil)
        #expect(ScopeCrypto.open(keys, blobId: [], blob: sealed.blob) == nil)
        #expect(ScopeCrypto.open(keys, blobId: Array(sealed.blobId.prefix(31)), blob: sealed.blob) == nil)
    }

    @Test func aWrongVersionByteIsRefused() throws {
        let keys = Self.keys()
        let sealed = try Self.sealed(keys)
        for version in [0x00, 0x02, 0x03, 0x04, 0x05, 0xFF] as [UInt8] {
            let blob = [version] + sealed.blob.dropFirst()
            #expect(ScopeCrypto.open(keys, blobId: ScopeCrypto.blobId(of: blob), blob: blob) == nil, "version \(version)")
        }
    }

    /// Every length from empty to one short of the minimum is refused before a byte is read, whatever the bytes: truncated
    /// from a real blob, and zeros behind the right version byte.
    @Test func everyTruncationIsRefusedWithoutATrap() throws {
        let keys = Self.keys()
        let sealed = try Self.sealed(keys)
        for count in 0..<ScopeCrypto.minimumBlobByteCount {
            let cut = Array(sealed.blob.prefix(count))
            #expect(ScopeCrypto.open(keys, blobId: ScopeCrypto.blobId(of: cut), blob: cut) == nil, "\(count) bytes")
            let zeros = count == 0 ? [] : [ScopeCrypto.sealVersion] + [UInt8](repeating: 0, count: count - 1)
            #expect(ScopeCrypto.open(keys, blobId: ScopeCrypto.blobId(of: zeros), blob: zeros) == nil, "\(count) zero bytes")
        }
        let trimmed = Array(sealed.blob.dropLast())
        #expect(ScopeCrypto.open(keys, blobId: ScopeCrypto.blobId(of: trimmed), blob: trimmed) == nil, "a byte off the tag")
    }

    /// A member can seal a plaintext of the signature alone under the scope's own keys, which no frame is: one byte short
    /// of the minimum, it is refused before the AEAD, as Kotlin refuses it after (`pt.size > SIG_BYTES`).
    @Test func aSealedSignatureWithNoFrameIsRefused() throws {
        let keys = Self.keys()
        let nonce = [UInt8](repeating: 9, count: 12)
        let box = try AES.GCM.seal(
            Self.bytes(4, count: 64),
            using: SymmetricKey(data: keys.sealKey),
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: Array("knit/scope/v1".utf8) + keys.id
        )
        let blob = [ScopeCrypto.sealVersion] + nonce + Array(box.ciphertext) + Array(box.tag)
        #expect(blob.count == ScopeCrypto.minimumBlobByteCount - 1)
        #expect(ScopeCrypto.open(keys, blobId: ScopeCrypto.blobId(of: blob), blob: blob) == nil)
    }

    // MARK: The digest

    @Test func theDigestFoldsOrderIndependentlyAndCancelsItself() {
        let first = Self.bytes(11)
        let second = Self.bytes(12)
        let third = Self.bytes(13)
        #expect(ScopeCrypto.digest(of: [[UInt8]]()) == 0)
        #expect(ScopeCrypto.digest(of: [first, second, third]) == ScopeCrypto.digest(of: [third, first, second]))
        #expect(ScopeCrypto.digest(of: [first, first]) == 0)
        #expect(ScopeCrypto.digest(of: [first, second]) ^ ScopeCrypto.fnv64(first) == ScopeCrypto.fnv64(second))
        #expect(
            ScopeCrypto.digest(of: [first, second, third])
                == ScopeCrypto.fnv64(first) ^ ScopeCrypto.fnv64(second) ^ ScopeCrypto.fnv64(third))
    }

    /// FNV-1a-64's known answers: the empty input is the offset basis, and "a" is the published value. The custody fold
    /// over an id's UTF-8 is the same function on the same bytes.
    @Test func fnv64IsFNV1a() {
        #expect(ScopeCrypto.fnv64([]) == 0xCBF2_9CE4_8422_2325)
        #expect(ScopeCrypto.fnv64(Array("a".utf8)) == 0xAF63_DC4C_8601_EC8C)
        #expect(ScopeCrypto.fnv64(Array("frame-id".utf8)) == StoreDigest.hash("frame-id"))
    }

    @Test func theDigestsWireFormRoundTripsBigEndian() {
        #expect(ScopeCrypto.digestBytes(0) == [UInt8](repeating: 0, count: 8))
        #expect(ScopeCrypto.digestBytes(0x0102) == [0, 0, 0, 0, 0, 0, 1, 2])
        for value: UInt64 in [0, 1, .max, 1 << 63, .max >> 1, 0x0123_4567_89AB_CDEF] {
            #expect(ScopeCrypto.digestValue(ScopeCrypto.digestBytes(value)) == value)
        }
        #expect(ScopeCrypto.digestValue([UInt8](repeating: 0, count: 7)) == nil)
        #expect(ScopeCrypto.digestValue([UInt8](repeating: 0, count: 9)) == nil)
    }

    /// A scope taken whole needs 32 bytes in each value, and then seals and opens as the derived one does.
    @Test func aScopeTakenWholeNeedsThirtyTwoBytesEach() throws {
        let keys = Self.keys()
        let whole = try #require(ScopeKeys(id: keys.id, sealKey: keys.sealKey, nonceKey: keys.nonceKey))
        let sealed = try Self.sealed(keys)
        #expect(ScopeCrypto.seal(whole, sig: Self.bytes(4, count: 64), signed: Self.bytes(5, count: 40))?.blob == sealed.blob)
        #expect(ScopeKeys(id: Array(keys.id.dropLast()), sealKey: keys.sealKey, nonceKey: keys.nonceKey) == nil)
        #expect(ScopeKeys(id: keys.id, sealKey: keys.sealKey + [0], nonceKey: keys.nonceKey) == nil)
        #expect(ScopeKeys(id: keys.id, sealKey: keys.sealKey, nonceKey: []) == nil)
    }
}
