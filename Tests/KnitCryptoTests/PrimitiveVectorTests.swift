import Crypto
import Foundation
import KnitCrypto
import Testing

/// The RFC known-answer tests for each primitive v1 uses, run through swift-crypto: BoringSSL on Linux,
/// CryptoKit on Apple platforms. Each vector was also checked against Python's `cryptography` package.
@Suite struct PrimitiveVectorTests {
    /// RFC 7748 §6.1: Alice and Bob derive each other's public keys and the same shared secret.
    @Test func x25519MatchesRFC7748() throws {
        let alice = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: hexBytes("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        )
        let bob = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: hexBytes("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        )
        #expect(
            Array(alice.publicKey.rawRepresentation) == hexBytes("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        )
        #expect(
            Array(bob.publicKey.rawRepresentation) == hexBytes("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        )
        let shared = try alice.sharedSecretFromKeyAgreement(with: bob.publicKey)
        #expect(
            shared.withUnsafeBytes { Array($0) } == hexBytes("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
        )
    }

    /// RFC 8032 §7.1 tests 1 to 3: an identity restored from the secret key derives the public key, and the
    /// RFC's signature verifies. Signatures are only ever verified, because CryptoKit's are randomized.
    @Test(arguments: [
        (
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
            "",
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
                + "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
        ),
        (
            "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
            "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
            "72",
            "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
                + "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"
        ),
        (
            "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
            "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
            "af82",
            "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac"
                + "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"
        ),
    ])
    func ed25519MatchesRFC8032(secret: String, publicKey: String, message: String, signature: String) throws {
        let identity = try #require(IdentityKeys(signingSeed: hexBytes(secret), agreementScalar: fixtureScalar))
        #expect(identity.bundle.signingKey == hexBytes(publicKey))
        #expect(identity.bundle.isValidSignature(hexBytes(signature), for: hexBytes(message)))

        var tampered = hexBytes(signature)
        tampered[0] ^= 1
        #expect(!identity.bundle.isValidSignature(tampered, for: hexBytes(message)))
        #expect(!identity.bundle.isValidSignature(Array(hexBytes(signature).dropLast()), for: hexBytes(message)))
        let ours = try identity.signature(for: hexBytes(message))
        #expect(identity.bundle.isValidSignature(ours, for: hexBytes(message)))
    }

    /// RFC 5869 test case 1, HKDF-SHA256: the KDF inside HPKE, and the one the ratchet will use directly.
    @Test func hkdfMatchesRFC5869() {
        let output = HKDF<SHA256>
            .deriveKey(
                inputKeyMaterial: SymmetricKey(data: [UInt8](repeating: 0x0B, count: 22)),
                salt: hexBytes("000102030405060708090a0b0c"),
                info: hexBytes("f0f1f2f3f4f5f6f7f8f9"),
                outputByteCount: 42
            )
        #expect(
            output.withUnsafeBytes { Array($0) }
                == hexBytes("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
        )
    }

    /// McGrew and Viega's GCM test case 16: AES-256 with a 12-byte nonce and AAD, the body cipher of every v1 DM.
    @Test func aesGCMMatchesTheGCMSpecification() throws {
        let key = SymmetricKey(data: hexBytes("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"))
        let nonce = try AES.GCM.Nonce(data: hexBytes("cafebabefacedbaddecaf888"))
        let aad = hexBytes("feedfacedeadbeeffeedfacedeadbeefabaddad2")
        let plaintext = hexBytes(
            "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a31"
                + "8a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39"
        )
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        #expect(
            Array(box.ciphertext)
                == hexBytes(
                    "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555"
                        + "d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662"
                )
        )
        #expect(Array(box.tag) == hexBytes("76fc6ece0f4e1768cddf8853bb2d551b"))
        #expect(try Array(AES.GCM.open(box, using: key, authenticating: aad)) == plaintext)
        #expect(throws: (any Error).self) {
            try AES.GCM.open(box, using: key, authenticating: Array(aad.dropLast()))
        }
    }

    private var fixtureScalar: [UInt8] { [UInt8](repeating: 7, count: 32) }
}
