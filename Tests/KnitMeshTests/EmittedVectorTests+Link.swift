import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

/// Carol's link proofs in `ios-emitted-v1.json` (``EmittedLinkProofs``, `link-hello-proof`).
extension EmittedVectorTests {
    /// Carol's committed link proofs: each entry's HELLOs, role and transcript are the case's, its record carries her keys,
    /// and its signature verifies for her role. Never compared: CryptoKit randomizes Ed25519.
    @Test(.disabled(if: VectorFile.writing))
    func theCommittedLinkProofsAreCurrent() throws {
        let committed = try #require(EmittedVectors.committed?.link, "run the tests with KNIT_WRITE_VECTORS=1 to write the file")
        let carol = try carol()
        #expect(committed.about == EmittedLinkProofs.about)
        let cases = EmittedLinkProofs.cases(carol: carol, alice: try keyed("alice"))
        for (entry, link) in zip([committed.carolDialsAlice, committed.aliceDialsCarol], cases) {
            #expect(EmittedLinkProofs.isCurrent(entry, link, carol: carol), "link.\(link.name) \(Self.stale)")
            #expect(entry.helloDialer.payload.hasSuffix("|1|40009|n" + Hex.encode(link.helloDialer.nonce ?? [])))
        }
        #expect(committed.carolDialsAlice.helloDialer == committed.aliceDialsCarol.helloResponder, "Carol's HELLO both ways")
    }

    /// The link proof's currency check must be able to fail: a fresh proof passes, and not under the other role, on the
    /// other link, or as Alice's.
    @Test func theLinkProofCheckTellsACurrentProofFromAStaleOne() throws {
        let carol = try carol()
        let alice = try keyed("alice")
        let cases = EmittedLinkProofs.cases(carol: carol, alice: alice)
        let dialing = try #require(try EmittedLinkProofs.entry(cases[0], carol: carol))
        let answering = try #require(try EmittedLinkProofs.entry(cases[1], carol: carol))
        #expect(EmittedLinkProofs.isCurrent(dialing, cases[0], carol: carol))
        #expect(EmittedLinkProofs.isCurrent(answering, cases[1], carol: carol))
        #expect(!EmittedLinkProofs.isCurrent(dialing, cases[1], carol: carol), "the other link")
        #expect(!EmittedLinkProofs.isCurrent(dialing, cases[0], carol: alice), "not Alice's keys")
        let otherRole = EmittedLinkProof(
            dialer: dialing.dialer,
            responder: dialing.responder,
            signer: dialing.signer,
            role: LinkProof.Role.responder.rawValue,
            helloDialer: dialing.helloDialer,
            helloResponder: dialing.helloResponder,
            transcript: dialing.transcript,
            proof: dialing.proof)
        #expect(!EmittedLinkProofs.isCurrent(otherRole, cases[0], carol: carol))
        let swapped = EmittedLinkProof(
            dialer: dialing.dialer,
            responder: dialing.responder,
            signer: dialing.signer,
            role: dialing.role,
            helloDialer: dialing.helloDialer,
            helloResponder: dialing.helloResponder,
            transcript: dialing.transcript,
            proof: answering.proof)
        #expect(!EmittedLinkProofs.isCurrent(swapped, cases[0], carol: carol), "the responder's signature is not the dialer's")
    }
}
