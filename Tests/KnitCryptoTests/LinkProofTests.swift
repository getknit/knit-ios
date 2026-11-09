import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

/// A link's proof of the id its HELLO claims (knit-ios #25, knit-next #232), against the shared contract's case: keyed-v1
/// Alice dials Bob, Alice's nonce `00…0f`, Bob's `10…1f`, both HELLOs carrying caps `40009`. The transcript is pinned
/// from the contract's layout, and every proof is verified, never compared, since CryptoKit randomizes Ed25519. knit-next's
/// `link` entries in `keyed-v1.json` replay in `LinkProofVectorTests`.
@Suite struct LinkProofTests {
    private func identity(_ name: String) throws -> IdentityKeys {
        let entry = try #require(KeyedVectors.file.identities[name])
        return try #require(IdentityKeys(signingSeed: hexBytes(entry.signingSeed), agreementScalar: hexBytes(entry.agreementScalar)))
    }

    private static let aliceNonce = (0..<16).map { UInt8($0) }
    private static let bobNonce = (16..<32).map { UInt8($0) }

    /// A HELLO payload with a nonce field, as the contract's §2 lays it out.
    private static func hello(_ id: NodeId, nonce: [UInt8]) -> [UInt8] {
        Array("\(id.string)|1|40009|n\(Hex.encode(nonce))".utf8)
    }

    /// The contract's link: Alice dialed, Bob answered, and the two HELLOs as they crossed.
    private struct Link {
        let alice: IdentityKeys
        let bob: IdentityKeys
        let dialer: [UInt8]
        let responder: [UInt8]
    }

    private func pair() throws -> Link {
        let alice = try identity("alice")
        let bob = try identity("bob")
        let dialer = Self.hello(alice.nodeId, nonce: Self.aliceNonce)
        return Link(alice: alice, bob: bob, dialer: dialer, responder: Self.hello(bob.nodeId, nonce: Self.bobNonce))
    }

    @Test func theHellosAreTheContracts() throws {
        let link = try pair()
        #expect(link.dialer == Array("4cgq2pnhh6p3j3afwsue3chrpi|1|40009|n000102030405060708090a0b0c0d0e0f".utf8))
        #expect(link.responder == Array("raunzp43s3sncyojiezgg7ulna|1|40009|n101112131415161718191a1b1c1d1e1f".utf8))
    }

