import KnitTestSupport
import KnitWire
import Testing

/// The v3 compact plaintext against the nine `messageContentV2*` fixtures this build models, and what its decoder does with keys,
/// labels, widths and kinds no encoder writes, as kotlinx's `compactCbor` reads them (`Crypto.kt:111-119`;
/// kotlinx-serialization-cbor 1.11.0's `CborReader`). Kotlin's own cases are ``MessageContentV2Tests``'.
@Suite struct CompactPlaintextTests {
    private let frameId = fixtureFrameId(1)
    private let nodeId = fixtureNodeId(3).string

    private func roundTrip(_ content: MessageContent) throws -> MessageContent {
        let bytes = try #require(MessageContentV2.encode(content), "must have a compact form")
        return try #require(MessageContentV2.decode(bytes), "must decode")
    }

    private func decode(_ entries: [(CBOR, CBOR)]) -> MessageContent? {
        MessageContentV2.decode(CBOR.map(entries.map { CBOR.Entry(key: $0.0, value: $0.1) }).encoded)
    }

    // MARK: The nine fixtures

    /// Every compact fixture but the two for fields this build does not model, a profile's supporter badges and a short
    /// video, which ``GoldenVectorTests`` decodes.
    @Test func everyCompactFixtureIsHere() {
        let unmodeled: Set = ["messageContentV2ProfileBadges", "messageContentV2Video"]
        let compact = Set(GoldenVectors.names.filter { $0.hasPrefix("messageContentV2") })
        #expect(Set(compactFixtures.keys) == compact.subtracting(unmodeled))
        #expect(compactFixtures.count == 9)
    }

    /// Each fixture encodes to knit-next's bytes, decodes back, and decodes to what its named layout decodes to.
    @Test(arguments: compactFixtures.keys.sorted())
    func eachCompactFixtureMatchesKnitNextBothWays(name: String) throws {
        let content = try #require(compactFixtures[name])
        let pinned = GoldenVectors.bytes(name)
        #expect(MessageContentV2.encode(content) == pinned, "\(name) encoded differently from knit-next")
        #expect(MessageContentV2.decode(pinned) == content, "\(name) did not decode back")
        let named = try MessageContent(decoding: content.encoded)
        #expect(MessageContentV2.decode(pinned) == named, "\(name) read apart from its named form")
        #expect(content.sealBytes(v3: true).plaintext == pinned)
    }

    // MARK: What kotlinx's decoder does with what no encoder writes

    /// kotlinx reads a text key as the property it names (`decodeElementNameWithTagsLenient`), by its exact characters.
    @Test func aTextKeyReadsAsThePropertyItNames() throws {
        let content = try #require(decode([(.text("body"), .text("hi")), (.text("ctl"), .unsigned(5))]))
        #expect(content.body == "hi")
        #expect(content.ctl == 5)
        // The Kelvin sign is `K` to Swift's `==`, and another name to Kotlin: skipped, not read as `attachmentKey`.
        let kelvin = try #require(decode([(.text("attachment\u{212A}ey"), .bytes([1])), (.unsigned(1), .text("x"))]))
        #expect(kelvin.attachmentKey == nil)
        #expect(try #require(decode([(.text("bodies"), .text("x"))])).body.isEmpty)
        // The last of two spellings of one field wins, as kotlinx assigns them in order.
        #expect(try #require(decode([(.unsigned(1), .text("a")), (.text("body"), .text("b"))])).body == "b")
    }

