import KnitTestSupport
import KnitWire
import Testing

/// KnitWire reads every field as kotlinx-cbor 1.12.0 reads it under knit-next's configuration (knit-ios #14), one rule
/// at a time, so a frame Android refuses is refused here and one Android reads is read here (`Decoder.kt` in its
/// sources).
@Suite struct KotlinxRulesTests {
    private func entry(_ key: String, _ value: CBOR) -> CBOR.Entry { CBOR.Entry(key: .text(key), value: value) }

    private var receipt: CBOR { .map([entry("ackId", .text("m1"))]) }

    private var reply: CBOR {
        ReplyRef(messageId: "m0", authorId: "a", author: "Ann", snippet: "hi").cbor
    }

    private func call(_ fields: [CBOR.Entry]) -> CBOR {
        .map([
            entry("body", .text("")), entry("ctl", .unsigned(10)),
            entry("cl", .map([entry("id", .text("c1")), entry("ph", .unsigned(1))] + fields)),
        ])
    }

    // MARK: Rule 1, the null mark

    /// `A0` is the null mark under any nullable field (`isNull`, `:193`), a key this build only checks included.
    @Test func theSingleByteA0ReadsAsAbsentUnderEveryNullableField() throws {
        let chat = try ChatContent(
            cbor: .map([
                entry("body", .text("hi")), entry("enc", .map([])), entry("replyTo", .map([])), entry("video", .map([])),
                entry("attachmentName", .map([])),
            ]))
        #expect(chat == ChatContent(body: "hi"))
        let compact = CBOR.map([CBOR.Entry(key: .unsigned(1), value: .text("hi")), CBOR.Entry(key: .unsigned(11), value: .map([]))])
        #expect(MessageContentV2.decode(compact.encoded) == MessageContent(body: "hi"))
        let enc = EncEnvelope(nonce: [1], ct: [2], keys: []).cbor.setting(.key("r"), .map([])).setting(.key("g"), .map([]))
        #expect(try EncEnvelope(cbor: enc) == EncEnvelope(nonce: [1], ct: [2], keys: []))
        let header = RatchetHeader(se: 1, ek: [1], pe: 1, n: 0).cbor.setting(.key("init"), .map([]))
        #expect(try RatchetHeader(cbor: header).initial == nil)
    }

    /// An empty map in a longer form is not the mark, so it goes to the field's decoder: text, a class with a required
    /// field, and a group roster all fail.
    @Test(arguments: [[0xB8, 0x00], [0xBF, 0xFF], [0xB9, 0x00, 0x00], [0xBB, 0, 0, 0, 0, 0, 0, 0, 0]] as [[UInt8]])
    func anEmptyMapInALongerFormIsAValueNotNull(form: [UInt8]) throws {
        for key in ["replyTo", "attachmentHash", "enc"] {
            let bytes = Splice.bytes(.map([entry("body", .text("hi")), entry(key, Splice.sentinel)]), form)
            #expect(throws: WireDecodingError.self, "\(key)") { try ChatContent(decoding: bytes) }
        }
        let envelope = RelayEnvelope(type: .chat, id: "f1", senderId: "s1", sentAt: 1, payload: [0xA0]).cbor
        for key in ["group", "recipientId"] {
            let bytes = Splice.bytes(envelope.setting(.key(key), Splice.sentinel), form)
            #expect(throws: WireDecodingError.self, "\(key)") { try RelayEnvelope(decoding: bytes) }
            let marked = Splice.bytes(envelope.setting(.key(key), Splice.sentinel), [0xA0])
            #expect(try RelayEnvelope(decoding: marked).isRoomPost, "\(key): A0 is absent")
        }
        // A class whose every field is nullable reads it as a value of defaults, as `DirectInvite` does.
        let invite = Splice.bytes(call([entry("dw", Splice.sentinel)]), form)
        #expect(try MessageContent(decoding: invite).ctl == 10)
    }

    /// `"s"` is defaulted, not nullable, so neither `F6` nor `A0` is absent there (`StyleRunsSerializer`).
    @Test func theStylesKeyIsNeverNull() {
        for value in [CBOR.null, .map([])] {
            #expect(throws: WireDecodingError.self) { try ChatContent(cbor: .map([entry("body", .text("x")), entry("s", value)])) }
            #expect(throws: WireDecodingError.self) { try MessageContent(cbor: .map([entry("body", .text("x")), entry("s", value)])) }
        }
    }

