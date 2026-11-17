import KnitTestSupport
import Testing

@testable import KnitCrypto

/// knit-next's scope vectors (`ScopeVectorTest`, `docs/SPOOL_PROTOCOL.md` §13, at `0832b8462`), read from
/// `spool-v1.json` (ADR 2026-11.adrq): the DM scope's id and keys, the deterministic seal and its blob id, the digest, and
/// the proof-of-work stamp. Kotlin made the answers, so a match here is a match with Android and the spool daemon.
///
/// Left out with what they pin: the group, pair and commons rows, the attachment chunk, and the typing sig.
@Suite struct ScopeVectorTests {
    private static let powDay: Int64 = 20_680
    private static let powBits = 8
    private static let powN: Int64 = 8

    private var pairwiseRoot: [UInt8] { SpoolVectors.bytes("Inputs", "pairwiseRoot") }
    private var keys: ScopeKeys {
        ScopeCrypto.dmScope(
            pairwiseRoot: pairwiseRoot, idText: SpoolVectors.text("Inputs", "nodeIdA"), SpoolVectors.text("Inputs", "nodeIdB"))
    }

    @Test func theInputsAreTheSpecsFixtures() {
        #expect(pairwiseRoot == SpoolVectors.fixture(32, seed: 1))
        #expect(SpoolVectors.bytes("Inputs", "sig") == SpoolVectors.fixture(64, seed: 4))
        #expect(SpoolVectors.bytes("Inputs", "signed") == SpoolVectors.fixture(40, seed: 5))
        #expect(SpoolVectors.bytes("PoW", "scopeId") == SpoolVectors.fixture(32, seed: 9))
    }

    @Test func theDMScopeIsPinned() {
        #expect(keys.id == SpoolVectors.bytes("Derivations", "dmScopeId"))
        #expect(keys.sealKey == SpoolVectors.bytes("Derivations", "dmSealKey"))
        #expect(keys.nonceKey == SpoolVectors.bytes("Derivations", "dmNonceKey"))
    }

    /// The seal is a function of the scope and the frame alone (C-4.3-1): sealing twice makes the pinned bytes twice.
    @Test func theSealIsPinnedAndSealingTwiceIsByteIdentical() throws {
        let sig = SpoolVectors.bytes("Inputs", "sig")
        let signed = SpoolVectors.bytes("Inputs", "signed")
        let sealed = try #require(ScopeCrypto.seal(keys, sig: sig, signed: signed))
        #expect(sealed.blob == SpoolVectors.bytes("Seal", "blob"))
        #expect(sealed.blobId == SpoolVectors.bytes("Seal", "blobId"))
        let again = try #require(ScopeCrypto.seal(keys, sig: sig, signed: signed))
        #expect(again.blob == sealed.blob && again.blobId == sealed.blobId)
        let opened = try #require(ScopeCrypto.open(keys, blobId: sealed.blobId, blob: sealed.blob))
        #expect(opened.sig == sig && opened.signed == signed)
    }

    @Test func bothDigestsArePinned() {
        #expect(ScopeCrypto.digestBytes(ScopeCrypto.digest(of: [[UInt8]]())) == SpoolVectors.bytes("Digest", "digest(∅)"))
        let ids = [11, 12, 13].map { SpoolVectors.fixture(32, seed: $0) }
        #expect(
            ScopeCrypto.digestBytes(ScopeCrypto.digest(of: ids))
                == SpoolVectors.bytes("Digest", "digest({fixture(32,11), fixture(32,12), fixture(32,13)})"))
    }

    /// `thePinnedPowStampIsTheSmallestAndVerifies`: mining finds n = 8, whose digest is §13's, with exactly as many leading
    /// zero bits as it has and not one more.
    @Test func thePinnedStampIsTheSmallestAndVerifies() {
        let scopeId = SpoolVectors.bytes("PoW", "scopeId")
        #expect(SpoolPow.mine(scopeId: scopeId, day: Self.powDay, bits: Self.powBits) == Self.powN)
        let digest = SpoolPow.digest(scopeId: scopeId, day: Self.powDay, n: Self.powN)
        #expect(digest == SpoolVectors.bytes("PoW", "SHA-256(input)"))
        #expect(SpoolPow.verify(scopeId: scopeId, day: Self.powDay, n: Self.powN, bits: Self.powBits))
        let exact = SpoolPow.leadingZeroBits(digest)
        #expect(!SpoolPow.verify(scopeId: scopeId, day: Self.powDay, n: Self.powN, bits: exact + 1))
    }
}
