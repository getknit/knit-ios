import KnitAppCore
import KnitCrypto
import KnitWire
import Testing

/// Collision-aware labels, ported from knit-next's `PeerLabelsTest` and `NameKeyTest` (ADR 058 there).
@Suite struct PeerLabelsTests {
    /// Two real node ids whose alias digests share their first four bytes, from knit-next's birthday scan over
    /// `NodeId.derive("alias-scan-$i")`: the same first token, a different second one, which is what a key pair
    /// ground to match an alias looks like.
    private static let groundX = "jiuqkhusaqt3u25svz7rbvvwje"
    private static let groundY = "p3ve2zdqk6ecz5dfofpywoobxa"

    private func index(_ peers: (String, String)..., me: (String, String)? = nil) -> PeerLabelIndex {
        PeerLabelIndex(peers: peers.map { (nodeId: $0.0, name: $0.1) }, me: me.map { (nodeId: $0.0, name: $0.1) })
    }

    private func alias(_ nodeId: String) -> String {
        Alias.alias(for: nodeId)
    }

    @Test func aUniqueNameIsUndiscriminatedAndIsTheDisplayName() {
        let labels = index(("a", "Alice"), ("b", "Bob"), ("c", ""))
        for (nodeId, stored) in [("a", "Alice"), ("b", "Bob"), ("c", "")] {
            let label = labels.label(for: nodeId)
            #expect(label.discriminator == nil)
            #expect(label.text == Alias.displayName(stored: stored, nodeId: nodeId))
            #expect(label.alias == alias(nodeId))
        }
        #expect(labels.label(for: "c").text == alias("c"), "a blank name renders as the alias")
    }

    @Test func twoPeersRenderingToTheSameKeyBothGetTheirAlias() {
        let labels = index(("a", "Alice"), ("b", "alice "), ("c", "Carol"))
        #expect(labels.label(for: "a").text == "Alice (\(alias("a")))")
        #expect(labels.label(for: "b").text == "alice  (\(alias("b")))", "the stored name renders verbatim")
        #expect(labels.label(for: "c").discriminator == nil)
    }

    @Test func aThreeWayCollisionDiscriminatesEveryMember() {
        let labels = index(("a", "Sam"), ("b", "Sam"), ("c", "SAM"))
        #expect(Set(["a", "b", "c"].map { labels.label(for: $0).text }).count == 3)
        for nodeId in ["a", "b", "c"] {
            #expect(labels.label(for: nodeId).discriminator == alias(nodeId))
        }
    }

    @Test func weArePartOfTheUniverse() {
        let labels = index(("a", "Alice"), me: ("me", "Alice"))
        #expect(labels.label(for: "a").discriminator == alias("a"))
        #expect(labels.label(for: "me").discriminator == alias("me"))
    }

    @Test func aPeerRowForOurOwnIdIsOneIdentityWithUs() {
        let labels = index(("me", "Alice"), ("b", "Bob"), me: ("me", "Alice"))
        #expect(labels.label(for: "me").discriminator == nil)
    }

    @Test func anUnknownSenderIsDiscriminatedWhenItCollidesWithAKnownName() {
        let labels = index(("a", "Alice"))
        #expect(labels.label(for: "zz", storedName: "Alice").discriminator == alias("zz"))
        #expect(labels.label(for: "zz", storedName: "Zed").discriminator == nil)
        #expect(labels.label(for: "zz", storedName: nil).discriminator == nil)
        #expect(labels.label(for: "a").discriminator == nil, "a lookup never discriminates a member after the fact")
    }

    @Test func aBlankNamedPeerGrowsAContinuationWhenSomeoneChoosesItsAlias() {
        let impostor = alias("a")
        let labels = index(("a", ""), ("b", impostor))
        let blank = labels.label(for: "a")
        let tokens = Alias.tokens(for: "a", count: 2)
        #expect(blank.discriminator == tokens[1], "the name already is the first token")
        #expect(blank.alias == Alias.phrase(for: "a", count: 2))
        #expect(blank.text == "\(impostor) (\(tokens[1]))")
        #expect(labels.label(for: "b").discriminator == alias("b"))
        #expect(blank.text != labels.label(for: "b").text)
    }

    @Test func aGroundAliasMatchMakesBothLabelsGrowToTwoTokens() {
        #expect(alias(Self.groundX) == alias(Self.groundY))
        #expect(Alias.tokens(for: Self.groundX, count: 2)[1] != Alias.tokens(for: Self.groundY, count: 2)[1])
        let labels = index((Self.groundX, "Alice"), (Self.groundY, "Alice"))
        let labelX = labels.label(for: Self.groundX)
        let labelY = labels.label(for: Self.groundY)
        #expect(labelX.discriminator == Alias.phrase(for: Self.groundX, count: 2))
        #expect(labelY.discriminator == Alias.phrase(for: Self.groundY, count: 2))
        #expect(labelX.discriminator == labelX.alias, "what the person would quote")
        #expect(labelX.text != labelY.text)
    }

