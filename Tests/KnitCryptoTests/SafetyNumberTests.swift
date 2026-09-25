import KnitCrypto
import KnitTestSupport
import Testing

/// The safety number, ported from knit-next's `SafetyNumberTest`. The two goldens were computed independently
/// in Python from `SafetyNumber.kt`'s description; A2's keyed vectors will add one computed by knit-next itself.
@Suite struct SafetyNumberTests {
    @Test func bothSidesComputeTheSameNumber() {
        let alice = SafetyNumber.compute(selfNodeId: "alice000", selfBundle: "bundleA", peerNodeId: "bob00000", peerBundle: "bundleB")
        let bob = SafetyNumber.compute(selfNodeId: "bob00000", selfBundle: "bundleB", peerNodeId: "alice000", peerBundle: "bundleA")
        #expect(alice == bob)
        #expect(alice == "50062 86021 27588 51044 52683 00018 52780 56900")
    }

    @Test func realBundlesGiveThePinnedNumber() throws {
        let card = try #require(IdentityKeys(signingSeed: fixtureBytes(32, seed: 1), agreementScalar: fixtureBytes(32, seed: 2)))
        let probe = try #require(PublicKeyBundle(encoded: GoldenVectors.file.bundle.encoded))
        let number = SafetyNumber.compute(mine: card.bundle, theirs: probe)
        #expect(number == "94780 60960 85200 30266 12352 67135 48745 81712")
        #expect(SafetyNumber.compute(mine: probe, theirs: card.bundle) == number)
    }

    @Test func aChangedKeyChangesTheNumber() {
        let original = SafetyNumber.compute(selfNodeId: "alice000", selfBundle: "bundleA", peerNodeId: "bob00000", peerBundle: "bundleB")
        let tampered = SafetyNumber.compute(selfNodeId: "alice000", selfBundle: "bundleA", peerNodeId: "bob00000", peerBundle: "bundleEVIL")
        #expect(original != tampered)
    }

    @Test func theNumberIsEightGroupsOfFiveDigits() {
        let groups = SafetyNumber.compute(selfNodeId: "a", selfBundle: "x", peerNodeId: "b", peerBundle: "y").split(separator: " ")
        #expect(groups.count == SafetyNumber.groupCount)
        let shaped = groups.allSatisfy { group in group.count == SafetyNumber.groupDigits && group.allSatisfy { $0.isASCII && $0.isNumber }
        }
        #expect(shaped)
    }
}
