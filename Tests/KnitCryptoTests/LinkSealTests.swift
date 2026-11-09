import Crypto
import KnitWire
import Testing

@testable import KnitCrypto

/// A sealed link's key exchange and frames (the `link-seal` contract, §5; knit-next #286), against the contract's vector
/// setup: Alice dials Bob, her ephemeral scalar `40…5f` and his `60…7f`. The keys are cross-checked against an RFC 5869
/// HKDF built on HMAC alone, and each frame's nonce and AAD against a bare `AES.GCM.open`, so nothing here only checks the
/// code against itself.
///
/// knit-next's `link.seal` entries (`keyed-v1.json`, contract "Vectors") replay through the same seam once they are
/// synced: ``LinkSeal/Ephemeral/init(scalar:)`` fixes each side's key, ``LinkSeal/Session``'s `shared`, `keyD2R` and
/// `keyR2D` compare with the file's, and ``LinkSealer/init(key:counter:)`` rebuilds a frame at any counter
/// (`skippedCounter`, `wrongDirection`).
@Suite struct LinkSealTests {
    private static let aliceScalar = (0x40...0x5F).map { UInt8($0) }
    private static let bobScalar = (0x60...0x7F).map { UInt8($0) }

    /// Both sides of the contract's link: Alice dialed, Bob answered.
    private struct Link {
        let alice: LinkSeal.Session
        let bob: LinkSeal.Session
    }

    private func ephemeral(_ scalar: [UInt8]) throws -> LinkSeal.Ephemeral {
        try #require(LinkSeal.Ephemeral(scalar: scalar))
    }

    private func link() throws -> Link {
        let alice = try ephemeral(Self.aliceScalar)
        let bob = try ephemeral(Self.bobScalar)
        let bobShare = bob.keyShare
        let aliceSession = try LinkSeal.derive(alice, peerShare: bobShare, role: .dialer)
        return Link(alice: aliceSession, bob: try LinkSeal.derive(bob, peerShare: aliceSession.shares.dialer, role: .responder))
    }

    /// A record's payload, after checking its 5-byte header is tag 11 and its length.
    private static func payload(of record: [UInt8]) throws -> [UInt8] {
        try #require(record.count > LinkRecord.headerBytes)
        #expect(record[0] == 0x0B)
        let length = record[1...4].reduce(0) { $0 << 8 | Int($1) }
        #expect(length == record.count - LinkRecord.headerBytes)
        return Array(record.dropFirst(LinkRecord.headerBytes))
    }

    @Test func theSealBitIsPinnedAndRidesOnlyWithTheProof() {
        // `Protocol.CAP_LINK_SEAL` (the contract, §1): in `local`, so the HELLO reads `1c215f`, and never without the proof.
        #expect(Capabilities.linkSeal.rawValue == 0x100000)
        #expect(Capabilities.local.contains(.linkSeal) && Capabilities.local.contains(.linkProof))
        #expect(Capabilities.local.rawValue & 0xFF == 0x5F, "the advert's low byte doesn't move; the flags byte carries it")
    }

    // MARK: The key schedule

    @Test func bothSidesDeriveTheSameKeysInOppositeDirections() throws {
        let link = try link()
        #expect(link.alice.shares == link.bob.shares)
        #expect(link.alice.shared == link.bob.shared)
        #expect(link.alice.keyD2R == link.bob.keyD2R && link.alice.keyR2D == link.bob.keyR2D)
        #expect(link.alice.keyD2R != link.alice.keyR2D)
        let fromAlice = try #require(link.alice.sealer.seal(Array("to bob".utf8)))
        #expect(link.bob.opener.open(sealedPayload: try Self.payload(of: fromAlice)) == Array("to bob".utf8))
        let fromBob = try #require(link.bob.sealer.seal(Array("to alice".utf8)))
        #expect(link.alice.opener.open(sealedPayload: try Self.payload(of: fromBob)) == Array("to alice".utf8))
    }