    /// Unknown labels are skipped, the reserved 12 (`pad`) and 13 (`gk`) and any label past a field's included
    /// (`MessageContentV2.kt:157-163`).
    @Test func theReservedLabelsAndUnknownOnesAreSkipped() throws {
        let content = try #require(
            decode([
                (.unsigned(1), .text("hi")),
                (.unsigned(12), .bytes([0, 0, 0])),
                (.unsigned(13), .map([CBOR.Entry(key: .unsigned(1), value: .bytes([1]))])),
                (.unsigned(UInt64.max), .null),
            ])
        )
        #expect(content == MessageContent(body: "hi"))
    }

    /// A key that is neither text nor an unsigned label is refused; kotlinx would read it as a label taken from its
    /// header, which nothing writes.
    @Test(arguments: [CBOR.negative(0), CBOR.bytes([1]), CBOR.bool(true)])
    func aKeyThatIsNeitherTextNorALabelIsRefused(key: CBOR) {
        #expect(decode([(key, .unsigned(1)), (.unsigned(1), .text("hi"))]) == nil)
    }

    /// Label 0 is the layout's version: up to ``MessageContentV2/maxSupportedVersion`` reads, as kotlinx's
    /// `w.v > MAX_SUPPORTED` lets it, and the content's own version is always 1.
    @Test func aVersionUpToTheSupportedOneReads() throws {
        #expect(try #require(decode([(.unsigned(0), .unsigned(1)), (.unsigned(1), .text("x"))])) == MessageContent(body: "x"))
        #expect(try #require(decode([(.unsigned(0), .unsigned(0))])).version == MessageContent.currentVersion)
        #expect(decode([(.unsigned(0), .null)]) == nil, "a version is never null")
    }

    /// Every id, hash and node id must be exactly its width (`FrameId.fromBytes`, `NodeId.BYTES`, `hashText`); a key
    /// may be any length, as Kotlin's `b64` takes one.
    @Test func anIdHashOrNodeIdOfTheWrongWidthDecodesToNothing() throws {
        let short = CBOR.bytes([UInt8](repeating: 1, count: 15))
        let mention = CBOR.map([CBOR.Entry(key: .unsigned(1), value: short), CBOR.Entry(key: .unsigned(2), value: .text("x"))])
        #expect(decode([(.unsigned(2), .array([mention]))]) == nil, "a mention's node id")
        #expect(decode([(.unsigned(3), .bytes([UInt8](repeating: 1, count: 31)))]) == nil, "an attachment's hash")
        #expect(decode([(.unsigned(6), reply(messageId: short))]) == nil, "a quote's frame id")
        #expect(decode([(.unsigned(6), reply(authorId: short))]) == nil, "a quote's author")
        #expect(decode([(.unsigned(9), .array([.bytes(fixtureBytes(16, seed: 1)), short]))]) == nil, "one of a batch's ids")
        #expect(decode([(.unsigned(10), .map([CBOR.Entry(key: .unsigned(1), value: short)]))]) == nil, "a reaction's frame id")
        let avatar = CBOR.bytes([UInt8](repeating: 1, count: 33))
        #expect(decode([(.unsigned(11), profile([(3, avatar)]))]) == nil, "a profile's avatar hash")

        let anyKey = try #require(decode([(.unsigned(5), .bytes([1, 2, 3]))]))
        #expect(anyKey.attachmentKey == Base64.encode([1, 2, 3]))
        let boardKey = try #require(decode([(.unsigned(11), profile([(7, .bytes([4]))]))]))
        #expect(boardKey.pr?.loraKey == Base64.encode([4]))
    }

    /// The kotlinx rules every typed field follows, in the labelled layout too.
    @Test func wrongKindsAndNullsDecodeToNothing() throws {
        #expect(MessageContentV2.decode(CBOR.array([]).encoded) == nil, "not a map")
        #expect(decode([(.unsigned(1), .null)]) == nil, "a body is never null")
        #expect(decode([(.unsigned(2), .null)]) == nil, "nor are mentions")
        #expect(decode([(.unsigned(2), .bytes([1]))]) == nil, "which are a list")
        #expect(decode([(.unsigned(7), .text("5"))]) == nil, "a control code is an Int")
        #expect(decode([(.unsigned(9), .bytes([1]))]) == nil, "a batch is a list")
        #expect(decode([(.unsigned(9), .array([.text("m1")]))]) == nil, "of byte strings")
        #expect(decode([(.unsigned(6), .array([]))]) == nil, "a quote is a map")
        let nameless = CBOR.map([CBOR.Entry(key: .unsigned(1), value: .bytes(fixtureBytes(16, seed: 3)))])
        #expect(decode([(.unsigned(2), .array([nameless]))]) == nil, "a mention's name has no default")
        // A nullable field reads `null` as absent.
        let nulls = try #require(decode([(.unsigned(3), .null), (.unsigned(7), .null), (.unsigned(9), .null), (.unsigned(11), .null)]))
        #expect(nulls == MessageContent(body: ""))
    }

    /// Defaults stay off the wire in the nested layouts too, and a value off its default goes on.
    @Test func aProfilesDefaultsStayOffTheWire() throws {
        let content = MessageContent(body: "", ctl: MessageContent.Control.profile, pr: ProfilePayload(name: "A", status: "b"))
        let bytes = try #require(MessageContentV2.encode(content))
        // { 7: 8, 11: { 1: "A", 2: "b" } }
        #expect(bytes == [0xA2, 0x07, 0x08, 0x0B, 0xA2, 0x01, 0x61, 0x41, 0x02, 0x61, 0x62])
        var negative = content
        negative.pr?.version = -1
        #expect(try roundTrip(negative) == negative)
        let quote = MessageContent(body: "", replyTo: ReplyRef(messageId: frameId, authorId: nodeId, author: "A", snippet: "s"))
        #expect(try roundTrip(quote) == quote)
        // { 6: { 1: h'<id>', 2: h'<node>', 3: "A", 4: "s" } }: no `hasAttachment` while it is false.
        let expected: [UInt8] =
            [0xA1, 0x06, 0xA4, 0x01, 0x50] + fixtureBytes(16, seed: 1) + [0x02, 0x50] + fixtureBytes(16, seed: 3)
            + [0x03, 0x61, 0x41, 0x04, 0x61, 0x73]
        #expect(MessageContentV2.encode(quote) == expected)
    }

    /// Every field that carries raw bytes refuses text that does not round-trip, wherever it sits.
    @Test func everyRawFieldRefusesWhatDoesNotRoundTrip() {
        let bad = "not-canonical"
        let samples = [
            MessageContent(body: "", replyTo: ReplyRef(messageId: bad, authorId: nodeId, author: "A", snippet: "s")),
            MessageContent(body: "", replyTo: ReplyRef(messageId: frameId, authorId: bad, author: "A", snippet: "s")),
            MessageContent(body: "", ctl: 6, rp: ReactionContent(messageId: bad, emoji: "x")),
            MessageContent(body: "", ctl: 5, acks: [frameId, bad]),
            MessageContent(body: "", ctl: 8, pr: ProfilePayload(name: "A", status: "", avatarHash: bad)),
            MessageContent(body: "", ctl: 8, pr: ProfilePayload(name: "A", status: "", loraKey: "QQ")),
            MessageContent(body: "", attachmentKey: "!!!!"),
        ]
        for content in samples {
            #expect(MessageContentV2.encode(content) == nil)
            #expect(content.sealBytes(v3: true).scheme == EncEnvelope.Version.ratchet)
        }
    }

    private func reply(messageId: CBOR = .bytes(fixtureBytes(16, seed: 6)), authorId: CBOR = .bytes(fixtureBytes(16, seed: 3))) -> CBOR {
        .map([
            CBOR.Entry(key: .unsigned(1), value: messageId),
            CBOR.Entry(key: .unsigned(2), value: authorId),
            CBOR.Entry(key: .unsigned(3), value: .text("A")),
            CBOR.Entry(key: .unsigned(4), value: .text("s")),
        ])
    }

    private func profile(_ extra: [(UInt64, CBOR)]) -> CBOR {
        .map(
            [CBOR.Entry(key: .unsigned(1), value: .text("A")), CBOR.Entry(key: .unsigned(2), value: .text(""))]
                + extra.map { CBOR.Entry(key: .unsigned($0.0), value: $0.1) }
        )
    }
}

