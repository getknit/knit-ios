import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

/// knit-next's link proof (`keyed-v1.json` → `link`, knit-next ADR 2026-11.264w): Alice dials Bob, her nonce `00..0f` and
/// his `10..1f`, both HELLOs at caps `40009`. Both transcripts are rebuilt byte for byte; each PROOF record's header and
/// keys are compared, and its signature is verified, never compared: Tink signs deterministically and CryptoKit does not
/// (`vectors/README.md`). Every `proofRejects` entry must fail as its reason says. The HELLOs' own parse is
/// `LinkVectorTests`'.
@Suite struct LinkProofVectorTests {
    private let link = KeyedVectors.file.link

    private func identity(_ name: String) throws -> IdentityKeys {
        let entry = try #require(KeyedVectors.file.identities[name])
        return try #require(IdentityKeys(signingSeed: hexBytes(entry.signingSeed), agreementScalar: hexBytes(entry.agreementScalar)))
    }

    private var dialerHello: [UInt8] { Array(link.helloProofDialer.payload.utf8) }
    private var responderHello: [UInt8] { Array(link.helloProofReply.payload.utf8) }

    private static func role(_ byte: UInt8) throws -> LinkProof.Role {
        try #require(LinkProof.Role(rawValue: byte))
    }

    /// The record's payload, after checking it is one whole PROOF record and nothing after it.
    private static func proofPayload(_ recordHex: String) throws -> [UInt8] {
        var reader = LinkRecordReader()
        reader.append(hexBytes(recordHex))
        let record = try #require(try reader.next())
        #expect(record.tag == .proof)
        #expect(!reader.hasPartialRecord)
        return record.payload
    }

    @Test(arguments: ["proofTranscriptDialer", "proofTranscriptResponder"])
    func bothTranscriptsAreRebuiltByteForByte(entry: String) throws {
        let vector = entry == "proofTranscriptDialer" ? link.proofTranscriptDialer : link.proofTranscriptResponder
        let role = try Self.role(vector.role)
        #expect(role == (entry == "proofTranscriptDialer" ? .dialer : .responder))
        #expect(vector.signer == (role == .dialer ? "alice" : "bob"))
        let ours = LinkProof.transcript(signer: role, dialerHello: dialerHello, responderHello: responderHello)
        #expect(Hex.encode(ours) == vector.hex)
    }

    /// Each side's PROOF: the header (tag 8, length 128) and the signer's raw keys byte for byte, the signature verified for
    /// the signer's role over the HELLOs as they crossed, and refused for the other role.
    @Test(arguments: [("proofDialer", LinkProof.Role.dialer), ("proofResponder", .responder)])
    func eachProofRecordsKeysMatchAndItsSignatureVerifies(entry: String, role: LinkProof.Role) throws {
        let vector = entry == "proofDialer" ? link.proofDialer : link.proofResponder
        let signer = try identity(vector.signer)
        let record = hexBytes(vector.record)
        #expect(Array(record.prefix(LinkRecord.headerBytes)) == [0x08, 0x00, 0x00, 0x00, 0x80])
        let payload = try Self.proofPayload(vector.record)
        #expect(payload.count == LinkProof.payloadByteCount)
        #expect(Array(payload.prefix(LinkProof.keysByteCount)) == signer.bundle.signingKey + signer.bundle.agreementKey)
        let outcome = LinkProof.verify(
            payload, claimedId: signer.nodeId, signer: role, dialerHello: dialerHello, responderHello: responderHello)
        #expect(outcome == .proven(signer.bundle))
        let other: LinkProof.Role = role == .dialer ? .responder : .dialer
        let reflected = LinkProof.verify(
            payload, claimedId: signer.nodeId, signer: other, dialerHello: dialerHello, responderHello: responderHello)
        #expect(reflected == .failed(.badSignature))
    }

    /// The outcome each named reject must give. A name the file adds that this table lacks fails the replay, so a new
    /// reject is never skipped.
    private static let rejectOutcomes: [String: LinkProof.Failure] = [
        "wrongRole": .badSignature,
        "otherResponderNonce": .badSignature,
        "idMismatch": .idMismatch,
        "short": .length,
    ]

    @Test func everyRejectIsNamedHere() {
        #expect(Set(link.proofRejects.keys) == Set(Self.rejectOutcomes.keys))
    }

    /// Every reject, checked as its `checkedAs` names (`<identity>, <role>, <transcript entry>`), fails with the outcome its
    /// reason implies.
    @Test(arguments: ["wrongRole", "otherResponderNonce", "idMismatch", "short"])
    func everyRejectFailsAgainstTheDialersTranscript(name: String) throws {
        let reject = try #require(link.proofRejects[name])
        let expected = try #require(Self.rejectOutcomes[name])
        let parts = reject.checkedAs.split(separator: ",").map { String($0.drop { $0 == " " }) }
        try #require(parts.count == 3, "checkedAs: \(reject.checkedAs)")
        let claimed = try identity(parts[0])
        let role: LinkProof.Role = try #require(["dialer": .dialer, "responder": .responder][parts[1]])
        let transcript = try #require(
            ["proofTranscriptDialer": link.proofTranscriptDialer, "proofTranscriptResponder": link.proofTranscriptResponder][parts[2]])
        #expect(transcript.role == role.rawValue, "the role checked is the transcript's")
        #expect(Hex.encode(LinkProof.transcript(signer: role, dialerHello: dialerHello, responderHello: responderHello)) == transcript.hex)
        let payload = try Self.proofPayload(reject.record)
        let outcome = LinkProof.verify(
            payload, claimedId: claimed.nodeId, signer: role, dialerHello: dialerHello, responderHello: responderHello)
        #expect(outcome == .failed(expected), "\(name): \(reject.reason)")
    }

    /// The id mismatch is Bob's genuine dialer-role signature: it holds as his, so only the claimed id refuses it.
    @Test func theIdMismatchIsBobsValidDialerSignature() throws {
        let bob = try identity("bob")
        let payload = try Self.proofPayload(try #require(link.proofRejects["idMismatch"]).record)
        #expect(Array(payload.prefix(LinkProof.keysByteCount)) == bob.bundle.signingKey + bob.bundle.agreementKey)
        let outcome = LinkProof.verify(
            payload, claimedId: bob.nodeId, signer: .dialer, dialerHello: dialerHello, responderHello: responderHello)
        #expect(outcome == .proven(bob.bundle))
    }
}
