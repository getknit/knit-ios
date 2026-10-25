import KnitTestSupport
import KnitWire
import Testing

/// A room post's declared size, `ChatContent.attachmentSize` (knit-next ADRs 2026-10.hmfe and 2026-10.js2p, knit-ios #7):
/// after `replyTo` and before `video`, as `Wire.kt:216-242` at knit-next `eac3debc` declares them, and absent when unset.
@Suite struct ChatContentSizeTests {
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

    @Test func androidsRoomVideoDeclaresItsSize() throws {
        let chat = try ChatContent(decoding: GoldenVectors.bytes("chatContentVideo"))
        #expect(chat.attachmentSize == 3_000_000)
        #expect(chat.body == "look" && chat.attachmentMime == "video/mp4")
    }

    /// The vector, its `video` entry taken out, is what a room post of ours that declares the same size encodes to: the
    /// shortest unsigned form (`1a002dc6c0`), in Android's place.
    @Test func aRoomPostThatDeclaresItsSizeEncodesAsAndroidsDoes() throws {
        guard case .map(let entries) = try CBOR.decode(GoldenVectors.bytes("chatContentVideo")) else {
            Issue.record("not a map")
            return
        }
        let withoutVideo = CBOR.map(entries.filter { $0.key != .text("video") })
        let hash = try #require(try ChatContent(decoding: GoldenVectors.bytes("chatContentVideo")).attachmentHash)
        let ours = ChatContent(body: "look", attachmentHash: hash, attachmentMime: "video/mp4", attachmentSize: 3_000_000)
        #expect(ours.encoded == withoutVideo.encoded)
        let shortest: [UInt8] = [0x1a, 0x00, 0x2d, 0xc6, 0xc0]
        #expect(ours.encoded.indices.contains { ours.encoded[$0...].starts(with: shortest) }, "a four-byte unsigned")
        #expect(try ChatContent(decoding: ours.encoded) == ours)
    }

    /// No vector holds a quote and a size together, so their order is pinned from `Wire.kt` here.
    @Test func aRoomReplyThatDeclaresItsSizePutsItAfterTheQuote() throws {
        let reply = ReplyRef(messageId: "m0", authorId: "a", author: "Ann", snippet: "see you")
        let chat = ChatContent(
            body: "this one", attachmentHash: "h", attachmentMime: "image/jpeg", replyTo: reply, attachmentSize: 1_000_000)
        #expect(try keys(chat.encoded) == ["body", "attachmentHash", "attachmentMime", "replyTo", "attachmentSize"])
        #expect(try ChatContent(decoding: chat.encoded) == chat)
    }

    /// Unset, the key is absent, so a post below the floor is what it always was.
    @Test func anUndeclaredSizeIsLeftOut() throws {
        let chat = ChatContent(body: "small", attachmentHash: "h", attachmentMime: "image/jpeg")
        #expect(try keys(chat.encoded) == ["body", "attachmentHash", "attachmentMime"])
        #expect(try ChatContent(decoding: chat.encoded).attachmentSize == nil)
    }

    /// kotlinx reads a negative `Long` as it is, and Android filters it with `> 0` later, so it decodes here too. A value
    /// past `Int64.max` wraps to a negative `Long`, as kotlinx-cbor 1.12.0 wraps it (`Decoder.kt:406-424`), so the post
    /// decodes on both and both carry it; only a wrongly typed size refuses the post, on both.
    @Test func aNegativeSizeDecodesAndOnePastLongWrapsAsKotlinxReadsIt() throws {
        let negative = ChatContent(body: "odd", attachmentSize: -5)
        #expect(try ChatContent(decoding: negative.encoded).attachmentSize == -5)
        for (item, kotlin) in [
            (CBOR.unsigned(UInt64(Int64.max) + 1), Int64.min), (.unsigned(.max), -1), (.negative(.max), 0),
            (.negative(UInt64(Int64.max)), Int64.min),
        ] {
            let past = CBOR.map([
                CBOR.Entry(key: .text("body"), value: .text("odd")), CBOR.Entry(key: .text("attachmentSize"), value: item),
            ])
            #expect(try ChatContent(decoding: past.encoded).attachmentSize == kotlin, "\(item)")
        }
        let wrongType = CBOR.map([CBOR.Entry(key: .text("attachmentSize"), value: .text("big"))])
        #expect(throws: WireDecodingError.self) { try ChatContent(decoding: wrongType.encoded) }
    }
}
