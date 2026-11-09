import Crypto
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitCrypto

/// knit-next's blinded-advert vectors, KnitCrypto's half (`keyed-v1.json`'s `blind` section at knit-next `cad69c77b`;
/// knit-next ADR 2026-11.xp6d and its owner-bound amendment; ADR 2026-11.sv5t): every tag's 44-byte MAC message, MAC, tag
/// and node-id reading, `slotOf`, the window and the constants; and the tagged link's proofs, verified over the HELLOs as
/// they crossed and never compared, since Tink signs deterministically and CryptoKit does not. The wire half is
/// `BlindVectorTests` in KnitWireTests.
@Suite struct BlindTagVectorTests {
    private let blind = KeyedVectors.file.blind

    private func bytes(_ hex: String) throws -> [UInt8] {
        try #require(Hex.decode(hex), "\(hex) is hex")
    }

    private func identity(_ name: String) throws -> IdentityKeys {
        let entry = try #require(KeyedVectors.file.identities[name])
        return try #require(IdentityKeys(signingSeed: hexBytes(entry.signingSeed), agreementScalar: hexBytes(entry.agreementScalar)))
    }

    private func presenceKey(_ name: String) throws -> PresenceKey {
        let hex = try #require(blind.presenceKeys[name])
        return try #require(PresenceKey(bytes: try bytes(hex)))
    }

    // MARK: Tags