    // MARK: Rule 2, a Kotlin Int

    @Test func anIntIsTheWrappedReadingHeldToItsRangeThenTruncated() throws {
        func ctl(_ value: CBOR) throws -> Int? {
            try MessageContent(cbor: .map([entry("body", .text("")), entry("ctl", value)])).ctl
        }
        #expect(try ctl(.unsigned(0xFFFF_FFFF)) == -1, "1A FFFFFFFF")
        #expect(try ctl(.unsigned(.max)) == -1, "1B FF…FF")
        #expect(try ctl(.negative(.max)) == 0, "3B FF…FF")
        #expect(try ctl(.negative(.max - 1)) == 1, "3B FF…FE")
        #expect(try ctl(.unsigned(UInt64(Int32.max) + 1)) == Int(Int32.min))
        #expect(try ctl(.negative(UInt64(Int32.max))) == Int(Int32.min))
        #expect(throws: WireDecodingError.invalidValue(type: "MessageContent", field: "ctl")) { try ctl(.unsigned(1 << 32)) }
        #expect(throws: WireDecodingError.invalidValue(type: "MessageContent", field: "ctl")) { try ctl(.unsigned(1 << 63)) }
        #expect(throws: WireDecodingError.invalidValue(type: "MessageContent", field: "ctl")) {
            try ctl(.negative(UInt64(Int32.max) + 1))
        }
        // `1B 8000000000000000` is `Int64.min` as a `Long`.
        let size = try MessageContent(cbor: .map([entry("body", .text("")), entry("attachmentSize", .unsigned(1 << 63))]))
        #expect(size.attachmentSize == .min)
        // A video's `width`, which this build only checks.
        let video = try CBOR.decode(GoldenVectors.bytes("chatContentVideo"))
        for width in [CBOR.unsigned(0xFFFF_FFFF), .unsigned(.max)] {
            _ = try ChatContent(cbor: video.editing(.key("video")) { $0.setting(.key("width"), width) })
        }
        #expect(throws: WireDecodingError.invalidValue(type: "VideoInfo", field: "width")) {
            try ChatContent(cbor: video.editing(.key("video")) { $0.setting(.key("width"), .unsigned(1 << 32)) })
        }
    }

    // MARK: Rule 3, a Kotlin Long

    @Test func aLongPastItsRangeWraps() throws {
        let envelope = RelayEnvelope(type: .chat, id: "f1", senderId: "s1", payload: [0xA0]).cbor
        #expect(try RelayEnvelope(cbor: envelope.setting(.key("sentAt"), .unsigned(UInt64(Int64.max) + 1))).sentAt == .min)
        #expect(try RelayEnvelope(cbor: envelope.setting(.key("sentAt"), .negative(.max))).sentAt == 0)
        let video = try CBOR.decode(GoldenVectors.bytes("chatContentVideo"))
        _ = try ChatContent(cbor: video.editing(.key("video")) { $0.setting(.key("durationMs"), .unsigned(.max)) })
    }

    // MARK: Rule 4, tags

    @Test func tagsAreSkippedBeforeAValueAKeyAndTheMap() throws {
        let tagged = CBOR.tagged(55_799, .map([CBOR.Entry(key: .tagged(1, .text("ackId")), value: .tagged(32, .text("m1")))]))
        #expect(try ReceiptContent(cbor: tagged) == ReceiptContent(ackId: "m1"))
        #expect(try ReceiptContent(decoding: tagged.encoded) == ReceiptContent(ackId: "m1"))
        let compact = CBOR.tagged(
            1,
            .map([
                CBOR.Entry(key: .tagged(2, .unsigned(1)), value: .tagged(3, .text("hi"))),
                CBOR.Entry(key: .unsigned(7), value: .tagged(4, .unsigned(5))),
            ]))
        #expect(MessageContentV2.decode(compact.encoded) == MessageContent(body: "hi", ctl: 5))
        // A run of tags, as `processTags` loops (`:307-318`): `C0 C1 01` reads as 1.
        let run = try MessageContent(cbor: .map([entry("body", .text("")), entry("ctl", .tagged(0, .tagged(1, .unsigned(1))))]))
        #expect(run.ctl == 1)
        // List elements, each read under its own tags.
        let acks = try MessageContent(cbor: .map([entry("body", .text("")), entry("acks", .array([.tagged(1, .text("a")), .text("b")]))]))
        #expect(acks.acks == ["a", "b"])
        let mentions = try ChatContent(
            cbor: .map([entry("mentions", .tagged(4, .array([.tagged(5, Mention(nodeId: "n", name: "N").cbor)])))]))
        #expect(mentions.mentions == [Mention(nodeId: "n", name: "N")])
    }

    /// The null mark is the first byte, so a tagged `F6` or `A0` is a value: it fails text and a class with a required
    /// field, and reads as defaults for a class with none.
    @Test func aTaggedNullIsAValue() throws {
        for value in [CBOR.tagged(0, .null), .tagged(0, .tagged(1, .null))] {
            #expect(throws: WireDecodingError.invalidValue(type: "ChatContent", field: "attachmentHash")) {
                try ChatContent(cbor: .map([entry("attachmentHash", value)]))
            }
        }
        #expect(throws: WireDecodingError.missingField(type: "ReplyRef", field: "messageId")) {
            try ChatContent(cbor: .map([entry("replyTo", .tagged(0, .map([])))]))
        }
        #expect(try MessageContent(cbor: call([entry("dw", .tagged(0, .map([])))])).ctl == 10)
    }

    /// A checked field keeps its item exactly as it came, tags and all.
    @Test func aCheckedFieldKeepsItsTags() throws {
        let transfer = CBOR.tagged(9, .map([entry("id", .text("t1")), entry("phase", .unsigned(1))]))
        let content = try MessageContent(cbor: .map([entry("body", .text("")), entry("xf", transfer)]))
        #expect(content.xf == transfer)
    }

    // MARK: Depth, as Android's `CborText` counts it

    /// Android walks the signed envelope with `CborText` first, which refuses an item deeper than 32 levels and counts
    /// each tag as one (`CborText.kt:21,36,63`). `CBOR.decode` counts the same way.
    @Test func depthMatchesCborTextOnTheSignedEnvelope() throws {
        func envelope(leafDepth: Int) -> [UInt8] {
            // The envelope's own map is level 0 and its value level 1; tags and arrays alternate down to the leaf.
            let wrappers = leafDepth - 1
            let chain = (0..<wrappers).map { $0.isMultiple(of: 2) ? UInt8(0xC1) : UInt8(0x81) } + [0x00]
            let item = RelayEnvelope(type: .chat, id: "f1", senderId: "s1", sentAt: 1, payload: [0xA0]).cbor
            return Splice.bytes(item.setting(.key("future"), Splice.sentinel), chain)
        }
        #expect(try RelayEnvelope(decoding: envelope(leafDepth: 32)).id == "f1")
        #expect(throws: WireDecodingError.cbor(.nestingTooDeep)) { try RelayEnvelope(decoding: envelope(leafDepth: 33)) }
    }

    /// A run of tags under a field: the value is level 1, so 31 tags put the leaf at 32 and are read, as `CborText`
    /// reads them before `decodeChecked`, and 32 are refused on both.
    @Test func depthCountsEveryTagInARun() throws {
        func chat(tags: Int) -> [UInt8] {
            CBOR.map([entry("body", .underTags(.text("hi"), count: tags))]).encoded
        }
        #expect(try ChatContent(decoding: chat(tags: 31)).body == "hi")
        #expect(throws: WireDecodingError.cbor(.nestingTooDeep)) { try ChatContent(decoding: chat(tags: 32)) }
    }

    // MARK: Rule 5, integer keys

    @Test func anIntegerKeyInANamedMapIsSkippedAndOtherKindsFail() throws {
        let skipped = receipt.adding(.unsigned(1), .text("x")).adding(.negative(4), .bytes([1])).adding(.tagged(2, .unsigned(9)), .null)
        #expect(try ReceiptContent(cbor: skipped) == ReceiptContent(ackId: "m1"))
        for key in [CBOR.bytes([1]), .array([]), .map([]), .bool(true), .null, .float(1), .simple(16), .tagged(1, .bytes([]))] {
            #expect(throws: WireDecodingError.nonTextKey(type: "ReceiptContent"), "\(key)") {
                try ReceiptContent(cbor: receipt.adding(key, .text("x")))
            }
        }
    }

    /// Keys compare by their bytes, as kotlinx's name lookup compares Kotlin strings: a Kelvin sign is not a `K`.
    @Test func aKeySwiftCallsEqualIsAnUnknownKey() throws {
        let content = try MessageContent(cbor: .map([entry("body", .text("")), entry("attachment\u{212A}ey", .text("k"))]))
        #expect(content.attachmentKey == nil)
    }

    // MARK: Rule 6, duplicated keys

    @Test func everyOccurrenceOfADuplicatedKeyIsDecoded() throws {
        #expect(try ReceiptContent(cbor: receipt.adding(.key("ackId"), .text("last"))).ackId == "last")
        // The first copy's wrong type fails, though the last copy is good.
        #expect(throws: WireDecodingError.invalidValue(type: "ReceiptContent", field: "ackId")) {
            try ReceiptContent(cbor: receipt.adding(.key("ackId"), .unsigned(1), first: true))
        }
        #expect(throws: WireDecodingError.unexpectedNull(type: "ReceiptContent", field: "ackId")) {
            try ReceiptContent(cbor: receipt.adding(.key("ackId"), .null, first: true))
        }
        // A nullable field takes its last copy, null included.
        let cleared = try ChatContent(cbor: .map([entry("attachmentHash", .text("h")), entry("attachmentHash", .null)]))
        #expect(cleared.attachmentHash == nil)
        #expect(throws: WireDecodingError.self) {
            try ChatContent(cbor: .map([entry("attachmentHash", .unsigned(1)), entry("attachmentHash", .text("h"))]))
        }
        // A copy under a text key and one under its label are one field in the compact layout.
        #expect(throws: WireDecodingError.self) {
            try ChatContent(cbor: .map([entry("video", .text("x")), entry("video", .map([]))]))
        }
        let compact = CBOR.map([CBOR.Entry(key: .key("ctl"), value: .text("x")), CBOR.Entry(key: .unsigned(7), value: .unsigned(5))])
        #expect(MessageContentV2.decode(compact.encoded) == nil)
    }

    /// A required field counts as present when any copy of its key holds it, and a duplicated class is decoded afresh
    /// each time, never merged into the copy before it: kotlinx-serialization-core's `decodeSerializableValue` ignores
    /// the previous value, so the last copy must be whole on its own.
    @Test func aDuplicatedClassIsDecodedAfreshNeverMerged() throws {
        #expect(
            try MessageContent(cbor: .map([entry("body", .text("a")), entry("ctl", .unsigned(1)), entry("body", .text("b"))])).body == "b")
        let partial = CBOR.map([entry("messageId", .text("m0"))])
        #expect(throws: WireDecodingError.missingField(type: "ReplyRef", field: "authorId")) {
            try ChatContent(cbor: .map([entry("replyTo", reply), entry("replyTo", partial)]))
        }
        #expect(throws: WireDecodingError.missingField(type: "ReplyRef", field: "authorId")) {
            try ChatContent(cbor: .map([entry("replyTo", partial), entry("replyTo", reply)]))
        }
        let whole = try ChatContent(
            cbor: .map([entry("replyTo", reply), entry("replyTo", reply.setting(.key("snippet"), .text("again")))]))
        #expect(whole.replyTo?.snippet == "again")
    }

    // MARK: The envelope

    @Test func aNegativeTtlOrHopsRefusesTheFrame() throws {
        let base = WireEnvelope(sig: [], signed: [0xA0]).cbor
        for key in ["ttl", "hops"] {
            for value in [CBOR(Int64(-1)), .unsigned(0xFFFF_FFFF), .unsigned(.max), .negative(UInt64(Int32.max))] {
                #expect(throws: WireDecodingError.invalidValue(type: "WireEnvelope", field: key), "\(key) \(value)") {
                    try WireEnvelope(decoding: base.setting(.key(key), value).encoded)
                }
            }
        }
        // `3B FF…FF` reads as 0, which is no negative.
        #expect(try WireEnvelope(cbor: base.setting(.key("ttl"), .negative(.max))).ttl == 0)
        #expect(try WireEnvelope(cbor: base.setting(.key("hops"), .negative(.max)).setting(.key("ttl"), .unsigned(3))).hops == 0)
    }
}
