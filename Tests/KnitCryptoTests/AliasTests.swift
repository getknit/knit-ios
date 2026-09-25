import Crypto
import KnitCrypto
import Testing

/// Aliases, ported from knit-next's `AliasTest`. The goldens there were computed from the salt and the lists in
/// Python, not from the Kotlin code.
@Suite struct AliasTests {
    @Test(arguments: [
        ("node123", "OptimallyArtfulFox"),
        ("k3p9xq2a", "ThriftilyWoollyOriole"),
        ("aaaaaaaa", "MindfullyZealousZircon"),
        ("zzzzzzzz", "EquallyQuaintMeerkat"),
    ])
    func aliasesMatchKnitNext(nodeId: String, alias: String) {
        #expect(Alias.alias(for: nodeId) == alias)
    }

    @Test func theFullPhraseMatchesKnitNext() {
        #expect(
            Alias.phrase(for: "node123", count: Alias.maxTokens)
                == "OptimallyArtfulFox AdeptlyPleasantMaple DecidedlyMildDune ArdentlyWonderfulBeacon WittilyCleverAtoll "
                + "QuietlyGallantTurtle HugelyGentleOriole LucidlySereneGarnet UtterlyUpbeatRidge BoldlyPolishedWren"
        )
    }

    /// `wordListFingerprintIsFrozen`: the three lists, newline-joined with a trailing newline, hash to knit-next's
    /// pinned value. `scripts/sync-vectors.py --check` catches drift at the source; this catches a hand edit.
    @Test func theWordListsMatchKnitNextsFingerprint() {
        let text = (AliasWords.adverbs + AliasWords.adjectives + AliasWords.nouns).joined(separator: "\n") + "\n"
        let digest = SHA256.hash(data: Array(text.utf8)).map { String($0, radix: 16).leftPadded(to: 2) }.joined()
        #expect(digest == "3d36fd522087180cef0ccaab6b6f3cc6f28aaf8a72816c44bcc9b778240164ed")
    }

    @Test func eachListIs256SortedUniqueCapitalizedWords() {
        for list in [AliasWords.adverbs, AliasWords.adjectives, AliasWords.nouns] {
            #expect(list.count == 256)
            #expect(Set(list).count == 256)
            #expect(list == list.sorted())
            let shaped = list.allSatisfy(\.isAliasWord)
            #expect(shaped)
        }
        #expect(Set(AliasWords.adverbs).isDisjoint(with: AliasWords.adjectives))
        #expect(Set(AliasWords.adverbs).isDisjoint(with: AliasWords.nouns))
        #expect(Set(AliasWords.adjectives).isDisjoint(with: AliasWords.nouns))
    }

    /// `tokensAreByteExact`: byte `3t` picks the adverb, `3t + 1` the adjective and `3t + 2` the noun.
    @Test func tokensAreByteExact() {
        let digest = Array(SHA256.hash(data: Array("knit-alias-v2:node123".utf8)))
        let tokens = Alias.tokens(for: "node123")
        #expect(tokens.count == Alias.maxTokens)
        for (index, token) in tokens.enumerated() {
            let expected =
                AliasWords.adverbs[Int(digest[3 * index])] + AliasWords.adjectives[Int(digest[3 * index + 1])]
                + AliasWords.nouns[Int(digest[3 * index + 2])]
            #expect(token == expected)
        }
    }

    @Test func eachPhraseExtendsTheShorterOne() {
        for seed in 0..<20 {
            let id = "id-\(seed)"
            #expect(Alias.phrase(for: id, count: 1) == Alias.alias(for: id))
            for count in 1..<Alias.maxTokens {
                let shorter = Alias.phrase(for: id, count: count)
                let longer = Alias.phrase(for: id, count: count + 1)
                #expect(longer.hasPrefix(shorter + " "))
                #expect(longer.split(separator: " ").count == count + 1)
            }
            #expect(Alias.tokens(for: id, count: 4) == Array(Alias.tokens(for: id).prefix(4)))
        }
    }

    @Test func aliasesSpreadAndNeverEchoTheId() {
        let ids = (0..<3000).map { "node-\($0)" }
        let aliases = Set(ids.map(Alias.alias(for:)))
        #expect(aliases.count > ids.count * 2 / 3)
        #expect(ids.allSatisfy { Alias.alias(for: $0) != $0 })
    }

    @Test func aDisplayNameFallsBackToTheAliasOnlyWhenBlank() {
        let alias = Alias.alias(for: "node123")
        #expect(Alias.displayName(stored: nil, nodeId: "node123") == alias)
        #expect(Alias.displayName(stored: "", nodeId: "node123") == alias)
        #expect(Alias.displayName(stored: "   ", nodeId: "node123") == alias)
        #expect(Alias.displayName(stored: "Alice", nodeId: "node123") == "Alice")
    }
}

extension String {
    /// `^[A-Z][a-z]{2,9}$`, the shape `AliasTest` requires of every word.
    var isAliasWord: Bool {
        let scalars = Array(unicodeScalars)
        guard (3...10).contains(scalars.count), let first = scalars.first, ("A"..."Z").contains(first) else {
            return false
        }
        return scalars.dropFirst().allSatisfy { ("a"..."z").contains($0) }
    }

    func leftPadded(to width: Int) -> String {
        String(repeating: "0", count: max(0, width - count)) + self
    }
}
