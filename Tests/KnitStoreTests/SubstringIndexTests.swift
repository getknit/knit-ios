import KnitWire
import Testing

@testable import KnitStore

/// The index ``MessageMention/carried(_:in:)`` looks tokens up in answers as a plain search of the body does, by UTF-16
/// code units, over texts and needles drawn from a small alphabet so that repeats and near misses are common.
@Suite struct SubstringIndexTests {
    /// A fixed linear congruential generator, so every run draws the same cases.
    private struct Draws {
        var state: UInt64

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }

        mutating func text(upTo length: Int) -> [UInt16] {
            let alphabet = Array("ab@".utf16)
            return (0..<next(length + 1)).map { _ in alphabet[next(alphabet.count)] }
        }
    }

    @Test func itAnswersAsAPlainSearchDoes() {
        var draws = Draws(state: 0x4B4E_4954)
        for _ in 0..<300 {
            let text = draws.text(upTo: 40)
            let index = SubstringIndex(text)
            for _ in 0..<20 {
                var needle = draws.text(upTo: 6)
                if draws.next(2) == 0, !text.isEmpty {
                    let start = draws.next(text.count)
                    needle = Array(text[start..<min(text.count, start + 1 + draws.next(8))])
                }
                guard !needle.isEmpty else {
                    continue
                }
                #expect(index.contains(needle) == (TextLimits.utf16Index(of: needle, in: text) != nil), "\(text) \(needle)")
            }
        }
    }

    /// Every substring of a text with repeats is found, and a near miss is not; an empty text holds only the empty needle.
    @Test func everySubstringIsFound() {
        let text = Array("@Ann @Annabel @An".utf16)
        let index = SubstringIndex(text)
        for start in text.indices {
            for end in (start + 1)...text.count {
                #expect(index.contains(Array(text[start..<end])))
            }
        }
        #expect(!index.contains(Array("@Anna@".utf16)))
        #expect(!SubstringIndex([]).contains(Array("@".utf16)))
        #expect(SubstringIndex([]).contains([]))
    }
}
