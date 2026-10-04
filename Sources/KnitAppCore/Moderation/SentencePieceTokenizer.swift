public import Foundation

/// ALBERT's SentencePiece unigram tokenizer, built from the Hugging Face `tokenizer.json` Knit for Android bundles
/// (`SentencePieceTokenizer.kt`): the ids the toxicity model reads (ADR 2026-10.e4kz).
///
/// It runs the pipeline that file describes, and `SentencePieceTokenizerTests` holds it to the ids Hugging Face's own
/// library makes from the same file (`tools/models/toxicity/tokens.py`):
///
/// 1. **Normalize,** twice over, as the file lists it: ``` `` ``` and `''` become `"`, then NFKD, every combining mark
///    goes (Hugging Face's `StripAccents`; Kotlin takes only the nonspacing ones), each scalar lowercases, and runs of
///    spaces collapse. The second pass catches what the first leaves, such as the dot that lowercasing `İ` adds.
///    Android's Kotlin runs it once.
/// 2. **Split** on whitespace, start each word with the metaspace `▁`, and split again at any `▁` the text carried.
/// 3. **Search** each word for its best-scoring pieces (Viterbi over the vocabulary's log probabilities). A character
///    no piece covers is unknown, and a run of them becomes one `<unk>`.
///
/// It walks Unicode scalars, as Hugging Face's Rust does; Kotlin walks UTF-16 units, which gives the same ids for an
/// emoji only because both halves of one are unknown. Neither port picks out a special token such as `[SEP]` typed in a
/// message, which Hugging Face's library would.
public struct SentencePieceTokenizer: Sendable {
    /// What every word starts with.
    private static let metaspace: Unicode.Scalar = "\u{2581}"
    /// How far below the vocabulary's lowest score an unknown character scores (`kUnkPenalty` in SentencePiece).
    private static let unknownPenalty = 10.0
    /// The tokens that frame every message: `[CLS]` before it and `[SEP]` after.
    private static let framing = 2

    private let pieces: [String: (id: Int32, score: Double)]
    private let unknownId: Int32
    private let firstId: Int32
    private let lastId: Int32
    private let unknownScore: Double
    /// The longest piece, in scalars: how far back a search looks.
    private let longest: Int

    /// The tokenizer in `json`, a Hugging Face `tokenizer.json` for a unigram model; `nil` when it is no such file or
    /// lacks `[CLS]` and `[SEP]`.
    public init?(json: Data) {
        guard let model = try? JSONDecoder().decode(TokenizerFile.self, from: json).model, model.type == "Unigram",
            model.vocab.indices.contains(model.unkId)
        else {
            return nil
        }
        var table: [String: (id: Int32, score: Double)] = [:]
        table.reserveCapacity(model.vocab.count)
        for (id, piece) in model.vocab.enumerated() where table[piece.text] == nil {
            table[piece.text] = (Int32(id), piece.score)
        }
        guard let first = table["[CLS]"], let last = table["[SEP]"] else {
            return nil
        }
        pieces = table
        unknownId = Int32(model.unkId)
        firstId = first.id
        lastId = last.id
        unknownScore = (model.vocab.map(\.score).min() ?? 0) - Self.unknownPenalty
        longest = model.vocab.map(\.text.unicodeScalars.count).max() ?? 1
    }

    /// `text` as the model reads it: `[CLS]`, the ids of its pieces, cut to fit, and `[SEP]`, padded with zeros to
    /// `length`, with a mask of ones over the real tokens (`SentencePieceTokenizer.encode`). A `length` too short for
    /// `[CLS]` and `[SEP]` gets those two alone.
    public func encode(_ text: String, length: Int) -> (ids: [Int32], mask: [Int32]) {
        let total = max(length, Self.framing)
        let room = total - Self.framing
        var body: [Int32] = []
        for word in Self.words(Self.normalized(text)) where body.count < room {
            search(word, into: &body)
        }
        let kept = [firstId] + body.prefix(room) + [lastId]
        let padding = total - kept.count
        return (kept + Array(repeating: 0, count: padding), Array(repeating: 1, count: kept.count) + Array(repeating: 0, count: padding))
    }