/// Ann, the compact fixtures' one person: the node id of `bytes(16, 3)`.
private let ann = fixtureNodeId(3).string

/// The sealed profile update every compact profile fixture carries, `GoldenVectorTest`'s.
private func fixtureProfile(openToChat: Bool = false, loraNode: Int64? = nil, loraKey: String? = nil) -> ProfilePayload {
    ProfilePayload(
        name: "Ann",
        status: "hiking",
        avatarHash: Hex.encode(fixtureBytes(32, seed: 7)),
        version: 1700,
        openToChat: openToChat,
        loraNode: loraNode,
        loraKey: loraKey
    )
}

/// `GoldenVectorTest`'s compact fixtures, rebuilt; `GoldenVectorTests` checks the generic codec on the same bytes.
private let compactFixtures: [String: MessageContent] = [
    "messageContentV2Plain": MessageContent(body: "hi there"),
    "messageContentV2Receipt": MessageContent(body: "", ctl: MessageContent.Control.receipt, ack: fixtureFrameId(1)),
    "messageContentV2ReceiptBatch": MessageContent(
        body: "", ctl: MessageContent.Control.receipt, acks: [fixtureFrameId(1), fixtureFrameId(2)]),
    "messageContentV2Reaction": MessageContent(
        body: "", ctl: MessageContent.Control.reaction, rp: ReactionContent(messageId: fixtureFrameId(1), emoji: "👍")),
    "messageContentV2Full": MessageContent(
        body: "hi there",
        mentions: [Mention(nodeId: ann, name: "Ann")],
        attachmentHash: Hex.encode(fixtureBytes(32, seed: 4)),
        attachmentMime: "image/webp",
        attachmentKey: Base64.encode(fixtureBytes(32, seed: 5)),
        replyTo: ReplyRef(messageId: fixtureFrameId(6), authorId: ann, author: "Ann", snippet: "see you", hasAttachment: true),
        pr: fixtureProfile()
    ),
    "messageContentV2ProfileOpenToChat": MessageContent(
        body: "", ctl: MessageContent.Control.profile, pr: fixtureProfile(openToChat: true)),
    "messageContentV2ProfileLoraNode": MessageContent(
        body: "", ctl: MessageContent.Control.profile, pr: fixtureProfile(loraNode: 0xDEAD_BEEF)),
    "messageContentV2ProfileLoraKey": MessageContent(
        body: "",
        ctl: MessageContent.Control.profile,
        pr: fixtureProfile(loraNode: 0xDEAD_BEEF, loraKey: "oR62IJmFUE0Tgcw0GcypU5ZqUFCQllVBy2snB/BKQA4=")
    ),
    "messageContentV2File": MessageContent(
        body: "",
        attachmentHash: Hex.encode(fixtureBytes(32, seed: 4)),
        attachmentMime: "application/pdf",
        attachmentKey: Base64.encode(fixtureBytes(32, seed: 5)),
        attachmentName: "report.pdf",
        attachmentSize: 1_400_000
    ),
]