    @Test func everyTagIsNamedHere() {
        #expect(
            Set(blind.tags.keys) == [
                "aliceSlotMinus1", "aliceSlot0", "aliceNowRestart0", "aliceNowRestart1", "aliceNowRestart2", "aliceNowRestart3",
                "bobNowRestart0", "aliceKeyUnderBob",
            ])
    }

    @Test(arguments: [
        "aliceSlotMinus1", "aliceSlot0", "aliceNowRestart0", "aliceNowRestart1", "aliceNowRestart2", "aliceNowRestart3",
        "bobNowRestart0", "aliceKeyUnderBob",
    ])
    func everyTagIsRebuiltByteForByte(name: String) throws {
        let vector = try #require(blind.tags[name])
        let key = try presenceKey(vector.key)
        let owner = try identity(vector.owner).nodeId
        #expect(Hex.encode(owner.bytes) == vector.ownerId, "the owner is the node id's 16 raw bytes")
        let message = BlindTag.message(owner: owner.bytes, slot: vector.slot, restart: vector.restart)
        #expect(Hex.encode(message) == vector.macInput)
        #expect(message.count == BlindTag.messageByteCount)
        let mac = BlindTag.mac(key: SymmetricKey(data: key.bytes), owner: owner.bytes, slot: vector.slot, restart: vector.restart)
        #expect(Hex.encode(mac) == vector.mac)
        let tag = try #require(BlindTag.Expected(key: key, owner: owner).tag(slot: vector.slot, restart: vector.restart))
        #expect(Hex.encode(tag) == vector.tag)
        #expect(BlindTag.tag(key: key, owner: owner.bytes, slot: vector.slot, restart: vector.restart) == tag)
        #expect(NodeId(bytes: tag)?.string == vector.asNodeId)
        #expect(AdvertForm.hasTagPrefix(tag))
    }

    /// A key re-sent by Bob as his own gives tags under Bob's id: not Alice's, and not Bob's own.
    @Test func aliceKeyUnderBobIsNeitherAlicesTagNorBobs() throws {
        let underBob = try #require(blind.tags["aliceKeyUnderBob"])
        let alice = try #require(blind.tags["aliceNowRestart0"])
        let bob = try #require(blind.tags["bobNowRestart0"])
        #expect(underBob.key == alice.key && underBob.slot == alice.slot && underBob.restart == alice.restart)
        #expect(underBob.tag != alice.tag)
        #expect(underBob.tag != bob.tag)
    }

    /// The window's 140 expected tags, at the vector's clock, hold every one of Alice's tags for its current slot.
    @Test func aliceNowIsInTheWindowsExpectedTags() throws {
        let key = try presenceKey("alice")
        let owner = try identity("alice").nodeId
        let listed = BlindTag.Expected(key: key, owner: owner).tags(slots: BlindTag.window(wallMilliseconds: blind.window.wallMs))
        #expect(listed.count == 35 * BlindTag.restarts)
        let expected = Set(listed.map { Hex.encode($0.tag) })
        for restart in 0..<BlindTag.restarts {
            let vector = try #require(blind.tags["aliceNowRestart\(restart)"])
            #expect(expected.contains(vector.tag), "restart \(restart)")
        }
    }

    // MARK: Slots and constants

    @Test func slotOfMatchesEveryRow() {
        #expect(blind.slotOf.count == 7)
        for row in blind.slotOf {
            #expect(BlindTag.slotOf(wallMilliseconds: row.wallMs) == row.slot, "\(row.wallMs)")
        }
    }

    @Test func theWindowMatches() {
        let window = BlindTag.window(wallMilliseconds: blind.window.wallMs)
        #expect(window.lowerBound == blind.window.from)
        #expect(window.upperBound == blind.window.to)
    }

    @Test func theConstantsMatch() {
        #expect(BlindTag.label == blind.constants.label)
        #expect(BlindTag.slotMilliseconds == blind.constants.slotMs)
        #expect(BlindTag.restarts == blind.constants.restarts)
        #expect(BlindTag.windowPastSlots == blind.constants.windowPastSlots)
        #expect(BlindTag.windowAheadSlots == blind.constants.windowAheadSlots)
    }

    // MARK: The tagged link's proofs

    private var dialerHello: [UInt8] { Array(blind.link.helloTaggedDialer.payload.utf8) }
    private var responderHello: [UInt8] { Array(blind.link.helloTaggedReply.payload.utf8) }

    /// The record's payload, after checking it is one whole PROOF record and nothing after it.
    private func proofPayload(_ recordHex: String) throws -> [UInt8] {
        var reader = LinkRecordReader()
        reader.append(try bytes(recordHex))
        let record = try #require(try reader.next())
        #expect(record.tag == .proof)
        #expect(!reader.hasPartialRecord)
        return record.payload
    }

    @Test func bothTranscriptsAreRebuiltByteForByte() {
        let link = blind.link
        #expect(link.proofTranscriptDialer.signer == "alice" && link.proofTranscriptResponder.signer == "bob")
        let dialer = LinkProof.transcript(form: .plain, signer: .dialer, dialerHello: dialerHello, responderHello: responderHello)
        let responder = LinkProof.transcript(form: .plain, signer: .responder, dialerHello: dialerHello, responderHello: responderHello)
        #expect(Hex.encode(dialer) == link.proofTranscriptDialer.hex)
        #expect(Hex.encode(responder) == link.proofTranscriptResponder.hex)
    }

    /// Each side's PROOF verifies for its signer and role over the HELLOs as they crossed, `t` and `a` included, and is
    /// refused for the other role.
    @Test(arguments: [("proofDialer", LinkProof.Role.dialer), ("proofResponder", .responder)])
    func eachProofVerifiesOverTheTaggedHellos(entry: String, role: LinkProof.Role) throws {
        let vector = entry == "proofDialer" ? blind.link.proofDialer : blind.link.proofResponder
        let signer = try identity(vector.signer)
        #expect(vector.signer == (role == .dialer ? "alice" : "bob"))
        let payload = try proofPayload(vector.record)
        #expect(Array(payload.prefix(LinkProof.keysByteCount)) == signer.bundle.signingKey + signer.bundle.agreementKey)
        let outcome = LinkProof.verify(
            payload, claimedId: signer.nodeId, form: .plain, signer: role, dialerHello: dialerHello, responderHello: responderHello)
        #expect(outcome == .proven(signer.bundle))
        let other: LinkProof.Role = role == .dialer ? .responder : .dialer
        let reflected = LinkProof.verify(
            payload, claimedId: signer.nodeId, form: .plain, signer: other, dialerHello: dialerHello, responderHello: responderHello)
        #expect(reflected == .failed(.badSignature))
    }

    /// Bob's proof, checked as the responder over Alice's HELLO and his reply with `t` rewritten, fails: the signature
    /// covers the HELLOs as sent, so a rewritten tag cannot ride a proven link.
    @Test func aRewrittenToldTagFailsBobsProof() throws {
        let rewritten = blind.link.toldRewritten
        #expect(rewritten.record == "proofResponder")
        #expect(rewritten.payload != blind.link.helloTaggedReply.payload)
        let bob = try identity("bob")
        let payload = try proofPayload(blind.link.proofResponder.record)
        let outcome = LinkProof.verify(
            payload,
            claimedId: bob.nodeId,
            form: .plain,
            signer: .responder,
            dialerHello: dialerHello,
            responderHello: Array(rewritten.payload.utf8))
        #expect(outcome == .failed(.badSignature), "\(rewritten.reason)")
    }
}