    @Test func theTranscriptIsTheLabelTheRoleAndBothHellosBehindTheirLengths() throws {
        let link = try pair()
        let hellos =
            "000000443463677132706e68683670336a336166777375653363687270697c317c34303030397c6e30303031303230333034303530363037"
            + "30383039306130623063306430653066000000447261756e7a7034337333736e63796f6a69657a676737756c6e617c317c34303030397c6e"
            + "3130313131323133313431353136313731383139316131623163316431653166"
        let label = "6b6e69742f6c696e6b2f76312f70726f6f66"
        let dialer = LinkProof.transcript(form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
        let responder = LinkProof.transcript(form: .plain, signer: .responder, dialerHello: link.dialer, responderHello: link.responder)
        #expect(Hex.encode(dialer) == label + "01" + hellos)
        #expect(Hex.encode(responder) == label + "02" + hellos, "the dialer's HELLO first, whoever signs")
        #expect(dialer.count == 163)
        #expect(dialer.first == 0x6B, "a CBOR text head, so no transcript reads as a frame's signed map")
    }

    @Test func eachSidesProofVerifiesForItsOwnRole() throws {
        let link = try pair()
        for (keys, role) in [(link.alice, LinkProof.Role.dialer), (link.bob, .responder)] {
            let payload = try LinkProof.payload(
                keys: keys, form: .plain, signer: role, dialerHello: link.dialer, responderHello: link.responder)
            #expect(payload.count == LinkProof.payloadByteCount && payload.count == 128)
            #expect(Array(payload.prefix(64)) == keys.bundle.signingKey + keys.bundle.agreementKey, "the keys ride first, raw")
            let outcome = LinkProof.verify(
                payload, claimedId: keys.nodeId, form: .plain, signer: role, dialerHello: link.dialer, responderHello: link.responder)
            #expect(outcome == .proven(keys.bundle))
        }
    }

    @Test func aSecondSigningAlsoVerifies() throws {
        // CryptoKit's signatures differ from one signing to the next; both hold, and neither is compared.
        let link = try pair()
        for _ in 0..<2 {
            let payload = try LinkProof.payload(
                keys: link.alice, form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
            #expect(
                LinkProof.verify(
                    payload,
                    claimedId: link.alice.nodeId,
                    form: .plain,
                    signer: .dialer,
                    dialerHello: link.dialer,
                    responderHello: link.responder)
                    == .proven(link.alice.bundle))
        }
    }

    // MARK: The contract's `proofRejects`, each against the dialer's transcript

    @Test func alicesSignatureOverTheResponderTranscriptIsTheWrongRole() throws {
        let link = try pair()
        let reflected = try LinkProof.payload(
            keys: link.alice, form: .plain, signer: .responder, dialerHello: link.dialer, responderHello: link.responder)
        let outcome = LinkProof.verify(
            reflected, claimedId: link.alice.nodeId, form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder
        )
        #expect(outcome == .failed(.badSignature))
    }

    @Test func alicesSignatureOverAnotherResponderNonceIsRefused() throws {
        let link = try pair()
        let replayed = Self.hello(link.bob.nodeId, nonce: [UInt8](repeating: 0xFF, count: 16))
        let payload = try LinkProof.payload(
            keys: link.alice, form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: replayed)
        let outcome = LinkProof.verify(
            payload, claimedId: link.alice.nodeId, form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
        #expect(outcome == .failed(.badSignature))
    }

    @Test func bobsValidDialerProofClaimedAsAliceIsAnIdMismatch() throws {
        let link = try pair()
        let bobs = try LinkProof.payload(
            keys: link.bob, form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
        #expect(
            LinkProof.verify(
                bobs, claimedId: link.bob.nodeId, form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
                == .proven(link.bob.bundle), "the signature itself holds")
        let outcome = LinkProof.verify(
            bobs, claimedId: link.alice.nodeId, form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
        #expect(outcome == .failed(.idMismatch))
    }

    @Test(arguments: [0, 64, 127, 129, 256])
    func aPayloadOfAnyOtherLengthIsRefused(length: Int) throws {
        let link = try pair()
        let payload = try LinkProof.payload(
            keys: link.alice, form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
        let cut = length <= payload.count ? Array(payload.prefix(length)) : payload + [UInt8](repeating: 0, count: length - payload.count)
        let outcome = LinkProof.verify(
            cut, claimedId: link.alice.nodeId, form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
        #expect(outcome == .failed(.length))
    }

    // MARK: Tampering

    @Test(arguments: [64, 100, 127])
    func aFlippedSignatureBitIsRefused(at index: Int) throws {
        let link = try pair()
        var payload = try LinkProof.payload(
            keys: link.alice, form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
        payload[index] ^= 0x01
        let outcome = LinkProof.verify(
            payload, claimedId: link.alice.nodeId, form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
        #expect(outcome == .failed(.badSignature))
    }

    @Test func aFlippedKeyBitIsNoLongerTheClaimedId() throws {
        let link = try pair()
        for index in [0, 32] {
            var payload = try LinkProof.payload(
                keys: link.alice, form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
            payload[index] ^= 0x01
            let outcome = LinkProof.verify(
                payload,
                claimedId: link.alice.nodeId,
                form: .plain,
                signer: .dialer,
                dialerHello: link.dialer,
                responderHello: link.responder)
            #expect(outcome == .failed(.idMismatch), "byte \(index)")
        }
    }

    @Test func aChangedByteInEitherHelloIsRefused() throws {
        let link = try pair()
        let payload = try LinkProof.payload(
            keys: link.alice, form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
        var dialer = link.dialer
        dialer[dialer.count - 1] ^= 0x01
        var responder = link.responder
        responder[30] ^= 0x01
        for (seenDialer, seenResponder) in [(dialer, link.responder), (link.dialer, responder), (link.dialer, link.responder + [0x7C])] {
            let outcome = LinkProof.verify(
                payload, claimedId: link.alice.nodeId, form: .plain, signer: .dialer, dialerHello: seenDialer, responderHello: seenResponder
            )
            #expect(outcome == .failed(.badSignature))
        }
    }

    @Test func theHellosCannotTradePlaces() throws {
        // The lengths frame each HELLO, and the order is fixed: the same two payloads swapped are another transcript.
        let link = try pair()
        let payload = try LinkProof.payload(
            keys: link.bob, form: .plain, signer: .responder, dialerHello: link.dialer, responderHello: link.responder)
        let outcome = LinkProof.verify(
            payload, claimedId: link.bob.nodeId, form: .plain, signer: .responder, dialerHello: link.responder, responderHello: link.dialer)
        #expect(outcome == .failed(.badSignature))
    }

    // MARK: The sealed form (the `link-seal` contract, §6)

    /// The contract's sealed link: the same HELLOs, and the two ephemeral shares, each a stand-in 32 bytes.
    private static let shares = LinkSeal.KeyShares(
        dialer: (0x80..<0xA0).map { UInt8($0) }, responder: (0xA0..<0xC0).map { UInt8($0) })

    private func sealed() throws -> LinkProof.Form {
        .sealed(try #require(Self.shares))
    }

    @Test func theSealedTranscriptBindsBothSharesBetweenTheRoleAndTheHellos() throws {
        let link = try pair()
        let form = try sealed()
        let bound = try #require(Self.shares)
        let plain = LinkProof.transcript(form: .plain, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
        for role in [LinkProof.Role.dialer, .responder] {
            let ours = LinkProof.transcript(form: form, signer: role, dialerHello: link.dialer, responderHello: link.responder)
            let expected = Array("knit/link/v2/proof".utf8) + [role.rawValue] + bound.dialer + bound.responder + plain.dropFirst(19)
            #expect(ours == expected)
            #expect(ours.count == plain.count + 64 && ours.first == 0x6B)
        }
        #expect(LinkProof.sealedLabel.utf8.count == 18 && LinkProof.label.utf8.count == 18)
    }

    @Test func theSealedFormVerifiesForEachRole() throws {
        let link = try pair()
        let form = try sealed()
        for (keys, role) in [(link.alice, LinkProof.Role.dialer), (link.bob, .responder)] {
            let payload = try LinkProof.payload(
                keys: keys, form: form, signer: role, dialerHello: link.dialer, responderHello: link.responder)
            let outcome = LinkProof.verify(
                payload, claimedId: keys.nodeId, form: form, signer: role, dialerHello: link.dialer, responderHello: link.responder)
            #expect(outcome == .proven(keys.bundle))
        }
    }

    @Test func aProofNeverVerifiesInTheOtherForm() throws {
        // `v1ProofOnSealedLink`, and its mirror: the labels keep a relay from opening the two forms toward the two peers.
        let link = try pair()
        let form = try sealed()
        let v1 = try LinkProof.payload(
            keys: link.bob, form: .plain, signer: .responder, dialerHello: link.dialer, responderHello: link.responder)
        let v2 = try LinkProof.payload(
            keys: link.bob, form: form, signer: .responder, dialerHello: link.dialer, responderHello: link.responder)
        #expect(
            LinkProof.verify(
                v1, claimedId: link.bob.nodeId, form: form, signer: .responder, dialerHello: link.dialer, responderHello: link.responder)
                == .failed(.badSignature))
        #expect(
            LinkProof.verify(
                v2, claimedId: link.bob.nodeId, form: .plain, signer: .responder, dialerHello: link.dialer, responderHello: link.responder)
                == .failed(.badSignature))
    }

    @Test func aProofOverOtherSharesIsRefused() throws {
        let link = try pair()
        let bound = try #require(Self.shares)
        let swapped = try #require(LinkSeal.KeyShares(dialer: bound.dialer, responder: [UInt8](repeating: 0xFF, count: 32)))
        let transposed = try #require(LinkSeal.KeyShares(dialer: bound.responder, responder: bound.dialer))
        // `swappedKeyShare`: Bob's signature over a transcript whose eR is `ff…ff`; then eD and eR traded.
        for other in [swapped, transposed] {
            let payload = try LinkProof.payload(
                keys: link.bob, form: .sealed(other), signer: .responder, dialerHello: link.dialer, responderHello: link.responder)
            let outcome = LinkProof.verify(
                payload,
                claimedId: link.bob.nodeId,
                form: .sealed(bound),
                signer: .responder,
                dialerHello: link.dialer,
                responderHello: link.responder)
            #expect(outcome == .failed(.badSignature))
        }
    }

    @Test func aSealedProofForTheOtherRoleIsRefused() throws {
        let link = try pair()
        let form = try sealed()
        let reflected = try LinkProof.payload(
            keys: link.alice, form: form, signer: .responder, dialerHello: link.dialer, responderHello: link.responder)
        let outcome = LinkProof.verify(
            reflected, claimedId: link.alice.nodeId, form: form, signer: .dialer, dialerHello: link.dialer, responderHello: link.responder)
        #expect(outcome == .failed(.badSignature))
    }

    // MARK: Nonces

    @Test func aFreshNonceIsSixteenBytesAndNeverRepeats() {
        let first = LinkProof.freshNonce()
        let second = LinkProof.freshNonce()
        #expect(first.count == LinkProof.nonceByteCount && LinkProof.nonceByteCount == 16)
        #expect(second.count == 16)
        #expect(first != second)
    }
}
