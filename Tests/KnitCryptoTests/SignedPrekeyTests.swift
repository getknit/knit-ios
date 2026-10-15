import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

/// Our signed prekeys and a peer's (`IdentityKeyStore.kt`'s prekeys, `InboundPipeline.verifiedPrekey`): signed once at
/// mint, published as a `PrekeyInfo`, and taken in only when the signature verifies against the bundle in the same
/// profile and the key is 32 bytes. Signatures are verified here, never compared: CryptoKit randomizes Ed25519.
@Suite struct SignedPrekeyTests {
    private let alice = IdentityKeys.generate()
    private let bob = IdentityKeys.generate()

    private func mint(id: Int = 1, by identity: IdentityKeys) throws -> SignedPrekey {
        try SignedPrekey.mint(id: id, signedBy: identity, createdAt: 1_756_100_000_000)
    }

    @Test func aPrekeyIsSignedOnceAtMintAndPublishedAsItsInfo() throws {
        let prekey = try mint(id: 7, by: alice)
        #expect(prekey.id == 7)
        #expect(prekey.createdAt == 1_756_100_000_000)
        #expect(prekey.publicKey.count == RatchetCrypto.keyByteCount)
        #expect(prekey.signature.count == 64)
        #expect(try RatchetCrypto.KeyPair(privateKey: prekey.privateKey).publicKey == prekey.publicKey)
        let signed = RatchetCrypto.spkSigningBytes(id: 7, pub: prekey.publicKey)
        #expect(alice.bundle.isValidSignature(prekey.signature, for: signed))

        // Read twice, the record is the same bytes: the signature was kept, not made again.
        let published = prekey.info
        let republished = prekey.info
        #expect(published == PrekeyInfo(id: 7, pub: prekey.publicKey, sig: prekey.signature))
        #expect(published.encoded == republished.encoded)
    }

    @Test func aMintTakesItsKeyPairFromTheSourceItIsGiven() throws {
        let fixed = try RatchetCrypto.KeyPair(privateKey: fixtureBytes(32, seed: 41))
        let prekey = try SignedPrekey.mint(id: 1, signedBy: bob, createdAt: 0) { fixed }
        #expect(prekey.privateKey == fixed.privateKey)
        #expect(prekey.publicKey == fixed.publicKey)
        // Left to the default, each mint draws a fresh pair from the system.
        let first = try mint(by: bob)
        let second = try mint(by: bob)
        #expect(first.publicKey != second.publicKey)
    }

    @Test func aPeersPrekeyIsTakenInWhenItVerifiesAgainstItsOwnersBundle() throws {
        let published = try mint(id: 3, by: alice).info
        let taken = try #require(PeerPrekey(verifying: published, signedBy: alice.bundle))
        #expect(taken.id == 3)
        #expect(taken.publicKey == published.pub)
        // As a profile carries it: through the wire codec and back.
        let carried = try PrekeyInfo(decoding: published.encoded)
        #expect(PeerPrekey(verifying: carried, signedBy: alice.bundle) == taken)
    }

    /// Anything else counts as no prekey (`InboundPipeline.kt:3353-3368`).
    @Test func aPrekeyThatDoesNotVerifyIsNotTakenIn() throws {
        let published = try mint(id: 3, by: alice).info
        #expect(PeerPrekey(verifying: published, signedBy: bob.bundle) == nil, "someone else's key")

        var renumbered = published
        renumbered.id = 4
        #expect(PeerPrekey(verifying: renumbered, signedBy: alice.bundle) == nil, "the id is signed")

        var swapped = published
        swapped.pub = try mint(id: 3, by: alice).publicKey
        #expect(PeerPrekey(verifying: swapped, signedBy: alice.bundle) == nil, "the key is signed")

        var forged = published
        forged.sig[0] ^= 1
        #expect(PeerPrekey(verifying: forged, signedBy: alice.bundle) == nil, "a damaged signature")

        var truncated = published
        truncated.sig.removeLast()
        #expect(PeerPrekey(verifying: truncated, signedBy: alice.bundle) == nil, "a short signature")
    }

    /// A key that is not 32 bytes is refused even when its owner signed exactly those bytes.
    @Test(arguments: [31, 33, 0])
    func aSignedKeyOfTheWrongLengthIsNotTakenIn(length: Int) throws {
        let pub = fixtureBytes(length, seed: 9)
        let sig = try alice.signature(for: RatchetCrypto.spkSigningBytes(id: 1, pub: pub))
        let info = PrekeyInfo(id: 1, pub: pub, sig: sig)
        #expect(alice.bundle.isValidSignature(sig, for: RatchetCrypto.spkSigningBytes(id: 1, pub: pub)))
        #expect(PeerPrekey(verifying: info, signedBy: alice.bundle) == nil)
    }
}
