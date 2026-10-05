import KnitAppCore
import Testing

extension CopyCatalogTests {
    /// Reactions' strings (ADR 2026-10.ehe6), apart so the suite stays under the lint's length.
    static var reactionStrings: [String] {
        [
            Copy.Reactions.react("\u{1F44D}"),
            Copy.Reactions.remove("\u{1F44D}"),
            Copy.Reactions.chipValue(count: 1, mine: true),
            Copy.Reactions.chipValue(count: 2, mine: true),
            Copy.Reactions.chipValue(count: 3, mine: true),
            Copy.Reactions.chipValue(count: 1, mine: false),
            Copy.Reactions.chipValue(count: 2, mine: false),
            Copy.Reactions.summary("\u{1F44D} You and 1 other, \u{2764}\u{FE0F} 1 person"),
        ]
    }
}

extension AccessibilityIDTests {
    /// Reactions' identifiers, the iPhone's own: Android tags no chip. A chip's names its emoji by code points, so no
    /// identifier holds an emoji.
    @Test func eachChipNamesItsMessageAndEmoji() {
        #expect(AccessibilityID.chatReaction("m1", "\u{2764}\u{FE0F}") == "chat_reaction_m1_2764-fe0f")
        #expect(AccessibilityID.chatReaction("m1", "\u{1F44D}") != AccessibilityID.chatReaction("m2", "\u{1F44D}"))
    }
}
