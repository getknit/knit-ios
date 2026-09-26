import KnitCrypto
import KnitTestSupport
import Testing

/// Identities minted to sort inside a window, for `knit-peer keygen` and the debug app's Diagnostics.
@Suite struct KeyGenTests {
    private func identity(_ seed: Int) throws -> IdentityKeys {
        try #require(IdentityKeys(signingSeed: fixtureBytes(32, seed: seed), agreementScalar: fixtureBytes(32, seed: seed + 100)))
    }

    @Test func keygenLandsInsideTheWindow() throws {
        let reference = try identity(1).nodeId
        #expect(try KeyGen.identity(in: KeyGen.Window(above: reference)).nodeId > reference)
        #expect(try KeyGen.identity(in: KeyGen.Window(below: reference)).nodeId < reference)
        let low = min(try identity(2).nodeId, try identity(3).nodeId)
        let high = max(try identity(2).nodeId, try identity(3).nodeId)
        let window = KeyGen.Window(above: low, below: high)
        #expect(window.contains(try KeyGen.identity(in: window).nodeId))
        #expect(!window.contains(low), "the bounds are outside")
        #expect(!window.contains(high))
    }

    @Test func boundsThatCrossOrMeetAreRefusedWithoutATry() throws {
        let low = min(try identity(2).nodeId, try identity(3).nodeId)
        let high = max(try identity(2).nodeId, try identity(3).nodeId)
        #expect(KeyGen.Window(above: high, below: low).isEmpty)
        #expect(KeyGen.Window(above: low, below: low).isEmpty)
        #expect(!KeyGen.Window(above: low, below: high).isEmpty)
        #expect(!KeyGen.Window(above: low).isEmpty && !KeyGen.Window().isEmpty)
        #expect(throws: KeyGen.Failure.noRoom(attempts: 0)) {
            try KeyGen.identity(in: KeyGen.Window(above: high, below: low)) {
                Issue.record("an empty window generates nothing")
                return IdentityKeys.generate()
            }
        }
    }

    @Test func keygenGivesUpWhenNothingLandsInTheWindow() throws {
        let only = try identity(1)
        #expect(throws: KeyGen.Failure.noRoom(attempts: 50)) {
            try KeyGen.identity(in: KeyGen.Window(above: only.nodeId), attempts: 50) { only }
        }
    }
}
