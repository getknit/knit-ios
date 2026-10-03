import KnitCrypto
import KnitWire
import Testing

/// Photos in DMs and groups, sealed as knit-next's `AttachmentCrypto` seals them: `nonce ‖ ciphertext ‖ tag`, under a
/// fresh key, with no AAD.
@Suite struct AttachmentCryptoTests {
    private let photo = Array("a photo, sealed".utf8)

    @Test func aSealedPhotoOpensWithItsKey() throws {
        let sealed = try #require(AttachmentCrypto.seal(photo))
        #expect(sealed.key.count == AttachmentCrypto.keyByteCount)
        #expect(sealed.blob.count == AttachmentCrypto.nonceByteCount + photo.count + AttachmentCrypto.tagByteCount)
        #expect(AttachmentCrypto.open(sealed.blob, key: sealed.key) == photo)
    }

    /// Each send draws its own key and nonce, so the same photo twice is two blobs no carrier can match.
    @Test func theSamePhotoSealsToADifferentBlobEachTime() throws {
        let first = try #require(AttachmentCrypto.seal(photo))
        let second = try #require(AttachmentCrypto.seal(photo))
        #expect(first.key != second.key)
        #expect(BlobHash(of: first.blob) != BlobHash(of: second.blob))
    }

    @Test func aWrongKeyABadTagOrAShortBlobOpensNothing() throws {
        let sealed = try #require(AttachmentCrypto.seal(photo))
        var wrongKey = sealed.key
        wrongKey[0] ^= 1
        #expect(AttachmentCrypto.open(sealed.blob, key: wrongKey) == nil)
        var badTag = sealed.blob
        badTag[badTag.count - 1] ^= 1
        #expect(AttachmentCrypto.open(badTag, key: sealed.key) == nil)
        #expect(
            AttachmentCrypto.open(
                Array(sealed.blob.prefix(AttachmentCrypto.nonceByteCount + AttachmentCrypto.tagByteCount - 1)), key: sealed.key) == nil)
        #expect(AttachmentCrypto.open([], key: sealed.key) == nil)
        #expect(AttachmentCrypto.open(sealed.blob, key: Array(sealed.key.prefix(16))) == nil, "only a 32-byte key opens")
    }

    /// An empty photo still seals: a nonce and a tag, which open to nothing.
    @Test func anEmptyPhotoSealsToANonceAndATag() throws {
        let sealed = try #require(AttachmentCrypto.seal([]))
        #expect(sealed.blob.count == AttachmentCrypto.nonceByteCount + AttachmentCrypto.tagByteCount)
        #expect(AttachmentCrypto.open(sealed.blob, key: sealed.key)?.isEmpty == true)
    }

    /// A known answer at a fixed key and nonce, computed with Python's `cryptography` (AESGCM), an implementation
    /// apart from swift-crypto, as Java's `AES/GCM/NoPadding` lays it out.
    @Test func aFixedKeyAndNonceSealToTheKnownBlob() throws {
        let key = (0..<32).map(UInt8.init)
        let nonce = (100..<112).map(UInt8.init)
        let blob = try #require(AttachmentCrypto.seal(photo, key: key, nonce: nonce))
        #expect(hex(blob) == "6465666768696a6b6c6d6e6f293bae0e169d39b21e113a89b6000ee27f1ab51e0e011abb4930d733964983")
        #expect(BlobHash(of: blob).string == "4e29f1cd608d155621feb88a2316ce39890a1bdc444867e5ffac2038d6c0ca57")
        #expect(Base64.encode(key) == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
        #expect(AttachmentCrypto.open(blob, key: key) == photo)
        #expect(AttachmentCrypto.seal(photo, key: Array(key.prefix(31)), nonce: nonce) == nil)
        #expect(AttachmentCrypto.seal(photo, key: key, nonce: Array(nonce.prefix(11))) == nil)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String($0, radix: 16).count == 1 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
    }
}