    /// The normalizer the file lists, which runs its four steps twice.
    static func normalized(_ text: String) -> String {
        let quoted = text.replacing("``", with: "\"").replacing("''", with: "\"")
        return folded(folded(quoted))
    }

    /// NFKD, combining marks removed, each scalar lowercased, runs of spaces made one.
    private static func folded(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCompatibilityMapping.unicodeScalars where !isMark(scalar) {
            for lower in scalar.properties.lowercaseMapping.unicodeScalars where !(lower == " " && out.last == " ") {
                out.append(lower)
            }
        }
        return String(out)
    }

    /// Whether `scalar` is a combining mark of any kind (`General_Category=Mark`).
    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            true
        default:
            false
        }
    }

    /// The words of `text`, each a run of non-whitespace starting with the metaspace, split again at a metaspace inside.
    static func words(_ text: String) -> [[Unicode.Scalar]] {
        var words: [[Unicode.Scalar]] = []
        var word: [Unicode.Scalar] = []
        func close() {
            if !word.isEmpty {
                words.append(word)
                word = []
            }
        }
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                close()
            } else if scalar == metaspace {
                close()
                word = [metaspace]
            } else {
                if word.isEmpty {
                    word = [metaspace]
                }
                word.append(scalar)
            }
        }
        close()
        return words
    }

    /// Appends the best segmentation of `word` to `ids`, a run of unknown characters as one `<unk>`.
    private func search(_ word: [Unicode.Scalar], into ids: inout [Int32]) {
        let count = word.count
        var best = [Double](repeating: -.infinity, count: count + 1)
        var from = [Int](repeating: -1, count: count + 1)
        var unknown = [Bool](repeating: false, count: count + 1)
        best[0] = 0
        for end in 1...count {
            for start in max(0, end - longest)..<end where best[start] > -.infinity {
                if let piece = pieces[String(String.UnicodeScalarView(word[start..<end]))], best[start] + piece.score > best[end] {
                    best[end] = best[start] + piece.score
                    from[end] = start
                    unknown[end] = false
                }
            }
            if best[end - 1] > -.infinity, best[end - 1] + unknownScore > best[end] {
                best[end] = best[end - 1] + unknownScore
                from[end] = end - 1
                unknown[end] = true
            }
        }
        var spans: [Span] = []
        var end = count
        while end > 0 {
            spans.append(Span(start: from[end], end: end, unknown: unknown[end]))
            end = from[end]
        }
        var lastWasUnknown = false
        for span in spans.reversed() {
            if span.unknown {
                if !lastWasUnknown {
                    ids.append(unknownId)
                }
            } else if let piece = pieces[String(String.UnicodeScalarView(word[span.start..<span.end]))] {
                ids.append(piece.id)
            }
            lastWasUnknown = span.unknown
        }
    }

    /// One piece of a word's best segmentation, by scalar offsets; an unknown one is a single character.
    private struct Span {
        let start: Int
        let end: Int
        let unknown: Bool
    }
}

/// The part of `tokenizer.json` the tokenizer reads: its model.
private struct TokenizerFile: Decodable {
    let model: UnigramModel
}

/// A unigram model: its type, which piece is unknown, and every piece with its log probability.
private struct UnigramModel: Decodable {
    /// One `[piece, score]` pair.
    struct Piece: Decodable {
        let text: String
        let score: Double

        init(from decoder: any Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            text = try pair.decode(String.self)
            score = try pair.decode(Double.self)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type = "type"
        case unkId = "unk_id"
        case vocab = "vocab"
    }

    let type: String
    let unkId: Int
    let vocab: [Piece]
}
