import Crypto
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitCrypto

/// `link.seal`'s `sealRejects`: each fails where this port refuses it, for the reason it names.
extension LinkSealVectorTests {
    /// Every reject this replay knows. A name the file adds that this list lacks fails ``everyRejectIsNamedHere()``, so a
    /// new reject is never skipped.
    private static let rejects = [
        "flippedBit", "skippedCounter", "wrongDirection", "lowOrderKeyShare", "shortKeyShare", "oversizeFrame", "emptyFrame",
        "v1ProofOnSealedLink", "swappedKeyShare",
    ]

    @Test func everyRejectIsNamedHere() {
        #expect(Set(seal.sealRejects.keys) == Set(Self.rejects))
    }

    private func reject(_ name: String) throws -> VectorLink.Seal.Reject {
        try #require(seal.sealRejects[name])
    }

    /// The reader's key is the one for frames it reads: Alice reads Bob's (`keyR2D`), Bob reads Alice's (`keyD2R`).
    @Test(arguments: ["flippedBit", "skippedCounter", "wrongDirection"])
    func eachFrameRejectIsReadUnderTheReadersKey(name: String) throws {
        let entry = try reject(name)
        #expect(entry.key == (entry.readBy == "alice" ? "keyR2D" : "keyD2R"), "\(name)")
    }

