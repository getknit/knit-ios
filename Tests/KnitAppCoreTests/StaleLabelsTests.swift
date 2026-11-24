import KnitAppCore
import KnitCrypto
import Testing

/// Stale members give way in the label index, ported from the stale cases of knit-next's `PeerLabelsTest` (ADR
/// 2026-10.k8ge there).
@Suite struct StaleLabelsTests {
    /// `PeerLabelsTests`' ground pair: real node ids whose alias digests share their first four bytes.
    private static let groundX = "jiuqkhusaqt3u25svz7rbvvwje"
    private static let groundY = "p3ve2zdqk6ecz5dfofpywoobxa"

    private func index(_ peers: [(String, String)], me: (String, String)? = nil, stale: Set<String> = []) -> PeerLabelIndex {
        PeerLabelIndex(
            peers: peers.map { (nodeId: $0.0, name: $0.1) }, me: me.map { (nodeId: $0.0, name: $0.1) }, stale: stale)
    }

    private func alias(_ nodeId: String) -> String {
        Alias.alias(for: nodeId)
    }

    /// `count` peers named from `pool` by a fixed draw, so a failure replays.
    private func universe(_ count: Int, pool: [String], seed: UInt64) -> [(String, String)] {
        var draw = SplitMix(state: seed)
        return (0..<count).map { ("peer-\($0)", pool[Int(draw.next() % UInt64(pool.count))]) }
    }

    @Test func anEmptyStaleSetIsTheIndexWithoutIt() {
        let peers = universe(500, pool: ["Alice", "alice", "Bob", "Sam", "SAM", ""], seed: 11)
        let me = ("me", "Alice")
        let without = index(peers, me: me)
        // Ids outside the universe change nothing either.
        let with = index(peers, me: me, stale: ["not-a-member"])
        for nodeId in peers.map(\.0) + [me.0] {
            #expect(without.label(for: nodeId) == with.label(for: nodeId))
            #expect(without.mentionTexts(for: nodeId) == with.mentionTexts(for: nodeId))
        }
    }

    @Test func aContactWhoseOnlyNamesakeIsStaleReadsPlainAndTheStrangerStaysMarked() {
        #expect(index([("c", "Alice"), ("s", "Alice")]).label(for: "c").discriminator == alias("c"))
        let labels = index([("c", "Alice"), ("s", "Alice")], stale: ["s"])
        #expect(labels.label(for: "c").discriminator == nil)
        #expect(labels.label(for: "c").text == "Alice")
        #expect(labels.label(for: "c").alias == alias("c"), "still shown where the alias is quoted")
        #expect(labels.label(for: "s").discriminator == alias("s"))
        // A sender outside the universe still reads apart from the stale namesake, and from the contact.
        #expect(labels.label(for: "zz", storedName: "Alice").discriminator == alias("zz"))
    }

    @Test func twoStaleNamesakesStayMarkedAndApart() {
        let labels = index([("a", "Alice"), ("b", "Alice")], stale: ["a", "b"])
        #expect(labels.label(for: "a").discriminator == alias("a"))
        #expect(labels.label(for: "b").discriminator == alias("b"))
        #expect(labels.label(for: "a").text != labels.label(for: "b").text)
    }

    @Test func aStaleGroundLookAlikeKeepsBothTokensSoItNeverWearsTheContactsOldLabel() {
        let both = [(Self.groundX, "Alice"), (Self.groundY, "Alice")]
        let contactsLabelWhileBothWereLive = index(both).label(for: Self.groundX).text
        let labels = index(both, stale: [Self.groundY])
        #expect(labels.label(for: Self.groundX).discriminator == nil)
        #expect(labels.label(for: Self.groundY).discriminator == Alias.phrase(for: Self.groundY, count: 2))
        // One token would read "Alice (<the shared first token>)": the contact's quoted alias.
        #expect(labels.label(for: Self.groundY).text != "Alice (\(alias(Self.groundX)))")
        #expect(labels.label(for: Self.groundY).text != contactsLabelWhileBothWereLive)
    }

    @Test func aLiveTextThatShrankOntoAStaleOneHoldsAndOnlyTheStaleOneGrows() {
        // L shares its chosen name only with the stale S2, so it drops its token once S2 yields, landing on
        // "Alice (<S's alias>)", the text S holds against the whole universe. S is the one that moves.
        let chosen = "Alice (\(alias("s")))"
        let labels = index([("m", "Alice"), ("s", "Alice"), ("l", chosen), ("s2", chosen)], stale: ["s", "s2"])
        #expect(labels.label(for: "m").discriminator == nil)
        #expect(labels.label(for: "l").discriminator == nil)
        #expect(labels.label(for: "l").text == chosen)
        #expect(labels.label(for: "s").discriminator == Alias.phrase(for: "s", count: 2))
        #expect(Set(["m", "s", "l", "s2"].map { labels.label(for: $0).text }).count == 4)
    }

    @Test func weNeverYield() {
        let labels = index([("a", "Alice")], me: ("me", "Alice"), stale: ["me", "a"])
        #expect(labels.label(for: "me").discriminator == nil)
        #expect(labels.label(for: "a").discriminator == alias("a"))
    }

    @Test func everyLabelIsDistinctWhateverYields() {
        let peers = universe(2000, pool: ["Alice", "alice", "Bob", "Sam", "SAM", "Dani", "Jonas W.", ""], seed: 13)
        var draw = SplitMix(state: 17)
        let stale = Set(peers.map(\.0).filter { _ in draw.next().isMultiple(of: 3) })
        let labels = index(peers, me: ("me", "Alice"), stale: stale)
        let texts = (peers.map(\.0) + ["me"]).map { labels.label(for: $0).text }
        #expect(Set(texts).count == texts.count)
    }

    @Test func aStaleNamesakeYieldsSoTheContactsBareNameCountsAgain() {
        let labels = index([("c", "Alice"), ("s", "Alice")], stale: ["s"])
        #expect(labels.mentionTexts(for: "c").first == "Alice")
        #expect(labels.mentionTexts(for: "c").count == Alias.maxTokens + 1)
        // The stale one still reads apart, so its texts start at its suffixed label.
        #expect(labels.mentionTexts(for: "s").first == labels.label(for: "s").text)
        #expect(!labels.mentionTexts(for: "s").contains("Alice"))
    }
}

/// A fixed, seedable draw (SplitMix64), so a randomised case replays the same universe every run.
private struct SplitMix {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
