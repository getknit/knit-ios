import Testing

@testable import KnitWire

/// The collision key of a display name, ported from knit-next's `NameKeyTest`, with the lookalike fold and the wider
/// drop set of knit-next #228.
@Suite struct NameKeyTests {
    @Test func aNameKeyFoldsCaseAndTrims() {
        #expect(NameKey.of("Bob") == "bob")
        #expect(NameKey.of("  BOB ") == "bob")
        #expect(NameKey.of("   ").isEmpty)
    }

    @Test func aNameKeyCollapsesWhitespaceRunsIncludingUnicodeSpaces() {
        #expect(NameKey.of("Bob \t  Smith") == "bob smith")
        #expect(NameKey.of("Bob\u{00A0}Smith") == "bob smith")
        #expect(NameKey.of("Bob\u{2003}Smith") == "bob smith")
        #expect(NameKey.of("Bob\u{3000}Smith") == "bob smith")
    }

    /// `PeerLabels.kt:270-272` on ART: `\s` is Unicode White_Space, and runs collapse before `trim()`, so a U+0085 at an
    /// end goes with its run though `trim()` alone would keep it.
    @Test(arguments: ["\u{0085}", "\u{1680}", "\u{2028}", "\u{2029}"])
    func aNameKeyFoldsTheSpacesARTMatches(space: String) {
        #expect(NameKey.of("Ana\(space)Bell") == "ana beii", "ArtTextSemanticsTest's pin, its l folded to i")
        #expect(NameKey.of("Bob\(space)Smith") == "bob smith")
        #expect(NameKey.of("\(space)Bob\(space)") == "bob")
        #expect(NameKey.of(" \(space)Bob\(space) ") == "bob")
    }

    @Test func aNameKeyNormalizesCompatibilityForms() {
        #expect(NameKey.of("\u{FF21}\u{FF4C}\u{FF49}\u{FF43}\u{FF45}") == "aiice")
        #expect(NameKey.of("\u{FB01}sh") == "fish")
        #expect(NameKey.of("e\u{0301}").unicodeScalars.map(\.value) == [0xE9])
    }

    @Test func aNameKeyStripsFormatCharacters() {
        for name in ["Al\u{200B}ice", "Al\u{200D}ice", "\u{202E}Alice", "\u{FEFF}Alice", "Alice\u{200E}"] {
            #expect(NameKey.of(name) == "aiice")
        }
    }

    /// The contract's lookalikes: a Cyrillic or Greek letter, an invisible mark, Braille's blank, a capital I. All key as
    /// "Alice" and "ALICE" do, with I, i and l one letter (contract revision 3).
    @Test(arguments: [
        "Alic\u{0435}", "Alice\u{FE0F}", "Al\u{034F}ice", "Alice\u{2800}", "AIice", "Al\u{0456}ce", "\u{0410}lice",
        "\u{0391}lice", "Al\u{20DD}ice", "Alice", "ALICE", "alice",
    ])
    func aLookalikeFoldsToTheLatinName(name: String) {
        #expect(NameKey.of(name) == "aiice")
    }

    /// Revision 3's pins: a capital I and an l key as an i, so an all-caps name keys with its mixed-case form, and two
    /// names that differ only by i and l share a key.
    @Test func iAndLAreOneLetter() {
        #expect(NameKey.of("KIM") == "kim" && NameKey.of("Kim") == "kim")
        #expect(NameKey.of("LIAM") == "iiam" && NameKey.of("Liam") == "iiam")
        #expect(Set(["Ian", "IAN", "lan"].map(NameKey.of)) == ["ian"])
        #expect(NameKey.of("Eli") == "eii" && NameKey.of("Ell") == "eii")
    }

    /// The fold runs on the case-preserved string, as UTS #39 does: a Cyrillic capital В is a B, a small в is not a b.
    @Test func theFoldIsCaseSensitive() {
        #expect(NameKey.of("\u{0412}\u{043E}b") == "bob")
        #expect(NameKey.of("\u{0432}ob") == "\u{0432}ob")
    }

    /// NFKC composes every mark with a precomposed form first, so an accent stays and keeps its own key. Only a mark left
    /// over, such as the U+0307 that lowering `İ` makes, is dropped.
    @Test func aComposedAccentKeepsItsKey() {
        #expect(NameKey.of("Nguy\u{1EC5}n") == "nguy\u{1EC5}n")
        #expect(NameKey.of("Nguye\u{0302}\u{0303}n") == "nguy\u{1EC5}n")
        #expect(NameKey.of("Ren\u{00E9}e") == "ren\u{00E9}e")
        #expect(NameKey.of("Ren\u{00E9}e") != NameKey.of("Renee"))
        #expect(NameKey.of("\u{0130}") == "i")
    }

    /// Java lowers a word-final Σ to ς and Swift may not; step 3 folds ς to σ, so the two agree.
    @Test func aFinalSigmaFoldsToSigma() {
        let key = NameKey.of("\u{03A3}\u{0391}\u{03A3}")
        #expect(!key.unicodeScalars.contains("\u{03C2}"))
        #expect(key == "\u{03C3}a\u{03C3}")
        #expect(NameKey.of("\u{03C3}\u{03C2}") == "o\u{03C3}", "a small σ typed as such is the o lookalike")
    }

    @Test(arguments: ["", "\u{2800}\u{2800}", "\u{3164}", "\u{115F}\u{1160}", "\u{FFA0}", "\u{FE0F}", "\u{E0041}", "\u{1D173}"])
    func anInvisibleNameHasAnEmptyKeyAndIsDisplayBlank(name: String) {
        #expect(NameKey.of(name).isEmpty)
        #expect(NameKey.isBlankName(name))
    }

    @Test func blankForDisplayIsWiderThanBlankOnTheWire() {
        #expect(NameKey.isBlankName(nil))
        #expect(NameKey.isBlankName(" \u{3164} "))
        #expect(!TextLimits.isBlank("\u{3164}"), "still a name on the wire")
        #expect(!NameKey.isBlankName("Bob"))
        #expect(!NameKey.isBlankName("\u{0001}"), "a control has a key; cleaning removes it")
    }

    /// The fold table is the contract's: 73 entries, every source in Latin, Greek or Cyrillic, every target ASCII.
    @Test func theFoldTableHasTheContractsShape() {
        #expect(NameKey.lookalikes.count == 73)
        for (source, target) in NameKey.lookalikes {
            #expect([0x41...0x7A, 0x370...0x3FF, 0x400...0x52F].contains { $0.contains(source.value) })
            #expect(target.isASCII && target.properties.isAlphabetic)
        }
    }
}
