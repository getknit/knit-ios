import KnitCrypto
import KnitWire
import Testing

@testable import KnitAppCore

/// ``NameKey/quick(_:)`` answers what ``NameKey/of(_:)`` does, whichever way it takes.
@Suite struct NameKeyQuickTests {
    /// Every printable ASCII character, alone and between two letters.
    @Test func everyPrintableCharacterKeysAsTheFullKeyDoes() {
        for byte in UInt8(ascii: " ")...UInt8(ascii: "~") {
            let character = String(Unicode.Scalar(byte))
            for text in [character, "a\(character)b", "I\(character)L"] {
                #expect(NameKey.quick(text) == NameKey.of(text), "\(text)")
            }
        }
    }

    /// Every alias word, and every label an alias phrase grows to: the texts the received-mention rule keys.
    @Test func everyAliasWordAndLabelKeysAsTheFullKeyDoes() {
        for word in AliasWords.adverbs + AliasWords.adjectives + AliasWords.nouns {
            #expect(NameKey.quick(word) == NameKey.of(word), "\(word)")
        }
        for seed in 0..<64 {
            let words = Alias.tokens(for: "id-\(seed)")
            for spent in 1...Alias.maxTokens {
                let label = PeerLabel(
                    nodeId: "", name: words[0], alias: "", discriminator: spent == 1 ? nil : words[1..<spent].joined(separator: " "))
                #expect(NameKey.quick(label.text) == NameKey.of(label.text), "\(label.text)")
            }
        }
    }

    /// What the shortcut leaves to the full key: whitespace at an edge or in a run, a control, anything past ASCII.
    @Test(arguments: ["", " ", " Alice", "Alice ", "Al  ice", "Al\tice", "Al\u{1C}ice", "Alic\u{0435}", "\u{FF21}lice", "Alice\u{FE0F}"])
    func whatTheShortcutLeavesKeysAsTheFullKeyDoes(text: String) {
        #expect(NameKey.quick(text) == NameKey.of(text))
    }
}
