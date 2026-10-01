import KnitCrypto
import Testing

/// The group id (`Conversations.groupIdFor`). knit-next's `ConversationsTest` pins only its properties, so the goldens
/// were computed in Python from the Kotlin; A5's keyed vectors will pin them on both sides (ADR 2026-09.n393).
@Suite struct GroupIdTests {
    @Test func theIdIsTheSaltedHashOfTheSortedMembers() {
        #expect(GroupId.derive(["alice", "bob", "carol"]) == "g-0fcb434512afea55af84f0a5")
        #expect(GroupId.derive(["a", "b"]) == "g-0aaf7d9b49f9210774ddcf1d")
    }

    /// `groupIdIsOrderAgnostic` and `groupIdDedupesMembers`: the same people make the same group.
    @Test func orderAndRepeatsDoNotMatter() {
        #expect(GroupId.derive(["carol", "alice", "bob", "alice"]) == GroupId.derive(["alice", "bob", "carol"]))
    }

    /// Kotlin's `TreeSet` sorts by UTF-16 code units, which put a surrogate pair (U+1F600) ahead of U+FF61. Unicode
    /// scalar order, Swift's, puts it after, and gives `g-786c8e7cddfe4cc9ea05e679`.
    @Test func membersSortByTheirUTF16Units() {
        #expect(GroupId.derive(["\u{FF61}", "\u{1F600}"]) == "g-54465e508ab811be30a4eb91")
    }

    /// The Kelvin sign is canonically equal to `K` in Swift and a different member in Kotlin (ADR 2026-09.jc2x).
    @Test func canonicallyEqualMembersStayTwo() {
        #expect(GroupId.derive(["K", "\u{212A}"]) == "g-34f034521607b981e226481b")
        #expect(GroupId.derive(["K"]) == "g-a544d4dc747625f5293d494c")
    }

    @Test func theIdIsThePrefixAndTwentyFourLowercaseHexDigits() {
        let id = GroupId.derive(["x"])
        #expect(id.hasPrefix("g-"))
        #expect(id.count == 26)
        #expect(id.dropFirst(2).allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}
