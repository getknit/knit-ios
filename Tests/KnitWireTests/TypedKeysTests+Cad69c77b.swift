import KnitTestSupport
import KnitWire
import Testing

/// The keys Android typed after knit-ios #14, at knit-next `cad69c77b` (knit-ios #42, #43): a chat's declared languages
/// (`Int?` under `"l"` and `"r"`, labels 18 and 19 compact; `Wire.kt:268-271`, `MessageContent.kt:126-129`,
/// `MessageContentV2.kt:232-235`), a transfer's `md` (`List<Long>?`, `Wire.kt:949`) and ctl 11's `pk`
/// (`PresenceKeyPayload`, `Wire.kt:828-848`), each read through kotlinx 1.12.0's `decodeInt`, `decodeLong` and `isNull`.
extension TypedKeysTests {
    /// What `decodeInt` reads: `1A FFFFFFFF` truncates to −1, a negative value reads, and 2³² and `1B 8000000000000000` are
    /// past what it admits.
    private static let readableInts: [CBOR] = [.unsigned(0xFFFF_FFFF), .negative(4), .unsigned(0), .null, .map([])]
    private static let refusedInts: [CBOR] = [.unsigned(1 << 32), .unsigned(1 << 63), .text("es"), .bytes([1]), .bool(true)]

    // MARK: The declared languages

    @Test func theHonestLanguageVectorsDecode() throws {
        #expect(try ChatContent(decoding: GoldenVectors.bytes("chatContentLang")) == ChatContent(body: "hola"))
        #expect(try MessageContent(decoding: GoldenVectors.bytes("messageContentLang")) == MessageContent(body: "hola"))
        #expect(MessageContentV2.decode(GoldenVectors.bytes("messageContentV2Lang")) == MessageContent(body: "hola"))
    }

    @Test(arguments: ["l", "r"])
    func aRoomPostsLanguagesAreKotlinInts(key: String) throws {
        let post = try vector("chatContentLang")
        for value in Self.readableInts {
            #expect(try ChatContent(cbor: post.setting(.key(key), value)).body == "hola", "\(key): \(value)")
        }
        for value in Self.refusedInts {
            #expect(throws: WireDecodingError.self, "\(key): \(value)") { try ChatContent(cbor: post.setting(.key(key), value)) }
        }
        // The property name is no key in the named layout, so a text value under it is skipped.
        #expect(try ChatContent(cbor: post.setting(.key(key == "l" ? "lang" : "reads"), .text("es"))).body == "hola")
    }

    @Test(arguments: ["l", "r"])
    func aSealedMessagesLanguagesAreKotlinInts(key: String) throws {
        let message = try vector("messageContentLang")
        for value in Self.readableInts {
            #expect(try MessageContent(cbor: message.setting(.key(key), value)).body == "hola", "\(key): \(value)")
        }
        for value in Self.refusedInts {
            #expect(throws: WireDecodingError.self, "\(key): \(value)") { try MessageContent(cbor: message.setting(.key(key), value)) }
        }
    }

    /// Labels 18 and 19, and the property names kotlinx also reads as their keys in the compact layout.
    @Test func theCompactLanguagesAreKotlinInts() throws {
        let message = try vector("messageContentV2Lang")
        for key in [CBOR.unsigned(18), .unsigned(19), .key("lang"), .key("reads")] {
            for value in Self.readableInts {
                #expect(MessageContentV2.decode(message.setting(key, value).encoded) == MessageContent(body: "hola"), "\(key): \(value)")
            }
            for value in Self.refusedInts {
                #expect(MessageContentV2.decode(message.setting(key, value).encoded) == nil, "\(key): \(value)")
            }
        }
    }

    // MARK: A transfer's models

