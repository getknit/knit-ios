import KnitCrypto
import KnitWire
import Testing

/// v1 DMs and frame signatures, ported from knit-next's `MessageCryptoTest` and `AesGcmTest`.
@Suite struct MessageCryptoTests {
    private let alice = IdentityKeys.generate()
    private let bob = IdentityKeys.generate()
    private let carol = IdentityKeys.generate()

    private func content(_ body: String) -> [UInt8] {
        MessageContent(body: body, mentions: [Mention(nodeId: "bob00000", name: "Bob")]).encoded
    }

    private func header(_ id: String, sentAt: Int64 = 1, to recipient: IdentityKeys) -> [UInt8] {
        MessageCrypto.header(id: id, senderId: alice.nodeId.string, sentAt: sentAt, thread: recipient.nodeId.string)
    }

    private func seal(_ body: String, header: [UInt8], to recipients: IdentityKeys...) throws -> EncEnvelope {
        let bundles = Dictionary(uniqueKeysWithValues: recipients.map { ($0.nodeId, $0.bundle) })
        return try #require(try MessageCrypto.seal(content(body), header: header, to: bundles))
    }

    @Test func theHeaderIsTheFourFieldsJoinedByBars() {
        #expect(MessageCrypto.header(id: "m1", senderId: "a", sentAt: 100, thread: "b") == Array("m1|a|100|b".utf8))
        #expect(MessageCrypto.header(id: "m1", senderId: "a", sentAt: -1, thread: "") == Array("m1|a|-1|".utf8))
    }

    @Test func aDMRoundTrips() throws {
        let header = header("m1", sentAt: 100, to: bob)
        let envelope = try seal("hi bob", header: header, to: bob)
        let opened = try #require(MessageCrypto.open(envelope, header: header, as: bob))
        #expect(opened.body == "hi bob")
        #expect(opened.mentions.first?.name == "Bob")
    }

    /// `sealedEnvelopeSurvivesTheWireCodec`: open the decoded copy of a `chat` payload, not the sealed value.
    @Test func aSealedEnvelopeSurvivesTheWireCodec() throws {
        let header = header("m6", to: bob)
        let envelope = try seal("over the wire", header: header, to: bob)
        let decoded = try #require(try ChatContent(decoding: ChatContent(enc: envelope).encoded).enc)
        #expect(MessageCrypto.open(decoded, header: header, as: bob)?.body == "over the wire")
    }

