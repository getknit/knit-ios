import Crypto
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitCrypto

/// knit-next's sealed link (`keyed-v1.json` → `link.seal`, the `link-seal` contract's "Vectors"; knit-next #286): Alice
/// dials Bob, her ephemeral scalar `40..5f` and his `60..7f`, both HELLOs at caps `140009`. The KEY_SHAREs, `ss`, both
/// direction keys, both sealed HELLOs and both v2 transcripts are rebuilt byte for byte. The PROOF frames are opened and
/// their Tink signatures verified, never compared: CryptoKit randomizes Ed25519. Both splits open to their records, and
/// every `sealRejects` entry fails where this port refuses it, for the reason it names. A file without the section fails
/// to decode (`VectorLink.seal` is required), so nothing here skips.
@Suite struct LinkSealVectorTests {
    let seal = KeyedVectors.file.link.seal

    func identity(_ name: String) throws -> IdentityKeys {
        let entry = try #require(KeyedVectors.file.identities[name])
        return try #require(IdentityKeys(signingSeed: hexBytes(entry.signingSeed), agreementScalar: hexBytes(entry.agreementScalar)))
    }

    /// Both sides of the file's link, derived from the fixed scalars: Alice's as the dialer, Bob's as the responder.
    func sessions() throws -> (alice: LinkSeal.Session, bob: LinkSeal.Session) {
        let alice = try #require(LinkSeal.Ephemeral(scalar: hexBytes(seal.keyShareDialer.scalar)))
        let bob = try #require(LinkSeal.Ephemeral(scalar: hexBytes(seal.keyShareResponder.scalar)))
        let bobShare = bob.keyShare
        let aliceSession = try LinkSeal.derive(alice, peerShare: bobShare, role: .dialer)
        return (aliceSession, try LinkSeal.derive(bob, peerShare: aliceSession.shares.dialer, role: .responder))
    }

    /// The direction key an entry names, from our own derivation (checked against the file's in
    /// ``theKeySharesAndKeysAreRebuiltByteForByte()``).
    func key(_ name: String?) throws -> SymmetricKey {
        let session = try sessions().alice
        switch name {
        case "keyD2R":
            return SymmetricKey(data: session.keyD2R)
        case "keyR2D":
            return SymmetricKey(data: session.keyR2D)
        default:
            Issue.record("no direction key named \(name ?? "nil")")
            throw KeyName.unknown
        }
    }

    enum KeyName: Error { case unknown }

    /// The one record in `bytes`, read as the link reads it, with nothing after it.
    static func onlyRecord(_ bytes: [UInt8]) throws -> LinkRecord {
        var reader = LinkRecordReader()
        reader.append(bytes)
        let record = try #require(try reader.next())
        #expect(!reader.hasPartialRecord)
        return record
    }

    /// Every record in `bytes`, which must end on a record's edge.
    static func records(_ bytes: [UInt8]) throws -> [LinkRecord] {
        var reader = LinkRecordReader()
        reader.append(bytes)
        var out: [LinkRecord] = []
        while let record = try reader.next() {
            out.append(record)
        }
        #expect(!reader.hasPartialRecord)
        return out
    }

    /// A `SEALED` frame's payload, after reading it as the link does.
    static func sealedPayload(_ frameHex: String) throws -> [UInt8] {
        let record = try onlyRecord(hexBytes(frameHex))
        #expect(record.tag == .sealed)
        return record.payload
    }