    @Test func theKeysAreTheContractsHKDFOverTheExchange() throws {
        let link = try link()
        let alice = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.aliceScalar)
        let bob = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.bobScalar)
        let eD = Array(alice.publicKey.rawRepresentation)
        let eR = Array(bob.publicKey.rawRepresentation)
        #expect(link.alice.shares.dialer == eD && link.alice.shares.responder == eR)
        #expect(link.alice.shares.salt == eD + eR && link.alice.shares.salt.count == 64, "the dialer's share first")
        let shared = copiedBytes(try alice.sharedSecretFromKeyAgreement(with: bob.publicKey))
        #expect(link.alice.shared == shared)
        #expect(LinkSeal.infoDialerToResponder == Array("knit/link/v1/seal/d2r".utf8) && LinkSeal.infoDialerToResponder.count == 21)
        #expect(LinkSeal.infoResponderToDialer == Array("knit/link/v1/seal/r2d".utf8) && LinkSeal.infoResponderToDialer.count == 21)
        // The salt keys the extract and `ss` is what it authenticates (Tink's order); swapped, these would differ.
        #expect(link.alice.keyD2R == referenceHKDF(ikm: shared, salt: eD + eR, info: LinkSeal.infoDialerToResponder, count: 32))
        #expect(link.alice.keyR2D == referenceHKDF(ikm: shared, salt: eD + eR, info: LinkSeal.infoResponderToDialer, count: 32))
    }

    @Test func eachEphemeralIsFreshAndItsShareIsItsPublicKey() throws {
        let first = LinkSeal.Ephemeral()
        let second = LinkSeal.Ephemeral()
        #expect(first.keyShare.count == LinkSeal.keyShareByteCount && LinkSeal.keyShareByteCount == 32)
        #expect(first.keyShare != second.keyShare)
        let fixed = try ephemeral(Self.aliceScalar)
        let alice = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.aliceScalar)
        #expect(fixed.keyShare == Array(alice.publicKey.rawRepresentation))
        #expect(LinkSeal.Ephemeral(scalar: Array(Self.aliceScalar.dropLast())) == nil)
    }

    @Test func anEphemeralDerivesOnceWhateverTheOutcome() throws {
        let bob = try ephemeral(Self.bobScalar)
        let spent = try ephemeral(Self.aliceScalar)
        _ = try LinkSeal.derive(spent, peerShare: bob.keyShare, role: .dialer)
        #expect(throws: LinkSeal.Failure.spent) { try LinkSeal.derive(spent, peerShare: bob.keyShare, role: .dialer) }
        let refused = try ephemeral(Self.aliceScalar)
        #expect(throws: LinkSeal.Failure.keyShareLength) { try LinkSeal.derive(refused, peerShare: [1], role: .dialer) }
        #expect(throws: LinkSeal.Failure.spent, "a failed seal takes the private half too") {
            try LinkSeal.derive(refused, peerShare: bob.keyShare, role: .dialer)
        }
    }

    @Test(arguments: [31, 0, 33, 64])
    func aShareOfAnyOtherLengthIsAFailedSeal(length: Int) throws {
        let share = [UInt8](repeating: 0x09, count: length)
        #expect(throws: LinkSeal.Failure.keyShareLength) {
            try LinkSeal.derive(try ephemeral(Self.aliceScalar), peerShare: share, role: .dialer)
        }
        #expect(LinkSeal.KeyShares(dialer: share, responder: [UInt8](repeating: 9, count: 32)) == nil)
        #expect(LinkSeal.KeyShares(dialer: [UInt8](repeating: 9, count: 32), responder: share) == nil)
    }

    /// Low-order points on Curve25519 (RFC 7748; the set libsodium and Tink refuse): each sends every clamped scalar to an
    /// all-zero `ss`, which swift-crypto and CryptoKit return where Tink throws.
    @Test(arguments: [
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0100000000000000000000000000000000000000000000000000000000000000",
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
        "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    ])
    func aLowOrderShareIsAFailedSeal(share: String) throws {
        for role in [LinkProof.Role.dialer, .responder] {
            #expect(throws: LinkSeal.Failure.lowOrderPoint) {
                try LinkSeal.derive(try ephemeral(Self.aliceScalar), peerShare: hexBytes(share), role: role)
            }
        }
    }

    // MARK: Frames

    @Test func aFrameIsTheRecordTheContractLaysOut() throws {
        let link = try link()
        let plaintext = Array("hello".utf8)
        let record = try #require(link.alice.sealer.seal(plaintext))
        #expect(record.count == plaintext.count + LinkSealer.overheadBytes && LinkSealer.overheadBytes == 21)
        #expect(Array(record.prefix(5)) == [0x0B, 0x00, 0x00, 0x00, 0x15], "tag 11, then len = 5 + 16")
        // Opened by hand: kD2R, the nonce `00 00 00 00 ‖ u64be(0)`, and the 5 header bytes as the AAD.
        let body = record.dropFirst(5)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: [UInt8](repeating: 0, count: 12)), ciphertext: body.dropLast(16), tag: body.suffix(16))
        let opened = try AES.GCM.open(box, using: SymmetricKey(data: link.alice.keyD2R), authenticating: Array(record.prefix(5)))
        #expect(Array(opened) == plaintext)
        let second = try #require(link.alice.sealer.seal(plaintext))
        let secondBody = second.dropFirst(5)
        let secondBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: [UInt8](repeating: 0, count: 11) + [1]),
            ciphertext: secondBody.dropLast(16),
            tag: secondBody.suffix(16))
        let reopened = try AES.GCM.open(
            secondBox, using: SymmetricKey(data: link.alice.keyD2R), authenticating: Array(second.prefix(5)))
        #expect(Array(reopened) == plaintext, "the second frame at counter 1")
        #expect(second != record, "the same plaintext never seals to the same bytes twice")
    }

    @Test func framesOpenInCounterOrder() throws {
        let link = try link()
        let texts = (0..<5).map { Array("frame \($0)".utf8) }
        let records = try texts.map { try #require(link.bob.sealer.seal($0)) }
        for (record, text) in zip(records, texts) {
            #expect(link.alice.opener.open(sealedPayload: try Self.payload(of: record)) == text)
        }
    }

    @Test func aFrameOpenedOutOfOrderFailsAndPoisons() throws {
        let link = try link()
        let first = try #require(link.alice.sealer.seal([1]))
        let second = try #require(link.alice.sealer.seal([2]))
        #expect(link.bob.opener.open(sealedPayload: try Self.payload(of: second)) == nil)
        #expect(link.bob.opener.open(sealedPayload: try Self.payload(of: first)) == nil, "poisoned by the first failure")
    }

    @Test func aReplayedFrameFails() throws {
        let link = try link()
        let first = try Self.payload(of: try #require(link.alice.sealer.seal([1])))
        #expect(link.bob.opener.open(sealedPayload: first) == [1])
        #expect(link.bob.opener.open(sealedPayload: first) == nil)
    }

    @Test func aFrameSealedAtASkippedCounterFails() throws {
        // `skippedCounter`: a frame sealed at counter 2 where 1 is due.
        let link = try link()
        #expect(link.bob.opener.open(sealedPayload: try Self.payload(of: try #require(link.alice.sealer.seal([0])))) == [0])
        let skipping = LinkSealer(key: SymmetricKey(data: link.alice.keyD2R), counter: 2)
        let skipped = try #require(skipping.seal([2]))
        #expect(link.bob.opener.open(sealedPayload: try Self.payload(of: skipped)) == nil)
    }

    @Test(arguments: [0, 3, 4, 5, 20])
    func aFlippedBitFails(at index: Int) throws {
        // `flippedBit`: ciphertext (0…4) or tag (5…20) of a 5-byte plaintext.
        let link = try link()
        var payload = try Self.payload(of: try #require(link.alice.sealer.seal(Array("hello".utf8))))
        payload[index] ^= 0x01
        #expect(link.bob.opener.open(sealedPayload: payload) == nil)
    }

    @Test func aFrameNeverOpensInItsOwnDirection() throws {
        // `wrongDirection`: Alice's own frames don't open with Alice's opener, nor Alice's frame sealed under kR2D with Bob's.
        let link = try link()
        let own = try Self.payload(of: try #require(link.alice.sealer.seal([7])))
        #expect(link.alice.opener.open(sealedPayload: own) == nil)
        let underReverse = LinkSealer(key: SymmetricKey(data: link.alice.keyR2D), counter: 0)
        #expect(link.bob.opener.open(sealedPayload: try Self.payload(of: try #require(underReverse.seal([7])))) == nil)
    }

    @Test func emptyAndOversizePlaintextsAreRefusedForGood() throws {
        let link = try link()
        #expect(LinkSealer.maxPlaintextBytes == 65_536)
        let largest = try #require(link.alice.sealer.seal([UInt8](repeating: 1, count: 65_536)))
        #expect(Array(largest.prefix(5)) == [0x0B, 0x00, 0x01, 0x00, 0x10], "len 65,552")
        #expect(link.bob.opener.open(sealedPayload: try Self.payload(of: largest))?.count == 65_536)
        #expect(link.alice.sealer.seal([UInt8](repeating: 1, count: 65_537)) == nil)
        #expect(link.alice.sealer.seal([1]) == nil, "poisoned")
        let empty = try self.link()
        #expect(empty.alice.sealer.seal([UInt8]()) == nil)
        #expect(empty.alice.sealer.seal([1]) == nil, "poisoned")
    }

    @Test(arguments: [0, 15, 16, 65_553])
    func aPayloadOutsideTheRangeFails(length: Int) throws {
        // `emptyFrame` (len 16) and `oversizeFrame` (len 65,553): the reader refuses both from the header, and so does this.
        let link = try link()
        #expect(LinkOpener.payloadByteRange == 17...65_552)
        #expect(link.bob.opener.open(sealedPayload: [UInt8](repeating: 0, count: length)) == nil)
        #expect(link.bob.opener.open(sealedPayload: try Self.payload(of: try #require(link.alice.sealer.seal([1])))) == nil, "poisoned")
    }

    @Test func neitherHalfPassesTheTwoToTheFortyEighthFrame() throws {
        let key = SymmetricKey(data: [UInt8](repeating: 0x11, count: 32))
        let last = LinkSeal.counterLimit - 1
        #expect(LinkSeal.counterLimit == 281_474_976_710_656)
        let sealer = LinkSealer(key: key, counter: last)
        let final = try #require(sealer.seal([1]))
        #expect(sealer.seal([2]) == nil, "frame 2^48 is never sealed")
        let opener = LinkOpener(key: key, counter: last)
        #expect(opener.open(sealedPayload: try Self.payload(of: final)) == [1])
        let beyond = LinkSealer(key: key, counter: LinkSeal.counterLimit)
        #expect(beyond.seal([1]) == nil)
        #expect(opener.open(sealedPayload: try Self.payload(of: final)) == nil, "frame 2^48 is never opened")
    }

    // MARK: The inner stream

    @Test(arguments: [1, 2, 7, 23, 64, 4096])
    func anySplitOfTheInnerStreamReassembles(sliceBytes: Int) throws {
        // The plaintexts, in counter order, are the record stream; frame boundaries mean nothing (contract §5).
        let link = try link()
        let records = [
            LinkRecord(.hello, payload: Array("4cgq2pnhh6p3j3afwsue3chrpi|1|1c215f|n000102030405060708090a0b0c0d0e0f".utf8)),
            LinkRecord(.proof, payload: [UInt8](repeating: 0xAB, count: 128)),
            LinkRecord(.digest, payload: Array(#"{"ids":["a","b"]}"#.utf8)),
            LinkRecord(.frame, payload: [UInt8](repeating: 0x5A, count: 3000)),
        ]
        let stream = try records.flatMap { try #require($0.encoded) }
        var opened: [UInt8] = []
        var start = 0
        while start < stream.count {
            let end = min(start + sliceBytes, stream.count)
            let frame = try #require(link.bob.sealer.seal(stream[start..<end]))
            opened += try #require(link.alice.opener.open(sealedPayload: try Self.payload(of: frame)))
            start = end
        }
        #expect(opened == stream)
        var reader = LinkRecordReader()
        reader.append(opened)
        for record in records {
            let read = try #require(try reader.next())
            #expect(read.tag == record.tag && read.payload == record.payload)
        }
        #expect(!reader.hasPartialRecord)
    }

    // MARK: Ownership and secrecy

    @Test func theSealerCrossesIntoAnotherTaskAndKeepsOneCounter() async throws {
        let link = try link()
        let sealer = link.alice.sealer
        let frames = await Task.detached { (0..<3).compactMap { sealer.seal([UInt8($0)]) } }.value
        let fourth = try #require(link.alice.sealer.seal([3]))
        for (index, frame) in (frames + [fourth]).enumerated() {
            #expect(link.bob.opener.open(sealedPayload: try Self.payload(of: frame)) == [UInt8(index)])
        }
    }

    @Test func nothingPrintsAKey() throws {
        let alice = try ephemeral(Self.aliceScalar)
        let session = try LinkSeal.derive(try ephemeral(Self.bobScalar), peerShare: alice.keyShare, role: .responder)
        let secrets =
            [Hex.encode(Self.aliceScalar), Hex.encode(Self.bobScalar), Hex.encode(session.shared)]
            + [Hex.encode(session.keyD2R), Hex.encode(session.keyR2D)]
        let values: [Any] = [alice, session, session.sealer, session.opener]
        for value in values {
            var dumped = ""
            dump(value, to: &dumped)
            let printed = [String(describing: value), String(reflecting: value), "\(value)", dumped]
            for text in printed {
                #expect(!secrets.contains { text.lowercased().contains($0) }, "\(type(of: value))")
                #expect(text.count < 80, "no bytes in any form: \(text)")
            }
        }
        #expect("\(session)" == "LinkSeal.Session" && "\(session.sealer)" == "LinkSealer" && "\(session.opener)" == "LinkOpener")
        #expect("\(alice)" == "LinkSeal.Ephemeral")
    }
}
