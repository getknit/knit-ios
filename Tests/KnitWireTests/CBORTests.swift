import KnitWire
import Testing

/// The codec against RFC 8949 Appendix A, and against the hostile inputs a radio can deliver.
@Suite struct CBORTests {
    /// Appendix A items whose encoding is already the shortest form, so they must decode and re-encode
    /// byte for byte.
    @Test(
        arguments: [
            ("00", CBOR.unsigned(0)),
            ("17", .unsigned(23)),
            ("1818", .unsigned(24)),
            ("1903e8", .unsigned(1000)),
            ("1a000f4240", .unsigned(1_000_000)),
            ("1b000000e8d4a51000", .unsigned(1_000_000_000_000)),
            ("1bffffffffffffffff", .unsigned(.max)),
            ("20", .negative(0)),
            ("3863", .negative(99)),
            ("3bffffffffffffffff", .negative(.max)),
            ("40", .bytes([])),
            ("4401020304", .bytes([1, 2, 3, 4])),
            ("60", .text("")),
            ("6161", .text("a")),
            ("6449455446", .text("IETF")),
            ("62c3bc", .text("ü")),
            ("64f0908591", .text("𐅑")),
            ("80", .array([])),
            ("83010203", .array([.unsigned(1), .unsigned(2), .unsigned(3)])),
            ("a0", .map([])),
            (
                "a26161016162820203",
                .map([
                    CBOR.Entry(key: .text("a"), value: .unsigned(1)),
                    CBOR.Entry(key: .text("b"), value: .array([.unsigned(2), .unsigned(3)])),
                ])
            ),
            ("f4", .bool(false)),
            ("f5", .bool(true)),
            ("f6", .null),
            ("f7", .undefined),
            ("f0", .simple(16)),
            ("f8ff", .simple(255)),
            ("c11a514b67b0", .tagged(1, .unsigned(1_363_896_240))),
        ] as [(String, CBOR)])
    func appendixItemsRoundTrip(hex: String, item: CBOR) throws {
        let bytes = try #require(Hex.decode(hex))
        #expect(try CBOR.decode(bytes) == item)
        #expect(item.encoded == bytes)
    }

    @Test func integersConvertThroughInt64() {
        #expect(CBOR(Int64(-1)) == .negative(0))
        #expect(CBOR(Int64(-100)) == .negative(99))
        #expect(CBOR(Int64.min).int64 == .min)
        #expect(CBOR.unsigned(UInt64(Int64.max) + 1).int64 == nil)
        #expect(CBOR.text("1").int64 == nil)
    }

    @Test func nonShortestIntegersStillDecode() throws {
        // A conforming encoder may write 1 as 0x1b00…01; a receiver must read it.
        #expect(try CBOR.decode([0x1B, 0, 0, 0, 0, 0, 0, 0, 1]) == .unsigned(1))
        #expect(try CBOR.decode([0x18, 0x05]) == .unsigned(5))
    }