    @Test func aNameChosenToReadLikeAnotherPeersLabelIsStillDistinct() {
        let labels = index(("a", "Alice"), ("b", "Alice"), ("c", "Alice (\(alias("a")))"))
        #expect(Set(["a", "b", "c"].map { labels.label(for: $0).text }).count == 3)
        #expect(labels.label(for: "a").discriminator == Alias.phrase(for: "a", count: 2), "grew past the chosen name")
        #expect(labels.label(for: "b").discriminator == alias("b"))
        #expect(labels.label(for: "c").discriminator == alias("c"), "caught by the text pass alone")
    }

    @Test func anOutsideIdGrowsUntilItReadsApartFromTheUniverse() {
        let labels = index((Self.groundX, "Alice"), ("b", "Alice"))
        #expect(labels.label(for: Self.groundX).discriminator == alias(Self.groundX))
        let outsider = labels.label(for: Self.groundY, storedName: "Alice")
        #expect(outsider.discriminator == Alias.phrase(for: Self.groundY, count: 2))
        #expect(labels.label(for: Self.groundX).text != outsider.text)
        #expect(labels.label(for: Self.groundX).discriminator == alias(Self.groundX))
    }

    @Test func aMemberAskedUnderAnotherNameResolvesAgainstTheSnapshot() {
        let labels = index(("a", "Alice"), ("b", "Bob"))
        #expect(labels.label(for: "a", storedName: "Bob").discriminator == alias("a"))
        #expect(labels.label(for: "a", storedName: "Carol").discriminator == nil)
        #expect(labels.label(for: "a").discriminator == nil)
    }

    @Test func twoBlankNamedPeersWithOneAliasReadApartByTheirContinuations() {
        let labels = index((Self.groundX, ""), (Self.groundY, ""))
        let labelX = labels.label(for: Self.groundX)
        #expect(labelX.name == alias(Self.groundX))
        #expect(labelX.discriminator == Alias.tokens(for: Self.groundX, count: 2)[1])
        #expect(labelX.alias == Alias.phrase(for: Self.groundX, count: 2))
        #expect(labelX.text != labels.label(for: Self.groundY).text)
    }

    @Test func everyLabelInAUniverseIsDistinct() {
        let pool = ["Alice", "alice", "Bob", "Sam", "SAM", "Dani", "Theo", "Priya", "Jonas W.", "Lena F.", ""]
        // 2,000 peers is knit-next's sweep cap, the largest universe an index is built over.
        let peers = (0..<2000).map { (nodeId: "peer-\($0)", name: pool[$0 * 7 % pool.count]) }
        let labels = PeerLabelIndex(peers: peers, me: (nodeId: "me", name: "Alice"))
        let texts = (peers.map(\.nodeId) + ["me"]).map { labels.label(for: $0).text }
        #expect(Set(texts).count == texts.count)
    }

    @Test func theEmptyIndexDiscriminatesNothing() {
        #expect(PeerLabelIndex.empty.label(for: "a", storedName: "Alice").discriminator == nil)
        #expect(PeerLabelIndex.empty.label(for: "a", storedName: "Alice").text == "Alice")
    }

    // MARK: NameKey

    @Test func aNameKeyFoldsCaseAndTrims() {
        #expect(NameKey.of("Alice") == "alice")
        #expect(NameKey.of("  ALICE ") == "alice")
        #expect(NameKey.of("   ").isEmpty)
    }

    @Test func aNameKeyCollapsesWhitespaceRunsIncludingUnicodeSpaces() {
        #expect(NameKey.of("Alice \t  Smith") == "alice smith")
        #expect(NameKey.of("Alice\u{00A0}Smith") == "alice smith")
        #expect(NameKey.of("Alice\u{2003}Smith") == "alice smith")
        #expect(NameKey.of("Alice\u{3000}Smith") == "alice smith")
    }

    @Test func aNameKeyNormalizesCompatibilityForms() {
        #expect(NameKey.of("\u{FF21}\u{FF4C}\u{FF49}\u{FF43}\u{FF45}") == "alice")
        #expect(NameKey.of("\u{FB01}sh") == "fish")
        #expect(NameKey.of("e\u{0301}").unicodeScalars.map(\.value) == [0xE9])
    }

    @Test func aNameKeyStripsFormatCharacters() {
        for name in ["Al\u{200B}ice", "Al\u{200D}ice", "\u{202E}Alice", "\u{FEFF}Alice", "Alice\u{200E}"] {
            #expect(NameKey.of(name) == "alice")
        }
    }

    @Test func aNameKeyDoesNotFoldConfusables() {
        #expect(NameKey.of("alice") != NameKey.of("\u{0430}lice"), "a Cyrillic а stays apart, a recorded limit")
    }
}