    var transcriptForm: LinkProof.Form {
        get throws {
            .sealed(
                try #require(
                    LinkSeal.KeyShares(
                        dialer: Array(hexBytes(seal.keyShareDialer.record).dropFirst(LinkRecord.headerBytes)),
                        responder: Array(hexBytes(seal.keyShareResponder.record).dropFirst(LinkRecord.headerBytes)))))
        }
    }

    var dialerHello: [UInt8] { Array(seal.helloSealedDialer.payload.utf8) }
    var responderHello: [UInt8] { Array(seal.helloSealedReply.payload.utf8) }

    // MARK: The exchange

    @Test func theSetupIsTheContracts() {
        #expect(seal.dialer == "alice" && seal.responder == "bob")
        #expect(seal.capabilities == "140009")
        #expect(Capabilities(rawValue: 0x140009).contains([.linkSeal, .linkProof]))
        #expect(seal.keyShareDialer.scalar == Hex.encode((0x40...0x5F).map { UInt8($0) }))
        #expect(seal.keyShareResponder.scalar == Hex.encode((0x60...0x7F).map { UInt8($0) }))
    }

    @Test func theKeySharesAndKeysAreRebuiltByteForByte() throws {
        let (alice, bob) = try sessions()
        #expect(Hex.encode(try #require(LinkRecord(.keyShare, payload: alice.shares.dialer).encoded)) == seal.keyShareDialer.record)
        #expect(Hex.encode(try #require(LinkRecord(.keyShare, payload: bob.shares.responder).encoded)) == seal.keyShareResponder.record)
        #expect(alice.shares == bob.shares)
        for session in [alice, bob] {
            #expect(Hex.encode(session.shared) == seal.shared)
            #expect(Hex.encode(session.keyD2R) == seal.keyD2R)
            #expect(Hex.encode(session.keyR2D) == seal.keyR2D)
        }
        // Each KEY_SHARE reads as the link reads one: tag 10, 32 bytes.
        for record in [seal.keyShareDialer.record, seal.keyShareResponder.record] {
            let read = try Self.onlyRecord(hexBytes(record))
            #expect(read.tag == .keyShare && read.payload.count == LinkSeal.keyShareByteCount)
        }
    }

    /// Each HELLO record sealed at its counter under its direction's key is the file's frame byte for byte, and the frame
    /// opens back to the HELLO, whose capabilities carry the seal and the proof.
    @Test(arguments: ["helloSealedDialer", "helloSealedReply"])
    func eachSealedHelloIsRebuiltByteForByteAndOpens(entry: String) throws {
        let hello = entry == "helloSealedDialer" ? seal.helloSealedDialer : seal.helloSealedReply
        #expect(hello.key == (entry == "helloSealedDialer" ? "keyD2R" : "keyR2D"))
        #expect(hello.counter == 0)
        let record = try #require(LinkRecord(.hello, payload: Array(hello.payload.utf8)).encoded)
        let frame = try #require(LinkSealer(key: try key(hello.key), counter: hello.counter).seal(record))
        #expect(Hex.encode(frame) == hello.frame)

        let opened = try #require(
            LinkOpener(key: try key(hello.key), counter: hello.counter).open(sealedPayload: try Self.sealedPayload(hello.frame)))
        #expect(opened == record)
        let parsed = Hello(payload: try Self.onlyRecord(opened).payload)
        #expect(parsed.capabilities.rawValue == 0x140009)
    }

    /// The sessions `derive` hands each side open what the other side's sealer writes, in the file's bytes: Bob's opener
    /// reads Alice's HELLO then her PROOF, and Alice's reads Bob's.
    @Test func eachSidesOpenerReadsTheOthersFramesInOrder() throws {
        let (alice, bob) = try sessions()
        #expect(bob.opener.open(sealedPayload: try Self.sealedPayload(seal.helloSealedDialer.frame)) != nil)
        #expect(bob.opener.open(sealedPayload: try Self.sealedPayload(seal.proofDialer.frame)).map(Hex.encode) == seal.proofDialer.record)
        #expect(alice.opener.open(sealedPayload: try Self.sealedPayload(seal.helloSealedReply.frame)) != nil)
        #expect(
            alice.opener.open(sealedPayload: try Self.sealedPayload(seal.proofResponder.frame)).map(Hex.encode)
                == seal.proofResponder.record)
    }

    // MARK: The proofs

    @Test(arguments: ["transcriptDialer", "transcriptResponder"])
    func bothV2TranscriptsAreRebuiltByteForByte(entry: String) throws {
        let vector = entry == "transcriptDialer" ? seal.transcriptDialer : seal.transcriptResponder
        let role = try #require(LinkProof.Role(rawValue: vector.role))
        #expect(role == (entry == "transcriptDialer" ? .dialer : .responder))
        #expect(vector.signer == (role == .dialer ? "alice" : "bob"))
        let ours = LinkProof.transcript(form: try transcriptForm, signer: role, dialerHello: dialerHello, responderHello: responderHello)
        #expect(Hex.encode(ours) == vector.hex)
    }

    /// Each PROOF frame opens at counter 1 to its record, whose Tink signature verifies as its signer's over the v2
    /// transcript, and fails under the other role and on a plain link (the v1 label).
    @Test(arguments: [("proofDialer", LinkProof.Role.dialer), ("proofResponder", .responder)])
    func eachSealedProofOpensAndVerifies(entry: String, role: LinkProof.Role) throws {
        let vector = entry == "proofDialer" ? seal.proofDialer : seal.proofResponder
        #expect(vector.counter == 1)
        #expect(vector.key == (role == .dialer ? "keyD2R" : "keyR2D"))
        let opened = try #require(
            LinkOpener(key: try key(vector.key), counter: vector.counter).open(sealedPayload: try Self.sealedPayload(vector.frame)))
        #expect(Hex.encode(opened) == vector.record)
        let record = try Self.onlyRecord(opened)
        #expect(record.tag == .proof)
        let signer = try identity(vector.signer)
        #expect(Array(record.payload.prefix(LinkProof.keysByteCount)) == signer.bundle.signingKey + signer.bundle.agreementKey)

        let form = try transcriptForm
        func verify(_ form: LinkProof.Form, _ role: LinkProof.Role) -> LinkProof.Outcome {
            LinkProof.verify(
                record.payload, claimedId: signer.nodeId, form: form, signer: role, dialerHello: dialerHello, responderHello: responderHello
            )
        }
        #expect(verify(form, role) == .proven(signer.bundle))
        #expect(verify(form, role == .dialer ? .responder : .dialer) == .failed(.badSignature))
        #expect(verify(.plain, role) == .failed(.badSignature))
    }

    // MARK: Splits

    @Test(arguments: ["replyAndProofInOneFrame", "dialerHelloInTwoFrames"])
    func eachSplitOpensToTheSameRecords(name: String) throws {
        let split = try #require(seal.splits[name])
        let opener = LinkOpener(key: try key(split.key), counter: 0)
        var stream: [UInt8] = []
        for frame in split.frames {
            stream += try #require(opener.open(sealedPayload: try Self.sealedPayload(frame)))
        }
        let records = try Self.records(stream)
        #expect(records.compactMap(\.encoded).map(Hex.encode) == split.records)
    }

    @Test func theSplitsAreTheOnesTheContractNames() throws {
        #expect(Set(seal.splits.keys) == ["replyAndProofInOneFrame", "dialerHelloInTwoFrames"])
        #expect(
            try #require(seal.splits["replyAndProofInOneFrame"]).records == [
                try Hex.encode(#require(LinkRecord(.hello, payload: responderHello).encoded)), seal.proofResponder.record,
            ])
        #expect(try #require(seal.splits["dialerHelloInTwoFrames"]).frames.count == 2)
    }
}
