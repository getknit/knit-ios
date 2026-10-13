import KnitTestSupport
import KnitWire
import Testing

/// A quote's place in the two payloads that carry one (ADR 2026-10.mn29): last in `ChatContent`, between the attachment
/// and the control fields in `MessageContent`, as `Wire.kt:205-216` and `MessageContent.kt:34-80` declare them.
@Suite struct ReplyWireTests {
    /// The golden `replyRef`'s fields.
    private let golden = ReplyRef(messageId: "m0", authorId: "a", author: "Ann", snippet: "see you", hasAttachment: true)

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

    /// `commonsPostFull` wraps a room reply's whole `ChatContent`, quote and mention included: a room reply of ours
    /// encodes to those bytes.
    @Test func aRoomReplyEncodesAsAndroidsDoes() throws {
        let commons = GoldenVectors.bytes("commonsPostFull")
        guard case .map(let entries) = try CBOR.decode(commons), let chat = entries.first(where: { $0.key == .text("chat") })?.value else {
            Issue.record("commonsPostFull carries no chat")
            return
        }
        let ann = "amfbcga7eywtio2cjfifoxtfnq"
        let reply = ChatContent(
            body: "hi @Ann",
            mentions: [Mention(nodeId: ann, name: "Ann")],
            replyTo: ReplyRef(messageId: "Bg0UGyIpMDc-RUxTWmFobw", authorId: ann, author: "Ann", snippet: "see you")
        )
        #expect(reply.encoded == chat.encoded)
        #expect(try ChatContent(decoding: chat.encoded) == reply)
    }

    /// No vector seals a quote, so the order is the Kotlin declaration's: after `attachmentSize`, before `ctl` and `ack`.
    @Test func aSealedQuoteSitsBetweenTheAttachmentAndTheControlFields() throws {
        let content = MessageContent(body: "yes", attachmentHash: "h", attachmentSize: 4, replyTo: golden, ack: "m1")
        let bytes = content.encoded
        #expect(try keys(bytes) == ["body", "attachmentHash", "attachmentSize", "replyTo", "ack"])
        guard case .map(let entries) = try CBOR.decode(bytes), let quote = entries.first(where: { $0.key == .text("replyTo") })?.value
        else {
            Issue.record("no quote")
            return
        }
        #expect(quote.encoded == GoldenVectors.bytes("replyRef"))
        #expect(try MessageContent(decoding: bytes) == content)
    }

    /// `author` and `snippet` have no default, so an empty one is still written (`60`), and `hasAttachment` is left out
    /// while it is false.
    @Test func anEmptyNameAndSnippetAreStillWritten() throws {
        let bare = ReplyRef(messageId: "m0", authorId: "a", author: "", snippet: "")
        #expect(try keys(bare.encoded) == ["messageId", "authorId", "author", "snippet"])
        #expect(try ReplyRef(decoding: bare.encoded) == bare)
    }

    /// A quote missing a field Android requires fails the whole payload, there as here.
    @Test func aQuoteMissingItsSnippetFailsTheMessage() throws {
        let broken = CBOR.map([
            CBOR.Entry(key: .text("body"), value: .text("yes")),
            CBOR.Entry(
                key: .text("replyTo"),
                value: .map([
                    CBOR.Entry(key: .text("messageId"), value: .text("m0")),
                    CBOR.Entry(key: .text("authorId"), value: .text("a")),
                    CBOR.Entry(key: .text("author"), value: .text("Ann")),
                ])
            ),
        ])
        #expect(throws: WireDecodingError.self) { try ChatContent(decoding: broken.encoded) }
        #expect(throws: WireDecodingError.self) { try MessageContent(decoding: broken.encoded) }
    }
}
