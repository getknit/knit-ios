import KnitWire
import Testing

@testable import KnitCrypto

/// The DM ratchet's primitive layer, ported case by case from knit-next's `RatchetCryptoTest` (at `ac491f4c`), then
/// what this port adds: the low-order refusal Tink makes and CryptoKit does not, and the AES-GCM the chain seals with.
/// Two anchors keep it honest, as in Kotlin: RFC 7748's vectors pin the curve, and ``referenceHKDF(ikm:salt:info:count:)``,
/// built on HMAC alone, cross-checks every HKDF call and its argument order. knit-next's own known answers are
/// `RatchetVectorTests`'.
@Suite struct RatchetCryptoTests {
    // MARK: RFC 7748

    /// #172 (`RatchetCryptoTest.kt` at `4f3cd995`): the probe answers what every DH against the key would, so a prekey it
    /// refuses is never pinned. The order-8 point and a non-canonical encoding of zero are this port's: swift-crypto reaches
    /// them as zeros, where Tink refuses them by list.
    @Test func acceptsPublicKeyRefusesWhatX25519Refuses() {
        #expect(RatchetCrypto.acceptsPublicKey(RatchetCrypto.generateKeyPair().publicKey))
        #expect(!RatchetCrypto.acceptsPublicKey([UInt8](repeating: 0, count: RatchetCrypto.keyByteCount)), "the zero point")
        #expect(!RatchetCrypto.acceptsPublicKey([1] + [UInt8](repeating: 0, count: RatchetCrypto.keyByteCount - 1)), "u = 1, order 1")
        #expect(!RatchetCrypto.acceptsPublicKey([UInt8](repeating: 9, count: 31)), "a short key")
        #expect(!RatchetCrypto.acceptsPublicKey(hexBytes("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800")), "order 8")
        #expect(
            !RatchetCrypto.acceptsPublicKey(hexBytes("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")),
            "p, which is zero")
    }

    @Test func x25519MatchesRfc7748Vector1() throws {
        let scalar = hexBytes("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
        let uCoordinate = hexBytes("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
        let expected = hexBytes("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
        #expect(try RatchetCrypto.dh(scalar, uCoordinate) == expected)
    }

    @Test func x25519MatchesRfc7748DiffieHellman() throws {
        let alicePriv = hexBytes("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        let bobPriv = hexBytes("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        let alicePub = hexBytes("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        let bobPub = hexBytes("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        let shared = hexBytes("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")

        #expect(try RatchetCrypto.KeyPair(privateKey: alicePriv).publicKey == alicePub)
        #expect(try RatchetCrypto.dh(alicePriv, bobPub) == shared)
        #expect(try RatchetCrypto.dh(bobPriv, alicePub) == shared)
    }

    // MARK: X3DH

    @Test func x3dhBothSidesDeriveTheSameRoot() throws {
        let (ikA, ikB, spkB, ekA) = (fresh(), fresh(), fresh(), fresh())

        let initiator = try RatchetCrypto.x3dhInitiate(
            ikPriv: ikA.privateKey, ekPriv: ekA.privateKey, peerIkPub: ikB.publicKey, peerSpkPub: spkB.publicKey)
        let responder = try RatchetCrypto.x3dhRespond(
            ikPriv: ikB.privateKey, spkPriv: spkB.privateKey, peerIkPub: ikA.publicKey, peerEkPub: ekA.publicKey)

        #expect(initiator == responder)
        #expect(initiator.count == RatchetCrypto.keyByteCount)
    }

    @Test func x3dhMatchesTheReferenceDerivation() throws {
        let (ikA, ikB, spkB, ekA) = (fresh(), fresh(), fresh(), fresh())

        // 0xFF×32 ‖ DH1 ‖ DH2 ‖ DH3 under the x3dh label, through the independent HKDF.
        let ikm =
            [UInt8](repeating: 0xFF, count: 32)
            + (try RatchetCrypto.dh(ikA.privateKey, spkB.publicKey))
            + (try RatchetCrypto.dh(ekA.privateKey, ikB.publicKey))
            + (try RatchetCrypto.dh(ekA.privateKey, spkB.publicKey))
        let expected = referenceHKDF(ikm: ikm, salt: zeroSalt, info: Array("knit/dm/v2/x3dh".utf8), count: 32)

        let root = try RatchetCrypto.x3dhInitiate(
            ikPriv: ikA.privateKey, ekPriv: ekA.privateKey, peerIkPub: ikB.publicKey, peerSpkPub: spkB.publicKey)
        #expect(root == expected)
    }

    @Test func x3dhBindsEveryKey() throws {
        let (ikA, ikB, spkB, ekA) = (fresh(), fresh(), fresh(), fresh())
        let root = try RatchetCrypto.x3dhInitiate(
            ikPriv: ikA.privateKey, ekPriv: ekA.privateKey, peerIkPub: ikB.publicKey, peerSpkPub: spkB.publicKey)

        let (otherIk, otherEk, otherSpk) = (fresh(), fresh(), fresh())
        let withOtherIdentity = try RatchetCrypto.x3dhInitiate(
            ikPriv: otherIk.privateKey, ekPriv: ekA.privateKey, peerIkPub: ikB.publicKey, peerSpkPub: spkB.publicKey)
        let withOtherEphemeral = try RatchetCrypto.x3dhInitiate(
            ikPriv: ikA.privateKey, ekPriv: otherEk.privateKey, peerIkPub: ikB.publicKey, peerSpkPub: spkB.publicKey)
        let withOtherPrekey = try RatchetCrypto.x3dhInitiate(
            ikPriv: ikA.privateKey, ekPriv: ekA.privateKey, peerIkPub: ikB.publicKey, peerSpkPub: otherSpk.publicKey)
        #expect(root != withOtherIdentity)
        #expect(root != withOtherEphemeral)
        #expect(root != withOtherPrekey)
    }

    // MARK: Epochs and chains

    @Test func epochDerivationMatchesTheReference() {
        let root = deterministicBytes(1)
        let dh = deterministicBytes(2)

        let keys = RatchetCrypto.deriveEpoch(sessionRoot: root, dhShared: dh, senderIsInitiator: true, senderEpoch: 3, baseEpoch: 2)

        let info = Array("knit/dm/v2/epoch".utf8) + [UInt8(ascii: "i")] + [0, 0, 0, 3] + [0, 0, 0, 2]
        // The exchange is the input key material and the root the salt: the order Tink's `Hkdf.computeHkdf` takes.
        let okm = referenceHKDF(ikm: dh, salt: root, info: info, count: 64)
        #expect(keys.chainKey == Array(okm.prefix(32)))
        #expect(keys.export == Array(okm.suffix(32)))
    }

    @Test func epochDerivationBindsDirectionAndCounters() {
        let root = deterministicBytes(1)
        let dh = deterministicBytes(2)
        let base = RatchetCrypto.deriveEpoch(sessionRoot: root, dhShared: dh, senderIsInitiator: true, senderEpoch: 1, baseEpoch: 0)

        let responder = RatchetCrypto.deriveEpoch(sessionRoot: root, dhShared: dh, senderIsInitiator: false, senderEpoch: 1, baseEpoch: 0)
        let laterEpoch = RatchetCrypto.deriveEpoch(sessionRoot: root, dhShared: dh, senderIsInitiator: true, senderEpoch: 2, baseEpoch: 0)
        let laterBase = RatchetCrypto.deriveEpoch(sessionRoot: root, dhShared: dh, senderIsInitiator: true, senderEpoch: 1, baseEpoch: 1)
        #expect(base.chainKey != responder.chainKey)
        #expect(base.chainKey != laterEpoch.chainKey)
        #expect(base.chainKey != laterBase.chainKey)
    }

    @Test func chainStepsMatchTheReferenceAndNeverCollide() {
        let chain0 = deterministicBytes(7)

        let message0 = RatchetCrypto.messageKey(chain0)
        let chain1 = RatchetCrypto.nextChainKey(chain0)
        let message1 = RatchetCrypto.messageKey(chain1)

        #expect(message0 == referenceHKDF(ikm: chain0, salt: zeroSalt, info: Array("knit/dm/v2/mk".utf8), count: 32))
        #expect(chain1 == referenceHKDF(ikm: chain0, salt: zeroSalt, info: Array("knit/dm/v2/ck".utf8), count: 32))
        #expect(message0 != chain1)
        #expect(message0 != message1)
    }

    // MARK: v3: the derived nonce and the header binding

    @Test func theV3NonceMatchesTheReferenceAndIsBoundToTheAad() {
        let messageKey = RatchetCrypto.messageKey(deterministicBytes(7))
        let aad = Array("m1|alice|100|bob".utf8)

        let nonce = RatchetCrypto.messageNonce(messageKey: messageKey, aad: aad)
        #expect(nonce.count == 12)
        #expect(nonce == referenceHKDF(ikm: messageKey, salt: zeroSalt, info: Array("knit/dm/v3/nonce".utf8) + aad, count: 12))
        // Another frame, so another AAD, under the same key derives another nonce: the rollback posture.
        #expect(nonce != RatchetCrypto.messageNonce(messageKey: messageKey, aad: Array("m2|alice|100|bob".utf8)))
        // And the label keeps it apart from the chain's derivations of the same key.
        #expect(nonce != Array(RatchetCrypto.messageKey(messageKey).prefix(12)))
        #expect(nonce != Array(RatchetCrypto.nextChainKey(messageKey).prefix(12)))
    }

    @Test func theV3HeaderBindingLayoutIsFrozen() {
        let ek = deterministicBytes(5)
        let eph = deterministicBytes(6)
        let label = Array("knit/dm/v3/hdr".utf8)

        let bare = RatchetCrypto.headerBindingBytes(RatchetHeader(se: 0x0102_0304, ek: ek, pe: 0x0000_0005, n: 0x0000_0600, flags: 1))
        #expect(Array(bare.prefix(label.count)) == label)
        var at = label.count
        #expect(Array(bare[at..<at + 4]) == [1, 2, 3, 4])
        at += 4
        #expect(Array(bare[at..<at + 32]) == ek)
        at += 32
        #expect(Array(bare[at..<at + 4]) == [0, 0, 0, 5])
        at += 4
        #expect(Array(bare[at..<at + 4]) == [0, 0, 6, 0])
        at += 4
        #expect(Array(bare[at..<at + 2]) == [1, 0], "flags, then no init")
        #expect(bare.count == at + 2)

        let initial = RatchetInit(eph: eph, pkid: 0x0000_0007, at: 0x0102_0304_0506_0708)
        let withInit = RatchetCrypto.headerBindingBytes(RatchetHeader(se: 1, ek: ek, pe: 0, n: 0, initial: initial))
        let tail = Array(withInit.suffix(1 + 32 + 4 + 8))
        #expect(tail == [1] + eph + [0, 0, 0, 7] + [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(bare != withInit)
        #expect(bare.count == 60)
        #expect(withInit.count == 104)
    }

    // MARK: The prekey's bytes and the root tag

    @Test func spkSigningBytesLayoutIsFrozen() {
        let pub = deterministicBytes(9)
        let bytes = RatchetCrypto.spkSigningBytes(id: 0x0102_0304, pub: pub)

        let label = Array("knit/dm/v2/spk".utf8)
        #expect(Array(bytes.prefix(label.count)) == label)
        #expect(Array(bytes[label.count..<label.count + 4]) == [1, 2, 3, 4])
        #expect(Array(bytes.dropFirst(label.count + 4)) == pub)
        #expect(bytes.count == 50)
    }

    // `exportsMatchTheReferenceAndStayDomainSeparated` is not ported: ADR 2026-10.5sk9 leaves the spool's exports
    // (`exportRoot`, `exportEpochSeal`) out of this port, so there is no code here for it to check.

    /// The receive-state tag (knit-next ADR 2026-10.gcrd): eight HKDF bytes, big-endian, under their own label. Local.
    @Test func theRootTagIsTheReferenceHkdfReadBigEndianAndSeparatesRoots() {
        let root = deterministicBytes(5)
        let bytes = referenceHKDF(ikm: root, salt: zeroSalt, info: Array("knit/dm/v2/root-tag".utf8), count: 8)
        let expected = Int64(bitPattern: bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        #expect(RatchetCrypto.rootTag(root) == expected)
        #expect(RatchetCrypto.rootTag(root) != RatchetCrypto.rootTag(deterministicBytes(6)))
    }

    // MARK: What this port adds

    /// Tink's banned public values (`Curve25519.BANNED_PUBLIC_KEYS`): zero, one, the two points of order eight, and
    /// p - 1, p and p + 1, little-endian. Tink clears the top bit first, so zero with it set stands for that rule. Each
    /// sends every exchange to zero.
    private static let lowOrderPoints = [
        [UInt8](repeating: 0, count: 32),
        [1] + [UInt8](repeating: 0, count: 31),
        hexBytes("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"),
        hexBytes("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157"),
        hexBytes("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
        hexBytes("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
        hexBytes("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
        [UInt8](repeating: 0, count: 31) + [0x80],
    ]

    /// Tink throws on a low-order public value and CryptoKit returns zeros, so the ratchet refuses the zeros with a
    /// typed error a later phase maps as Android maps the throw: never to `AEAD_FAIL` (`RatchetCrypto.kt:56-60`).
    @Test(arguments: lowOrderPoints)
    func aLowOrderPublicValueIsRefusedNotZeroed(point: [UInt8]) {
        let (ik, peerIk, spk, ek) = (fresh(), fresh(), fresh(), fresh())
        #expect(throws: RatchetCryptoError.lowOrderPoint) {
            try RatchetCrypto.dh(ek.privateKey, point)
        }
        // A bad prekey or peer identity on the initiator's side, and a bad init ephemeral on the responder's.
        #expect(throws: RatchetCryptoError.lowOrderPoint) {
            try RatchetCrypto.x3dhInitiate(ikPriv: ik.privateKey, ekPriv: ek.privateKey, peerIkPub: peerIk.publicKey, peerSpkPub: point)
        }
        #expect(throws: RatchetCryptoError.lowOrderPoint) {
            try RatchetCrypto.x3dhInitiate(ikPriv: ik.privateKey, ekPriv: ek.privateKey, peerIkPub: point, peerSpkPub: spk.publicKey)
        }
        #expect(throws: RatchetCryptoError.lowOrderPoint) {
            try RatchetCrypto.x3dhRespond(ikPriv: ik.privateKey, spkPriv: spk.privateKey, peerIkPub: peerIk.publicKey, peerEkPub: point)
        }
    }

    @Test func aKeyThatIsNot32BytesIsRefused() {
        let pair = fresh()
        #expect(throws: RatchetCryptoError.invalidKey) {
            try RatchetCrypto.dh(Array(pair.privateKey.dropLast()), pair.publicKey)
        }
        #expect(throws: RatchetCryptoError.invalidKey) {
            try RatchetCrypto.dh(pair.privateKey, pair.publicKey + [0])
        }
        #expect(throws: RatchetCryptoError.invalidKey) {
            try RatchetCrypto.KeyPair(privateKey: [])
        }
    }

    /// Tink's `Hkdf.computeHkdf(MAC, ikm, salt, info, size)` takes the input key material first: pinned here on its own,
    /// apart from every derivation that leans on it.
    @Test func theHKDFTakesItsInputKeyMaterialFirstThenTheSalt() {
        let ikm = deterministicBytes(11)
        let salt = deterministicBytes(12)
        let info = Array("knit/dm/v2/order".utf8)
        let derived = RatchetCrypto.hkdf(ikm, salt: salt, info: info, count: 32)
        #expect(derived == referenceHKDF(ikm: ikm, salt: salt, info: info, count: 32))
        #expect(derived != referenceHKDF(ikm: salt, salt: ikm, info: info, count: 32))
    }

    @Test func freshKeyPairsComeFromTheSystemAndDiffer() throws {
        let one = RatchetCrypto.generateKeyPair()
        let two = RatchetCrypto.generateKeyPair()
        #expect(one.privateKey != two.privateKey)
        #expect(one.publicKey.count == RatchetCrypto.keyByteCount)
        #expect(try RatchetCrypto.KeyPair(privateKey: one.privateKey).publicKey == one.publicKey)
    }

    /// The chain's AES-GCM (`AesGcm`, `Crypto.kt:36-81`): a body opens under its own key, nonce and AAD only.
    @Test func aBodyOpensUnderItsOwnKeyNonceAndAadOnly() throws {
        let key = RatchetCrypto.messageKey(deterministicBytes(3))
        let nonce = RatchetCrypto.messageNonce(messageKey: key, aad: [1])
        let aad = Array("m1|alice|100|bob".utf8)
        let sealed = try RatchetCrypto.seal(Array("hi bob".utf8), key: key, nonce: nonce, aad: aad)
        #expect(sealed.count == 6 + RatchetCrypto.tagByteCount)
        #expect(RatchetCrypto.open(sealed, key: key, nonce: nonce, aad: aad) == Array("hi bob".utf8))

        #expect(RatchetCrypto.open(sealed, key: RatchetCrypto.nextChainKey(key), nonce: nonce, aad: aad) == nil)
        #expect(RatchetCrypto.open(sealed, key: key, nonce: Array(nonce.reversed()), aad: aad) == nil)
        #expect(RatchetCrypto.open(sealed, key: key, nonce: nonce, aad: aad + [0]) == nil)
        var tampered = sealed
        tampered[0] ^= 1
        #expect(RatchetCrypto.open(tampered, key: key, nonce: nonce, aad: aad) == nil)
        #expect(RatchetCrypto.open(Array(sealed.prefix(15)), key: key, nonce: nonce, aad: aad) == nil)
        #expect(RatchetCrypto.open(sealed, key: Array(key.prefix(16)), nonce: nonce, aad: aad) == nil)
        #expect(RatchetCrypto.open(sealed, key: key, nonce: nonce + [0], aad: aad) == nil)
    }

    @Test func aKeyOrNonceOfTheWrongLengthDoesNotSeal() {
        let key = deterministicBytes(4)
        #expect(throws: RatchetCryptoError.sealing) {
            try RatchetCrypto.seal([1], key: Array(key.prefix(16)), nonce: Array(key.prefix(12)), aad: [])
        }
        #expect(throws: RatchetCryptoError.sealing) {
            try RatchetCrypto.seal([1], key: key, nonce: Array(key.prefix(16)), aad: [])
        }
    }

    private func fresh() -> RatchetCrypto.KeyPair {
        RatchetCrypto.generateKeyPair()
    }
}
