import Testing

@testable import KnitCrypto

/// The group form's primitives, ported case by case from knit-next's `GroupRatchetCryptoTest` (at `ac491f4c`), against
/// the same independent HKDF as ``RatchetCryptoTests``.
@Suite struct GroupRatchetCryptoTests {
    @Test func epochDerivationMatchesTheReference() {
        let seed = deterministicBytes(1)

        let keys = GroupRatchetCrypto.deriveEpoch(seed: seed, groupId: "g-abc123", senderId: "alice000", epoch: 3)

        let info = Array("knit/group/v1/epoch".utf8) + Array("g-abc123|alice000|".utf8) + [0, 0, 0, 3]
        let okm = referenceHKDF(ikm: seed, salt: zeroSalt, info: info, count: 64)
        #expect(keys.chainKey == Array(okm.prefix(32)))
        #expect(keys.export == Array(okm.suffix(32)))
        #expect(GroupRatchetCrypto.epochInfo(groupId: "g-abc123", senderId: "alice000", epoch: 3) == info)
    }

    @Test func epochDerivationBindsGroupSenderAndEpoch() {
        let seed = deterministicBytes(2)
        let base = GroupRatchetCrypto.deriveEpoch(seed: seed, groupId: "g-1", senderId: "alice000", epoch: 1)

        #expect(base.chainKey != GroupRatchetCrypto.deriveEpoch(seed: seed, groupId: "g-2", senderId: "alice000", epoch: 1).chainKey)
        #expect(base.chainKey != GroupRatchetCrypto.deriveEpoch(seed: seed, groupId: "g-1", senderId: "bob00000", epoch: 1).chainKey)
        #expect(base.chainKey != GroupRatchetCrypto.deriveEpoch(seed: seed, groupId: "g-1", senderId: "alice000", epoch: 2).chainKey)
    }

    @Test func chainStepsMatchTheReferenceAndStayDisjointFromTheDmLabels() {
        let chain0 = deterministicBytes(7)

        let message0 = GroupRatchetCrypto.messageKey(chain0)
        let chain1 = GroupRatchetCrypto.nextChainKey(chain0)

        #expect(message0 == referenceHKDF(ikm: chain0, salt: zeroSalt, info: Array("knit/group/v1/mk".utf8), count: 32))
        #expect(chain1 == referenceHKDF(ikm: chain0, salt: zeroSalt, info: Array("knit/group/v1/ck".utf8), count: 32))
        // The same bytes under the DM labels derive other keys: the separation that keeps the two schemes' keys apart.
        #expect(message0 != RatchetCrypto.messageKey(chain0))
        #expect(chain1 != RatchetCrypto.nextChainKey(chain0))
        #expect(message0 != chain1)
    }

    // `exportMatchesTheReferenceAndStaysDomainSeparated` is not ported: ADR 2026-10.5sk9 leaves the spool's exports
    // (`exportEpochSeal`) out of this port, so there is no code here for it to check.

    @Test func freshSeedsAreDistinctAndSized() {
        let one = GroupRatchetCrypto.newSeed()
        let two = GroupRatchetCrypto.newSeed()

        #expect(one.count == GroupRatchetCrypto.seedByteCount)
        #expect(one != two)
    }
}
