import Crypto
import Foundation
import Testing

/// v1 DMs wrap their body key with HPKE base mode, DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM, the
/// suite knit-next's Tink template names. This opens the CFRG test vector for that suite on the recipient side
/// (mode 0, kem 0x20, kdf 0x01, aead 0x02), which proves the same primitive runs on Linux as on the phone.
/// `HPKE.Sender` cannot take a fixed ephemeral key, so the vector is checked in the open direction only.
@Suite struct HPKEVectorTests {
    @Test func opensTheCFRGBaseModeVector() throws {
        let recipientKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: hexBytes("497b4502664cfea5d5af0b39934dac72242a74f8480451e1aee7d6a53320333d")
        )
        #expect(
            Array(recipientKey.publicKey.rawRepresentation)
                == hexBytes("430f4b9859665145a6b1ba274024487bd66f03a2dd577d7753c68d7d7d00c00c")
        )

        var recipient = try HPKE.Recipient(
            privateKey: recipientKey,
            ciphersuite: HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256),
            info: Data(hexBytes("4f6465206f6e2061204772656369616e2055726e")),
            encapsulatedKey: Data(hexBytes("6c93e09869df3402d7bf231bf540fadd35cd56be14f97178f0954db94b7fc256"))
        )
        let plaintext = try recipient.open(
            hexBytes("e5d84cd531cfb583096e7cfa9641bd3079cf3a91cda813c52deb5f512be9931980a41de125a925cdad859d5b7a"),
            authenticating: hexBytes("436f756e742d30")
        )
        #expect(Array(plaintext) == hexBytes("4265617574792069732074727574682c20747275746820626561757479"))
    }
}
