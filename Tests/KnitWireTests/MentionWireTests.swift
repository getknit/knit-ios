import KnitTestSupport
import KnitWire
import Testing

/// A mention's place in the sealed payload: right after `body`, as `MessageContent.kt:36-38` declares it. The cleartext
/// one is pinned by the `chatContent` and `commonsPostFull` goldens; no vector seals a mention.
@Suite struct MentionWireTests {
    /// The golden `mention`'s fields.
    private let golden = Mention(nodeId: "node1", name: "Ann")

    /// The keys of `bytes`' top-level map, in wire order.
    private func keys(_ bytes: [UInt8]) throws -> [String] {
        guard case .map(let entries) = try CBOR.decode(bytes) else {
            Issue.record("not a map")
            return []
        }
        return entries.compactMap { entry in
            guard case .text(let key) = entry.key else {
                return nil
            }
            return key
        }
    }

    /// A sealed mention sits between the body and the attachment, and each entry encodes to the golden bytes.
    @Test func aSealedMentionSitsRightAfterTheBody() throws {
        let content = MessageContent(body: "hi @Ann", mentions: [golden], attachmentHash: "h")
        let bytes = content.encoded
        #expect(try keys(bytes) == ["body", "mentions", "attachmentHash"])
        guard case .map(let entries) = try CBOR.decode(bytes),
            case .array(let mentions) = entries.first(where: { $0.key == .text("mentions") })?.value
        else {
            Issue.record("no mentions")
            return
        }
        #expect(mentions.map(\.encoded) == [GoldenVectors.bytes("mention")])
        #expect(try MessageContent(decoding: bytes) == content)
    }

    /// An empty list is Kotlin's default, which `encodeDefaults = false` leaves out, in both payloads.
    @Test func noMentionsWritesNoKey() throws {
        #expect(try keys(MessageContent(body: "hi").encoded) == ["body"])
        #expect(try !keys(ChatContent(body: "hi").encoded).contains("mentions"))
    }

    /// A body carries a mention when its code units hold the token, as Kotlin's `contains` reads it, even where Swift's
    /// characters would not: here the token's last letter takes a combining accent.
    @Test func indexOfComparesCodeUnits() {
        let text = Array("hi @Ann\u{301} and @Ann".utf16)
        let token = Array("@Ann".utf16)
        #expect(TextLimits.utf16Index(of: token, in: text) == 3)
        #expect(TextLimits.utf16Index(of: token, in: text, from: 4) == 13)
        #expect(TextLimits.utf16Index(of: token, in: text, from: 14) == nil)
        #expect(TextLimits.utf16Index(of: [], in: text) == nil)
        #expect(TextLimits.utf16Index(of: token, in: Array("@An".utf16)) == nil)
    }

    /// `name` has no default, so a mention without one fails the whole payload, there as here.
    @Test func aMentionMissingItsNameFailsTheMessage() throws {
        let broken = CBOR.map([
            CBOR.Entry(key: .text("body"), value: .text("hi @Ann")),
            CBOR.Entry(key: .text("mentions"), value: .array([.map([CBOR.Entry(key: .text("nodeId"), value: .text("node1"))])])),
        ])
        #expect(throws: WireDecodingError.self) { try ChatContent(decoding: broken.encoded) }
        #expect(throws: WireDecodingError.self) { try MessageContent(decoding: broken.encoded) }
    }
}