    @Test func aFlippedBitFailsTheTag() throws {
        let entry = try reject("flippedBit")
        let frame = hexBytes(try #require(entry.frame))
        let genuine = hexBytes(seal.helloSealedReply.frame)
        try #require(frame.count == genuine.count)
        let flipped = zip(frame, genuine).map { ($0 ^ $1).nonzeroBitCount }.reduce(0, +)
        #expect(flipped == 1, "one bit")
        #expect(Array(frame.prefix(LinkRecord.headerBytes)) == Array(genuine.prefix(LinkRecord.headerBytes)), "in the ciphertext")
        let control = LinkOpener(key: try key(entry.key), counter: try #require(entry.counter))
        #expect(control.open(sealedPayload: try Self.sealedPayload(seal.helloSealedReply.frame)) != nil, "the genuine frame opens")
        let opener = LinkOpener(key: try key(entry.key), counter: try #require(entry.counter))
        #expect(opener.open(sealedPayload: try Self.sealedPayload(Hex.encode(frame))) == nil, "\(entry.reason)")
        #expect(opener.open(sealedPayload: try Self.sealedPayload(seal.helloSealedReply.frame)) == nil, "a failed frame poisons the opener")
    }

    @Test func aSkippedCounterFailsWhereOneIsDueAndOpensOnlyAtTwo() throws {
        let entry = try reject("skippedCounter")
        let payload = try Self.sealedPayload(try #require(entry.frame))
        let due = try #require(entry.counter)
        #expect(due == 1)
        #expect(LinkOpener(key: try key(entry.key), counter: due).open(sealedPayload: payload) == nil, "\(entry.reason)")
        let atTwo = LinkOpener(key: try key(entry.key), counter: 2).open(sealedPayload: payload)
        #expect(atTwo.map(Hex.encode) == seal.proofResponder.record)
    }

    @Test func aFrameSealedTheOtherWayFails() throws {
        let entry = try reject("wrongDirection")
        let payload = try Self.sealedPayload(try #require(entry.frame))
        let counter = try #require(entry.counter)
        #expect(LinkOpener(key: try key(entry.key), counter: counter).open(sealedPayload: payload) == nil, "\(entry.reason)")
        let reflected = LinkOpener(key: try key("keyR2D"), counter: counter).open(sealedPayload: payload)
        #expect(reflected == LinkRecord(.hello, payload: dialerHello).encoded, "it is Alice's HELLO under keyR2D")
    }

    /// The all-zero point reads as a KEY_SHARE (it is 32 bytes) and Bob's exchange with it is a failed seal.
    @Test func aLowOrderKeyShareIsAFailedSeal() throws {
        let entry = try reject("lowOrderKeyShare")
        #expect(entry.readBy == "bob")
        let record = try Self.onlyRecord(hexBytes(try #require(entry.record)))
        #expect(record.tag == .keyShare)
        let bob = try #require(LinkSeal.Ephemeral(scalar: hexBytes(seal.keyShareResponder.scalar)))
        #expect(throws: LinkSeal.Failure.lowOrderPoint, "\(entry.reason)") {
            try LinkSeal.derive(bob, peerShare: record.payload, role: .responder)
        }
    }

    /// A 31-byte KEY_SHARE fails from its header, before the payload; were it read, the exchange would refuse it too.
    @Test func aShortKeyShareFailsFromItsHeader() throws {
        let entry = try reject("shortKeyShare")
        let bytes = hexBytes(try #require(entry.record))
        var reader = LinkRecordReader()
        reader.append(bytes.prefix(LinkRecord.headerBytes))
        #expect(throws: LinkRecordError.badLength(tag: LinkRecord.Tag.keyShare.rawValue, length: 31), "\(entry.reason)") {
            try reader.next()
        }
        let bob = try #require(LinkSeal.Ephemeral(scalar: hexBytes(seal.keyShareResponder.scalar)))
        #expect(throws: LinkSeal.Failure.keyShareLength) {
            try LinkSeal.derive(bob, peerShare: Array(bytes.dropFirst(LinkRecord.headerBytes)), role: .responder)
        }
    }

    /// The SEALED headers stating 65,553 and 16 bytes fail from the header alone, and the opener refuses either length.
    @Test(arguments: [("oversizeFrame", UInt32(65_553)), ("emptyFrame", 16)])
    func aSealedHeaderOutOfRangeFailsFromTheHeader(name: String, length: UInt32) throws {
        let entry = try reject(name)
        let bytes = hexBytes(try #require(entry.record))
        var reader = LinkRecordReader()
        reader.append(bytes.prefix(LinkRecord.headerBytes))
        #expect(throws: LinkRecordError.badLength(tag: LinkRecord.Tag.sealed.rawValue, length: length), "\(entry.reason)") {
            try reader.next()
        }
        #expect(!LinkOpener.payloadByteRange.contains(Int(length)))
        #expect(!LinkRecord.sealedPayloadBytes.contains(Int(length)))
        if name == "emptyFrame" {
            let payload = Array(bytes.dropFirst(LinkRecord.headerBytes))
            #expect(payload.count == 16)
            #expect(LinkOpener(key: try key("keyR2D"), counter: 0).open(sealedPayload: payload) == nil)
        }
    }

    /// Bob's genuine v1 signature over the same HELLOs: proven on a plain link, refused on the sealed one.
    @Test func aV1ProofFailsOnASealedLink() throws {
        let entry = try reject("v1ProofOnSealedLink")
        #expect(entry.verifyAs == "transcriptResponder" && entry.signer == "bob")
        let bob = try identity(try #require(entry.signer))
        let payload = try Self.onlyRecord(hexBytes(try #require(entry.record))).payload
        func verify(_ form: LinkProof.Form) -> LinkProof.Outcome {
            LinkProof.verify(
                payload, claimedId: bob.nodeId, form: form, signer: .responder, dialerHello: dialerHello, responderHello: responderHello)
        }
        #expect(verify(try transcriptForm) == .failed(.badSignature), "\(entry.reason)")
        #expect(verify(.plain) == .proven(bob.bundle), "it is Bob's v1 signature")
    }

    /// Bob's genuine v2 signature over a transcript whose `eR` is `ff..ff`: proven over those shares, refused over the link's.
    @Test func aProofOverASwappedKeyShareFails() throws {
        let entry = try reject("swappedKeyShare")
        #expect(entry.verifyAs == "transcriptResponder" && entry.signer == "bob")
        let bob = try identity(try #require(entry.signer))
        let payload = try Self.onlyRecord(hexBytes(try #require(entry.record))).payload
        func verify(_ form: LinkProof.Form) -> LinkProof.Outcome {
            LinkProof.verify(
                payload, claimedId: bob.nodeId, form: form, signer: .responder, dialerHello: dialerHello, responderHello: responderHello)
        }
        #expect(verify(try transcriptForm) == .failed(.badSignature), "\(entry.reason)")
        let dialerShare = Array(hexBytes(seal.keyShareDialer.record).dropFirst(LinkRecord.headerBytes))
        let swapped = try #require(LinkSeal.KeyShares(dialer: dialerShare, responder: [UInt8](repeating: 0xFF, count: 32)))
        #expect(verify(.sealed(swapped)) == .proven(bob.bundle), "it is Bob's v2 signature over the swapped share")
    }
}
