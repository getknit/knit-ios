import Foundation
import Testing

@testable import KnitAppCore

/// The Swift tokenizer makes the ids Hugging Face's own library makes from Android's `tokenizer.json` (ADR 2026-10.e4kz).
/// `tools/models/toxicity/tokens.py` wrote the goldens: knit-next's own (`SentencePieceTokenizerTest.kt`), then the
/// corners of the normalizer and the pre-tokenizer.
@Suite struct SentencePieceTokenizerTests {
    private struct Goldens: Decodable {
        struct Item: Decodable {
            let text: String
            let ids: [Int32]
        }

        let length: Int
        let items: [Item]
    }

    private static let tokenizer = SentencePieceTokenizer(json: (try? data("App/Models/ToxicityTokenizer.json")) ?? Data())

    private static func data(_ path: String) throws -> Data {
        try Data(contentsOf: CopyTests.root.appendingPathComponent(path))
    }

    @Test func everyGoldenGetsHuggingFacesIds() throws {
        let words = try #require(Self.tokenizer)
        let goldens = try JSONDecoder().decode(Goldens.self, from: Self.data("tools/models/toxicity/parity/tokens.json"))
        #expect(goldens.items.count >= 40)
        for golden in goldens.items {
            let (ids, mask) = words.encode(golden.text, length: goldens.length)
            #expect(Array(ids.prefix(golden.ids.count)) == golden.ids, "\(golden.text.debugDescription)")
            #expect(ids.count == goldens.length && mask.count == goldens.length)
            #expect(mask == Array(repeating: 1, count: golden.ids.count) + Array(repeating: 0, count: goldens.length - golden.ids.count))
            #expect(ids.dropFirst(golden.ids.count).allSatisfy { $0 == 0 }, "padded with <pad>")
        }
    }

    @Test func androidsGoldensHoldAtItsLengthToo() throws {
        // `SentencePieceTokenizerTest.matchesHuggingFaceIds` encodes at 64.
        let words = try #require(Self.tokenizer)
        #expect(words.encode("shut up moron", length: 64).ids.prefix(5) == [2, 2218, 71, 24_932, 3])
        #expect(words.encode("emoji test 🔥😡", length: 64).ids.prefix(7) == [2, 3579, 18_451, 1289, 13, 1, 3])
        #expect(words.encode("", length: 64).ids.prefix(3) == [2, 3, 0])
    }

    @Test func aLongTextIsCutBetweenItsClsAndSep() throws {
        // `SentencePieceTokenizerTest.truncatesKeepingClsAndSep`.
        let words = try #require(Self.tokenizer)
        let (ids, mask) = words.encode(String(repeating: "word ", count: 200), length: 8)
        #expect(ids == [2, 833, 833, 833, 833, 833, 833, 3])
        #expect(mask.allSatisfy { $0 == 1 })
        #expect(words.encode("anything", length: 0).ids == [2, 3], "room for [CLS] and [SEP] at the least")
    }

    @Test func aFileThatIsNoUnigramTokenizerIsRefused() {
        #expect(SentencePieceTokenizer(json: Data("{}".utf8)) == nil)
        #expect(SentencePieceTokenizer(json: Data(#"{"model":{"type":"BPE","unk_id":0,"vocab":[["a",0]]}}"#.utf8)) == nil)
        #expect(SentencePieceTokenizer(json: Data(#"{"model":{"type":"Unigram","unk_id":3,"vocab":[["a",0]]}}"#.utf8)) == nil)
        let bare = #"{"model":{"type":"Unigram","unk_id":0,"vocab":[["<unk>",0],["▁a",-1]]}}"#
        #expect(SentencePieceTokenizer(json: Data(bare.utf8)) == nil, "no [CLS] or [SEP] to frame a message")
    }

    @Test func theNormalizerRunsTwiceAndKeepsNoMark() {
        #expect(SentencePieceTokenizer.normalized("``Ça'' İ  x\u{0903}") == "\"ca\" i x")
        #expect(SentencePieceTokenizer.words(" a\u{2581}b  c ").map { String(String.UnicodeScalarView($0)) } == ["▁a", "▁b", "▁c"])
    }
}
