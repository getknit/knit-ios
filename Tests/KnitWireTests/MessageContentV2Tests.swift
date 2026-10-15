import KnitTestSupport
import KnitWire
import Testing

/// The v3 compact plaintext (`MessageContentV2.kt`, knit-next ADR 059), ported case by case from knit-next's
/// `MessageContentV2Test` (at `ac491f4c`): a lossless round trip for everything the content carries, a refusal (never a
/// mangling) for anything without a canonical raw form, and a byte layout pinned by hand. The nine `messageContentV2*`
/// fixtures, and what the decoder does with what no encoder writes, are ``CompactPlaintextTests``'.
@Suite struct MessageContentV2Tests {
    private let frameId = fixtureFrameId(1)
    private let nodeId = fixtureNodeId(3).string
    private let hash = String(repeating: "ab", count: 32)
    private let key = Base64.encode((0..<32).map { UInt8($0) })

    private func roundTrip(_ content: MessageContent) throws -> MessageContent {
        let bytes = try #require(MessageContentV2.encode(content), "must have a compact form")
        return try #require(MessageContentV2.decode(bytes), "must decode")
    }

    // MARK: knit-next's MessageContentV2Test

    @Test func aTickRoundTripsAndIsPinnedByteForByte() throws {
        let tick = MessageContent(body: "", ctl: MessageContent.Control.receipt, ack: frameId)
        let bytes = try #require(MessageContentV2.encode(tick))
        // map(2) { 7: 5, 8: h'<16 bytes>' }: no body, no version, 21 bytes against the named layout's 39.
        #expect(bytes.count == 21)
        #expect(Array(bytes.prefix(5)) == [0xA2, 0x07, 0x05, 0x08, 0x50])
        #expect(Array(bytes.suffix(16)) == FrameId.bytes(of: frameId))
        #expect(tick.encoded.count == 39)
        #expect(try roundTrip(tick) == tick)
    }

    @Test func aTwelveAckBatchIsSeventyTwoBytesLighter() throws {
        let acks = (1...12).map(fixtureFrameId)
        let batch = MessageContent(body: "", ctl: MessageContent.Control.receipt, acks: acks)
        let compact = try #require(MessageContentV2.encode(batch))
        #expect(batch.encoded.count - compact.count >= 72, "\(batch.encoded.count) - \(compact.count)")
        #expect(try roundTrip(batch).acks == acks)
    }

    @Test func everyFieldRoundTrips() throws {
        let full = MessageContent(
            body: "see you at the gate — 👍",
            mentions: [Mention(nodeId: nodeId, name: "Alice"), Mention(nodeId: fixtureNodeId(4).string, name: "Bob (2)")],
            attachmentHash: hash,
            attachmentMime: "image/jpeg",
            attachmentKey: key,
            replyTo: ReplyRef(messageId: fixtureFrameId(2), authorId: nodeId, author: "Alice", snippet: "earlier", hasAttachment: true),
            ctl: nil,
            ack: nil,
            rp: ReactionContent(messageId: fixtureFrameId(3), emoji: "🔥"),
            pr: ProfilePayload(
                name: "Alice",
                status: "out",
                avatarHash: String(repeating: "cd", count: 32),
                version: 1_756_100_000_000,
                openToChat: true
            ),
            acks: [fixtureFrameId(4), fixtureFrameId(5)]
        )
        #expect(try roundTrip(full) == full)
        let retraction = MessageContent(
            body: "", ctl: MessageContent.Control.reaction, rp: ReactionContent(messageId: frameId, emoji: nil))
        #expect(try roundTrip(retraction) == retraction)
        let plain = MessageContent(body: "just text")
        #expect(try roundTrip(plain) == plain)
        // A plain message encodes to exactly { 1: body }.
        #expect(MessageContentV2.encode(plain)?.first == 0xA1)
    }