    @Test func indefiniteLengthItemsDecodeToTheirDefiniteForm() throws {
        let array = try #require(Hex.decode("9f018202039f0405ffff"))
        #expect(
            try CBOR.decode(array) == .array([.unsigned(1), .array([.unsigned(2), .unsigned(3)]), .array([.unsigned(4), .unsigned(5)])])
        )
        let map = try #require(Hex.decode("bf61610161629f0203ffff"))
        #expect(
            try CBOR.decode(map)
                == .map([
                    CBOR.Entry(key: .text("a"), value: .unsigned(1)),
                    CBOR.Entry(key: .text("b"), value: .array([.unsigned(2), .unsigned(3)])),
                ])
        )
        let text = try #require(Hex.decode("7f657374726561646d696e67ff"))
        #expect(try CBOR.decode(text) == .text("streaming"))
        let bytes = try #require(Hex.decode("5f42010243030405ff"))
        #expect(try CBOR.decode(bytes) == .bytes([1, 2, 3, 4, 5]))
    }

    @Test func floatsWidenToDouble() throws {
        #expect(try CBOR.decode([0xF9, 0x3C, 0x00]) == .float(1.0))
        #expect(try CBOR.decode([0xF9, 0x00, 0x01]) == .float(0x1p-24))
        #expect(try CBOR.decode([0xF9, 0x7C, 0x00]) == .float(.infinity))
        #expect(try CBOR.decode([0xFA, 0x47, 0xC3, 0x50, 0x00]) == .float(100_000.0))
        #expect(try CBOR.decode([0xFB, 0x3F, 0xF1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9A]) == .float(1.1))
        guard case .float(let nan) = try CBOR.decode([0xF9, 0x7E, 0x00]) else {
            Issue.record("a half-precision NaN did not decode as a float")
            return
        }
        #expect(nan.isNaN)
    }

    @Test(
        arguments: [
            ([], CBORError.truncated),
            ([0x18], .truncated),
            ([0x19, 0x01], .truncated),
            ([0x62, 0x61], .lengthExceedsInput),
            ([0x82, 0x01], .lengthExceedsInput),
            ([0x9F, 0x01], .truncated),
            ([0x00, 0x00], .trailingBytes),
            ([0x1C], .malformedHeader(0x1C)),
            ([0x1F], .malformedHeader(0x1F)),
            ([0xFC], .malformedHeader(0xFC)),
            ([0xF8, 0x10], .malformedHeader(0xF8)),
            ([0xFF], .unexpectedBreak),
            ([0x81, 0xFF], .unexpectedBreak),
            ([0x62, 0xC3, 0x28], .invalidUTF8),
            ([0x5F, 0x61, 0x61, 0xFF], .invalidChunk),
            ([0x5F, 0x5F, 0xFF, 0xFF], .invalidChunk),
            ([0x5B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], .lengthExceedsInput),
            ([0x9B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], .lengthExceedsInput),
            ([0xBA, 0x00, 0x01, 0x00, 0x00, 0x00], .lengthExceedsInput),
        ] as [([UInt8], CBORError)])
    func malformedInputIsAnErrorNotACrash(bytes: [UInt8], expected: CBORError) {
        #expect(throws: expected) {
            try CBOR.decode(bytes)
        }
    }

    @Test func nestingPastTheLimitIsRefused() throws {
        let deep = [UInt8](repeating: 0x81, count: 40) + [0x00]
        #expect(throws: CBORError.nestingTooDeep) {
            try CBOR.decode(deep)
        }
        let allowed = [UInt8](repeating: 0x81, count: 32) + [0x00]
        #expect(throws: Never.self) {
            try CBOR.decode(allowed)
        }
    }

    @Test func typedDecodingMirrorsKotlinxRules() throws {
        // A map key that is not text.
        #expect(throws: WireDecodingError.nonTextKey(type: "ReceiptContent")) {
            try ReceiptContent(cbor: .map([CBOR.Entry(key: .unsigned(1), value: .text("m1"))]))
        }
        // A missing field that has no default.
        #expect(throws: WireDecodingError.missingField(type: "ReceiptContent", field: "ackId")) {
            try ReceiptContent(cbor: .map([]))
        }
        // `null` for a field that is not nullable, even one with a default.
        #expect(throws: WireDecodingError.unexpectedNull(type: "WireEnvelope", field: "ttl")) {
            try WireEnvelope(
                cbor: .map([
                    CBOR.Entry(key: .text("ttl"), value: .null),
                    CBOR.Entry(key: .text("sig"), value: .bytes([])),
                    CBOR.Entry(key: .text("signed"), value: .bytes([])),
                ])
            )
        }
        // A Kotlin Int outside 32 bits.
        #expect(throws: WireDecodingError.invalidValue(type: "WireEnvelope", field: "hops")) {
            try WireEnvelope(
                cbor: .map([
                    CBOR.Entry(key: .text("hops"), value: .unsigned(UInt64(Int32.max) + 1)),
                    CBOR.Entry(key: .text("sig"), value: .bytes([])),
                    CBOR.Entry(key: .text("signed"), value: .bytes([])),
                ])
            )
        }
        // Not a map at all.
        #expect(throws: WireDecodingError.notAMap(type: "Mention")) {
            try Mention(cbor: .array([]))
        }
        // Bytes that are not CBOR: a two-entry map with nothing after it.
        #expect(throws: WireDecodingError.cbor(.lengthExceedsInput)) {
            try Mention(decoding: [0xA2])
        }
    }

    @Test func unknownKeysAreIgnoredAndTheLastDuplicateWins() throws {
        let receipt = try ReceiptContent(
            cbor: .map([
                CBOR.Entry(key: .text("ackId"), value: .text("first")),
                CBOR.Entry(key: .text("future"), value: .array([.unsigned(1)])),
                CBOR.Entry(key: .text("ackId"), value: .text("last")),
            ])
        )
        #expect(receipt.ackId == "last")
    }

    @Test func nullableFieldsReadNullAsAbsent() throws {
        let chat = try ChatContent(
            cbor: .map([
                CBOR.Entry(key: .text("attachmentHash"), value: .null),
                CBOR.Entry(key: .text("enc"), value: .null),
            ])
        )
        #expect(chat == ChatContent())
    }

    @Test func aTypingCueWithNoGroupIsTheEmptyMapAndroidReads() throws {
        // A room or DM cue, `{}`: what knit-next's `IosPayloadShapesTest` pins for this port, with no vector to hold it.
        #expect(TypingContent().encoded == [0xA0])
        #expect(try TypingContent(decoding: [0xA0]) == TypingContent())
    }
}
