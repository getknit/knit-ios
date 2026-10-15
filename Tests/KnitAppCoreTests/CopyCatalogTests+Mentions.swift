import KnitAppCore
import Testing

extension CopyCatalogTests {
    /// Mentions' strings (ADR 2026-10.nbhj), apart so the suite stays under the lint's length.
    static var mentionStrings: [String] {
        [
            Copy.Mentions.picker,
            Copy.Mentions.offered(1),
            Copy.Mentions.offered(3),
            Copy.Mentions.everyoneNote,
            Copy.Mentions.everyone,
        ]
    }

    @Test func theMentionCountReadsInTheRightNumber() {
        #expect(Copy.Mentions.offered(1) == "1 person to mention")
        #expect(Copy.Mentions.offered(3) == "3 people to mention")
    }

    @Test func theEveryoneRowSaysWhomItNotifies() {
        #expect(Copy.Mentions.everyoneNote == "Notifies everyone else in the group")
        #expect(Copy.Mentions.everyone == "Mention everyone. Notifies everyone else in the group")
    }
}