    @Test func anythingWithoutACanonicalRawFormIsRefusedNotMangled() throws {
        let uuid = "123e4567-e89b-12d3-a456-426614174000"
        #expect(MessageContentV2.encode(MessageContent(body: "", ctl: 5, ack: uuid)) == nil, "a 36-character UUID id")
        #expect(
            MessageContentV2.encode(MessageContent(body: "", mentions: [Mention(nodeId: String(nodeId.dropLast()), name: "x")])) == nil,
            "a 25-character node id"
        )
        #expect(
            MessageContentV2.encode(MessageContent(body: "", mentions: [Mention(nodeId: nodeId.uppercased(), name: "x")])) == nil,
            "uppercase base32"
        )
        // A 22-character base64url id whose last character carries nonzero padding bits: it decodes, but not to bytes
        // that re-encode to it.
        let padded = String(frameId.dropLast()) + "B"
        #expect(FrameId.bytes(of: padded) == nil)
        #expect(MessageContentV2.encode(MessageContent(body: "", ctl: 5, ack: padded)) == nil, "padding-bit base64url")
        #expect(MessageContentV2.encode(MessageContent(body: "", attachmentHash: hash.uppercased())) == nil, "uppercase hex")
        #expect(MessageContentV2.encode(MessageContent(body: "", attachmentHash: "abcd")) == nil, "a short hash")
        #expect(key.hasSuffix("="))
        #expect(MessageContentV2.encode(MessageContent(body: "", attachmentKey: String(key.dropLast()))) == nil, "an unpadded key")
        #expect(
            MessageContentV2.encode(MessageContent(body: "", ctl: 2, gk: GroupKeyPayload(groupId: "g-1"))) == nil,
            "a group-key ctl"
        )
        let offer = CBOR.map([CBOR.Entry(key: .text("id"), value: .text("t1")), CBOR.Entry(key: .text("phase"), value: .unsigned(2))])
        let transfer = MessageContent(body: "", ctl: MessageContent.Control.transfer, xf: offer)
        #expect(MessageContentV2.encode(transfer) == nil, "a direct-transfer ctl")
        #expect(transfer.sealBytes(v3: true).scheme == EncEnvelope.Version.ratchet)
        #expect(MessageContentV2.encode(MessageContent(version: 2, body: "")) == nil, "a foreign content version")
        // And the seam every seal site uses falls back to the named layout instead of losing the frame.
        let fallback = MessageContent(body: "", ctl: 5, ack: uuid).sealBytes(v3: true)
        #expect(fallback.scheme == EncEnvelope.Version.ratchet)
        #expect(try MessageContent(decoding: fallback.plaintext) == MessageContent(body: "", ctl: 5, ack: uuid))
        let tick = MessageContent(body: "", ctl: 5, ack: frameId)
        #expect(tick.sealBytes(v3: true).scheme == EncEnvelope.Version.compactRatchet)
        #expect(tick.sealBytes(v3: true).plaintext == MessageContentV2.encode(tick))
        #expect(tick.sealBytes(v3: false).scheme == EncEnvelope.Version.ratchet)
        #expect(tick.sealBytes(v3: false).plaintext == tick.encoded)
    }

    @Test func malformedBytesDecodeToNull() throws {
        #expect(MessageContentV2.decode([0x7F]) == nil)
        // A wrong-width id inside an otherwise valid map: { 8: h'0102' }.
        #expect(MessageContentV2.decode([0xA1, 0x08, 0x42, 0x01, 0x02]) == nil)
        // A newer compact layout: { 0: 2 }.
        #expect(MessageContentV2.decode([0xA1, 0x00, 0x02]) == nil)
        // An unknown label is ignored, not fatal: { 1: "hi", 99: 1 }.
        let unknownLabel: [UInt8] = [0xA2, 0x01, 0x62, 0x68, 0x69, 0x18, 0x63, 0x01]
        #expect(try #require(MessageContentV2.decode(unknownLabel)).body == "hi")
    }

    @Test func aFileAttachmentRoundTripsItsNameAndSize() throws {
        let file = MessageContent(
            body: "",
            attachmentHash: hash,
            attachmentMime: "application/pdf",
            attachmentKey: key,
            attachmentName: "report.pdf",
            attachmentSize: 1_400_000
        )
        let back = try roundTrip(file)
        #expect(back.attachmentName == "report.pdf")
        #expect(back.attachmentSize == 1_400_000)
        #expect(back.attachmentMime == "application/pdf")
    }

    /// The open-to-chat flag is additive: a profile without it carries no label 5, so an older peer's bytes are unchanged.
    @Test func aProfileWithoutTheOpenToChatFlagCarriesNoLabelFive() throws {
        let off = MessageContent(body: "", ctl: MessageContent.Control.profile, pr: ProfilePayload(name: "A", status: "", version: 5))
        var on = off
        on.pr?.openToChat = true
        let offBytes = try #require(MessageContentV2.encode(off))
        let onBytes = try #require(MessageContentV2.encode(on))
        #expect(offBytes.count + 2 == onBytes.count, "label 5 and `f5`")
        #expect(try roundTrip(off).pr?.openToChat == false)
        #expect(try roundTrip(on).pr?.openToChat == true)
    }

    /// The two file labels are additive: an image's compact bytes must not move because they exist.
    @Test func anImageAttachmentCarriesNeitherLabel() throws {
        let image = MessageContent(body: "", attachmentHash: hash, attachmentMime: "image/jpeg", attachmentKey: key)
        let bytes = try #require(MessageContentV2.encode(image))
        // map(3): hash, type, key. Labels 14 and 15 are absent, so no byte of an image's frame changed.
        #expect(bytes.first == 0xA3)
        let back = try roundTrip(image)
        #expect(back.attachmentName == nil)
        #expect(back.attachmentSize == nil)
    }

    /// Kotlin's `aHostileNameIsRepairedOnDecode`: Kotlin repairs a name at both decoders (`MessageContent.normalized()`,
    /// `MessageContent.kt:95-99`), so `../../etc/passwd` reads as `....etcpasswd`. This port's named decoder has no
    /// `AttachmentName.sanitize` and the delivery path only clips a name's length, so the compact decoder leaves the name
    /// as the named one does: the two decoders always agree.
    @Test func aHostileNameReadsAsTheNamedLayoutReadsIt() throws {
        let hostile = MessageContent(body: "", attachmentHash: hash, attachmentKey: key, attachmentName: "../../etc/passwd")
        #expect(try roundTrip(hostile).attachmentName == (try MessageContent(decoding: hostile.encoded)).attachmentName)
    }
}