    @Test func aTransfersModelsAreALongList() throws {
        let offer = try vector("messageContentTransferOffer")
        let readable: [CBOR] = [
            .array([.unsigned(0xFFFF_FFFF), .unsigned(1 << 63), .negative(0)]), .array([]), .array([.tagged(7, .unsigned(1))]), .null,
            .map([]),
        ]
        for value in readable {
            #expect(try MessageContent(cbor: offer.editing(.key("xf")) { $0.setting(.key("md"), value) }).ctl == 9, "\(value)")
        }
        let refused: [CBOR] = [
            .array([.text("en-es")]), .array([.unsigned(1), .null]), .array([.map([])]), .array([.bytes([1])]), .text("x"), .unsigned(1),
        ]
        for value in refused {
            #expect(throws: WireDecodingError.self, "\(value)") {
                try MessageContent(cbor: offer.editing(.key("xf")) { $0.setting(.key("md"), value) })
            }
        }
    }

    // MARK: ctl 11's presence keys

    @Test func aPresenceKeyIsTypedFieldByField() throws {
        let content = try vector("messageContentPresenceKeyNext")
        func decode(_ edit: (CBOR) -> CBOR) throws -> MessageContent {
            try MessageContent(cbor: content.editing(.key("pk"), edit))
        }
        for (field, kind) in [("g", "int"), ("k", "bytes")] {
            for broken in [CBOR.null, .map([])] + wrongKinds(besides: kind) {
                #expect(throws: WireDecodingError.self, "pk.\(field): \(broken)") { try decode { $0.setting(.key(field), broken) } }
            }
            #expect(throws: WireDecodingError.missingField(type: "PresenceKeyPayload", field: field)) {
                try decode { $0.removing(.key(field)) }
            }
        }
        for (field, kind) in [("ng", "int"), ("nk", "bytes"), ("p", "bytes")] {
            for wrong in wrongKinds(besides: kind) {
                #expect(throws: WireDecodingError.self, "pk.\(field): \(wrong)") { try decode { $0.setting(.key(field), wrong) } }
            }
            for absent in [CBOR.null, .map([])] {
                #expect(try decode { $0.setting(.key(field), absent) }.pk != nil, "pk.\(field): \(absent)")
            }
        }
        // Shape only: a `g` past `Long.MAX_VALUE` wraps negative and decodes, for `PresenceKeyPolicy` to refuse later.
        #expect(try decode { $0.setting(.key("g"), .unsigned(1 << 63)) }.pk?.generation == .min)
        // A key of any length decodes too: 32 bytes is the policy's rule, not the shape's.
        #expect(try decode { $0.setting(.key("k"), .bytes([1])) }.pk?.key == [1])
        // The `@SerialName`s are the only keys: the Kotlin property names are unknown and skipped.
        #expect(try decode { $0.adding(.key("generation"), .text("x")) }.pk?.generation == 1_793_577_600_000)
    }

    @Test func anAbsentOrNullPresenceKeyIsNoKey() throws {
        let content = try vector("messageContentPresenceKey")
        for absent in [CBOR.null, .map([])] {
            let decoded = try MessageContent(cbor: content.setting(.key("pk"), absent))
            #expect(decoded.pk == nil && decoded.ctl == MessageContent.Control.presenceKey, "\(absent)")
        }
        #expect(try MessageContent(cbor: content.removing(.key("pk"))).pk == nil)
        for wrong in wrongKinds(besides: "map") {
            #expect(throws: WireDecodingError.self, "pk: \(wrong)") { try MessageContent(cbor: content.setting(.key("pk"), wrong)) }
        }
        // An empty map in a longer form is no null mark, so it goes to the payload's decoder, which needs `g` and `k`.
        let longForm = Splice.bytes(content.setting(.key("pk"), Splice.sentinel), [0xBF, 0xFF])
        #expect(throws: WireDecodingError.self) { try MessageContent(decoding: longForm) }
    }

    /// A presence-key payload prints its generations, never a key, whether alone, inside a message or dumped.
    @Test func aPresenceKeyNeverPrintsItsKeys() {
        let key = [UInt8](repeating: 0xAB, count: 32)
        let next = [UInt8](repeating: 0xCD, count: 32)
        let payload = PresenceKeyPayload(generation: 7, key: key, nextGeneration: 8, nextKey: next, pad: [0xEF])
        let content = MessageContent(body: "", ctl: MessageContent.Control.presenceKey, pk: payload)
        var dumped = ""
        dump(content, to: &dumped)
        let printed = [
            String(describing: payload), String(reflecting: payload), String(describing: content), String(reflecting: content), dumped,
        ]
        for text in printed {
            for needle in ["171", "205", "239", "abab", "cdcd"] {
                #expect(!text.lowercased().contains(needle), "\(text) shows \(needle)")
            }
        }
        #expect(String(describing: payload) == "PresenceKeyPayload(g=7, next=8)")
        #expect(String(describing: PresenceKeyPayload(generation: 7, key: key)) == "PresenceKeyPayload(g=7, next=-)")
    }
}
