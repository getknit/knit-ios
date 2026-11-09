import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

/// Carol's link proofs in `ios-emitted-v1.json` (``EmittedLinkProofs``, `link-hello-proof`), and her sealed links under
/// `link.seal` (``EmittedLinkSeals``, `link-seal`).
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

    /// Carol's committed sealed links: every KEY_SHARE, key, HELLO, sealed HELLO and transcript is rebuilt byte for byte,
    /// and each PROOF frame opens to her record, whose signature verifies for her role over the v2 transcript.
    @Test(.disabled(if: VectorFile.writing))
    func theCommittedSealedLinksAreCurrent() throws {
        let committed = try #require(EmittedVectors.committed?.link?.seal, "run the tests with KNIT_WRITE_VECTORS=1 to write the file")
        let carol = try carol()
        #expect(committed.about == EmittedLinkSeals.about)
        let cases = EmittedLinkSeals.cases(carol: carol, alice: try keyed("alice"))
        for (entry, link) in zip([committed.carolDialsAlice, committed.aliceDialsCarol], cases) {
            #expect(EmittedLinkSeals.isCurrent(entry, link, carol: carol), "link.seal.\(link.name) \(Self.stale)")
            #expect(entry.capabilities == "140009")
        }
        let dialing = committed.carolDialsAlice
        let answering = committed.aliceDialsCarol
        #expect(dialing.keyShareDialer == answering.keyShareResponder, "Carol's KEY_SHARE both ways")
        #expect(dialing.keyShareResponder == answering.keyShareDialer, "Alice's KEY_SHARE both ways")
        #expect(dialing.helloSealed.payload == answering.helloSealed.payload, "Carol's HELLO both ways")
        #expect(dialing.helloSealed.frame != answering.helloSealed.frame, "under the other direction's key")
    }

    /// The sealed link's currency check must be able to fail: a fresh entry passes, and not on the other link, as Alice's,
    /// with the other link's PROOF, or with a HELLO frame sealed at another counter.
    @Test func theSealedLinkCheckTellsACurrentEntryFromAStaleOne() throws {
        let carol = try carol()
        let alice = try keyed("alice")
        let cases = EmittedLinkSeals.cases(carol: carol, alice: alice)
        let dialing = try #require(try EmittedLinkSeals.entry(cases[0], carol: carol))
        let answering = try #require(try EmittedLinkSeals.entry(cases[1], carol: carol))
        #expect(EmittedLinkSeals.isCurrent(dialing, cases[0], carol: carol))
        #expect(EmittedLinkSeals.isCurrent(answering, cases[1], carol: carol))
        #expect(!EmittedLinkSeals.isCurrent(dialing, cases[1], carol: carol), "the other link")
        #expect(!EmittedLinkSeals.isCurrent(dialing, cases[0], carol: alice), "not Alice's keys")
        #expect(!EmittedLinkSeals.isCurrent(dialing.with(proof: answering.proof), cases[0], carol: carol), "the responder's PROOF")
        let reflected = VectorLink.Seal.SealedProof(
            signer: "carol", record: answering.proof.record, key: dialing.proof.key, counter: 1, frame: answering.proof.frame)
        #expect(!EmittedLinkSeals.isCurrent(dialing.with(proof: reflected), cases[0], carol: carol), "a frame of the other way")
        let relabelled = VectorLink.Seal.SealedProof(
            signer: "alice", record: dialing.proof.record, key: dialing.proof.key, counter: 1, frame: dialing.proof.frame)
        #expect(!EmittedLinkSeals.isCurrent(dialing.with(proof: relabelled), cases[0], carol: carol), "a PROOF labelled as another's")
        let fresh = try #require(try EmittedLinkSeals.entry(cases[0], carol: carol))
        #expect(EmittedLinkSeals.isCurrent(dialing.with(proof: fresh.proof), cases[0], carol: carol), "a second signature is as good")
        #expect(fresh.helloSealed == dialing.helloSealed && fresh.keyD2R == dialing.keyD2R, "all but the PROOF is deterministic")
        let skipped = VectorLink.Seal.SealedHello(
            payload: dialing.helloSealed.payload, key: dialing.helloSealed.key, counter: 1, frame: dialing.proof.frame)
        #expect(!EmittedLinkSeals.isCurrent(dialing.with(helloSealed: skipped), cases[0], carol: carol))
    }
}

extension EmittedLinkSealCase {
    /// The same entry with another PROOF or sealed HELLO, for the currency check's own test.
    func with(proof: VectorLink.Seal.SealedProof? = nil, helloSealed: VectorLink.Seal.SealedHello? = nil) -> Self {
        Self(
            dialer: dialer,
            responder: responder,
            signer: signer,
            role: role,
            capabilities: capabilities,
            keyShareDialer: keyShareDialer,
            keyShareResponder: keyShareResponder,
            shared: shared,
            keyD2R: keyD2R,
            keyR2D: keyR2D,
            helloDialer: helloDialer,
            helloResponder: helloResponder,
            helloSealed: helloSealed ?? self.helloSealed,
            transcript: transcript,
            proof: proof ?? self.proof)
    }
}