    @Test func aReplyQuoteStaysInsideTheCiphertext() throws {
        let header = header("m8", to: bob)
        let reply = ReplyRef(messageId: "m0", authorId: alice.nodeId.string, author: "Alice", snippet: "see you at 8", hasAttachment: true)
        let bundles = [bob.nodeId: bob.bundle]
        let sealed = try #require(
            try MessageCrypto.seal(MessageContent(body: "on my way", replyTo: reply).encoded, header: header, to: bundles))
        let decoded = try #require(try ChatContent(decoding: ChatContent(enc: sealed).encoded).enc)
        #expect(MessageCrypto.open(decoded, header: header, as: bob)?.replyTo == reply)
    }

    /// `groupMessageDecryptsForEveryMember`: a group message's thread is the group id, and each member opens it.
    @Test func aGroupMessageOpensForEveryMember() throws {
        let header = MessageCrypto.header(id: "g1", senderId: alice.nodeId.string, sentAt: 5, thread: "g-team")
        let envelope = try seal("hi team", header: header, to: bob, carol)
        #expect(MessageCrypto.open(envelope, header: header, as: bob)?.body == "hi team")
        #expect(MessageCrypto.open(envelope, header: header, as: carol)?.body == "hi team")
        let otherGroup = MessageCrypto.header(id: "g1", senderId: alice.nodeId.string, sentAt: 5, thread: "g-other")
        #expect(MessageCrypto.open(envelope, header: otherGroup, as: bob) == nil)
    }

    @Test func everyRecipientOpensAndNobodyElseDoes() throws {
        let header = MessageCrypto.header(id: "g1", senderId: alice.nodeId.string, sentAt: 5, thread: "g-team")
        let envelope = try seal("hi team", header: header, to: bob, carol)
        #expect(MessageCrypto.open(envelope, header: header, as: bob)?.body == "hi team")
        #expect(MessageCrypto.open(envelope, header: header, as: carol)?.body == "hi team")
        #expect(MessageCrypto.open(envelope, header: header, as: alice) == nil, "no wrapped key for the sender")
    }

    @Test func wrappedKeysAreSortedByNodeIdAndEightyBytesEach() throws {
        let people = (0..<6).map { _ in IdentityKeys.generate() }
        let bundles = Dictionary(uniqueKeysWithValues: people.map { ($0.nodeId, $0.bundle) })
        let envelope = try #require(try MessageCrypto.seal(content("hi"), header: [1], to: bundles))
        let order = envelope.keys.map(\.to)
        let sorted = people.map(\.nodeId).sorted().map(\.string)
        #expect(order == sorted)
        #expect(envelope.keys.allSatisfy { $0.wk.count == 80 })
        #expect(envelope.nonce.count == MessageCrypto.nonceByteCount)
        #expect(envelope.ct.count == content("hi").count + MessageCrypto.tagByteCount)
        #expect(envelope.version == EncEnvelope.Version.staticKeys)
    }

    /// v1 is the default, so the envelope's map leaves `v` out, exactly as kotlinx does.
    @Test func aV1EnvelopeOmitsItsVersion() throws {
        let envelope = try seal("hi", header: [1], to: bob)
        guard case .map(let entries) = envelope.cbor else {
            Issue.record("an envelope is a map")
            return
        }
        let keys = entries.map(\.key)
        #expect(keys == [.text("nonce"), .text("ct"), .text("keys")])
    }

    @Test func tamperingWithAnyPartFailsToOpen() throws {
        let header = header("m3", to: bob)
        let envelope = try seal("a longer secret than one block", header: header, to: bob)

        var lastByte = envelope
        lastByte.ct[lastByte.ct.count - 1] ^= 1
        #expect(MessageCrypto.open(lastByte, header: header, as: bob) == nil)

        var firstByte = envelope
        firstByte.ct[0] ^= 1
        #expect(MessageCrypto.open(firstByte, header: header, as: bob) == nil)

        var nonce = envelope
        nonce.nonce[0] ^= 1
        #expect(MessageCrypto.open(nonce, header: header, as: bob) == nil)

        var wrapped = envelope
        wrapped.keys[0].wk[40] ^= 1
        #expect(MessageCrypto.open(wrapped, header: header, as: bob) == nil)

        var truncated = envelope
        truncated.keys[0].wk = Array(truncated.keys[0].wk.prefix(MessageCrypto.encapsulatedKeyByteCount))
        #expect(MessageCrypto.open(truncated, header: header, as: bob) == nil)

        var shortBody = envelope
        shortBody.ct = Array(shortBody.ct.prefix(MessageCrypto.tagByteCount - 1))
        #expect(MessageCrypto.open(shortBody, header: header, as: bob) == nil)
    }

    /// The header is the AAD and the HPKE `info`, so a different `sentAt` opens nothing.
    @Test func aMismatchedHeaderFailsToOpen() throws {
        let envelope = try seal("hi", header: header("m5", sentAt: 1, to: bob), to: bob)
        #expect(MessageCrypto.open(envelope, header: header("m5", sentAt: 2, to: bob), as: bob) == nil)
    }

    @Test func aBodyThatIsNotMessageContentOpensToNil() throws {
        let header = header("m4", to: bob)
        let envelope = try #require(try MessageCrypto.seal(CBOR.text("not a map").encoded, header: header, to: [bob.nodeId: bob.bundle]))
        #expect(MessageCrypto.open(envelope, header: header, as: bob) == nil)
    }

    @Test func noRecipientsSealsNothing() throws {
        #expect(try MessageCrypto.seal(content("hi"), header: [1], to: [:]) == nil)
    }

    /// Low-order X25519 points: zero, one, and the order-8 point, in the RFC 7748 little-endian encoding. Any
    /// exchange with one of them gives an all-zero secret, which RFC 9180 says both sides must refuse.
    private static let lowOrderPoints = [
        [UInt8](repeating: 0, count: 32),
        [1] + [UInt8](repeating: 0, count: 31),
        hexBytes("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"),
    ]

    /// `noWrapLeftIsNullNotAThrow` (#172, `MessageCryptoTest.kt` at `4f3cd995`): Tink refuses to wrap to a low-order key,
    /// and so does this port, although swift-crypto would not. With no wrap left nobody could read the frame, so the seal
    /// answers `nil`, as for no recipients, never a throw.
    @Test(arguments: lowOrderPoints)
    func noWrapLeftIsNullNotAThrow(point: [UInt8]) throws {
        let hostile = try #require(PublicKeyBundle(signingKey: bob.bundle.signingKey, agreementKey: point))
        #expect(PublicKeyBundle(encoded: hostile.encoded) == hostile, "the bundle still parses, as on Android")
        #expect(!hostile.hasUsableAgreementKey)
        #expect(try MessageCrypto.seal(content("hi"), header: [1], to: [hostile.nodeId: hostile]) == nil)
    }

    /// `aRecipientWhoseKeyHpkeRefusesIsSkippedAndTheRestStillRead` (#172): a forged bundle, a real signing key beside a
    /// low-order X25519 key, is skipped like an unknown key, so one such group member never strands the post for the rest.
    @Test(arguments: lowOrderPoints)
    func aRecipientWhoseKeyHpkeRefusesIsSkippedAndTheRestStillRead(point: [UInt8]) throws {
        let mallory = try #require(PublicKeyBundle(signingKey: carol.bundle.signingKey, agreementKey: point))
        let header = MessageCrypto.header(id: "m9", senderId: alice.nodeId.string, sentAt: 1, thread: "g-1")
        let sealed = try MessageCrypto.seal(content("hello group"), header: header, to: [bob.nodeId: bob.bundle, mallory.nodeId: mallory])
        let envelope = try #require(sealed)
        #expect(envelope.keys.map(\.to) == [bob.nodeId.string])
        #expect(MessageCrypto.open(envelope, header: header, as: bob)?.body == "hello group")
    }

    /// A sender who puts a low-order point in `enc` is refused on open too, as Tink refuses it.
    @Test(arguments: lowOrderPoints)
    func aLowOrderEncapsulatedKeyFailsToOpen(point: [UInt8]) throws {
        let header = header("m9", to: bob)
        var envelope = try seal("hi", header: header, to: bob)
        envelope.keys[0].wk = point + envelope.keys[0].wk.dropFirst(MessageCrypto.encapsulatedKeyByteCount)
        #expect(MessageCrypto.open(envelope, header: header, as: bob) == nil)
    }

    /// `carrierAuthenticatesFrameWithoutDecrypting`: a relay checks the frame signature over the signed
    /// envelope bytes, and cannot read the DM inside.
    @Test func aCarrierAuthenticatesAFrameItCannotRead() throws {
        let header = header("m1", sentAt: 100, to: bob)
        let envelope = try seal("hi bob", header: header, to: bob)
        let relay = RelayEnvelope(
            type: .chat,
            id: "m1",
            senderId: alice.nodeId.string,
            sentAt: 100,
            recipientId: bob.nodeId.string,
            payload: ChatContent(enc: envelope).encoded
        )
        let signed = relay.encoded
        let signature = try alice.signature(for: signed)
        #expect(signature.count == 64)
        #expect(alice.bundle.isValidSignature(signature, for: signed))
        #expect(MessageCrypto.open(envelope, header: header, as: carol) == nil)
    }

    @Test func signaturesVerifyOnlyForTheirKeyAndBytes() throws {
        let bytes = Array("frame-canonical-bytes".utf8)
        let signature = try alice.signature(for: bytes)
        #expect(alice.bundle.isValidSignature(signature, for: bytes))
        #expect(!alice.bundle.isValidSignature(signature, for: Array("frame-canonical-bytez".utf8)))
        #expect(!bob.bundle.isValidSignature(signature, for: bytes))
        #expect(!alice.bundle.isValidSignature([], for: bytes))
    }
}
