import Foundation

/// The collision key of a display name (`NameKey` in knit-next's `PeerLabels.kt`, knit-next #228). Two names with
/// one key both show their alias discriminator, so the key folds generously: a collision only costs a suffix.
/// "Alice", "ALICE", "Ａlice", "Al\u{200B}ice", "Al\u{0456}ce" (a Cyrillic і) and "AIice" (a capital I) are one name, `aiice`.
///
/// The key is never stored, sent or compared between devices. Each port keeps the same rule so a pair draws the same
/// discriminators, and `vectors/name-key-v1.json` pins it.
public enum NameKey {
    /// The key of `name`, in the contract's five steps:
    ///
    /// 1. NFKC.
    /// 2. Each code point in ``lookalikes`` becomes its ASCII letter, on the case-preserved string, since UTS #39 is
    ///    case-sensitive: a Cyrillic `В` looks like `B`, but a `в` doesn't look like `b`.
    /// 3. Lower-cased, then U+03C2 ς folded to U+03C3 σ, so Java's Final_Sigma and Swift's lack of it agree, then `l`
    ///    folded to `i` (contract revision 3). Step 2 makes a capital I an `l`, so without this "ALICE" would key apart
    ///    from "Alice"; with it, I, i, l and their lookalikes are one letter, at the cost of a suffix between "Eli" and
    ///    "Ell".
    /// 4. Every format, non-spacing or enclosing mark dropped, and every code point in ``dropped``. This runs after
    ///    lower-casing, so the U+0307 that `İ` lowers to goes too.
    /// 5. Runs of Java regex `\s` collapsed, then the ends trimmed (`PeerLabels.kt:270-272`): the reverse of
    ///    `normalizeSingleLine`, so a U+0085 at an end, which `trim()` keeps but `\s` takes, goes with its run.
    public static func of(_ name: String) -> String {
        var folded = String.UnicodeScalarView()
        folded.append(contentsOf: name.precomposedStringWithCompatibilityMapping.unicodeScalars.map { lookalikes[$0] ?? $0 })
        var kept = String.UnicodeScalarView()
        for scalar in String(folded).lowercased().unicodeScalars where !isDropped(scalar) {
            kept.append(lowered[scalar] ?? scalar)
        }
        return TextLimits.trimmed(TextLimits.collapsingWhitespaceRuns(String(kept)))
    }

    /// Whether a person or group shows its alias, or its member-derived title, in place of `name`: no name, or one
    /// whose key is empty, such as U+3164 or U+2800 alone. It decides display only. What a group frame carries still
    /// follows ``TextLimits/isBlank(_:)``, as Kotlin's `isBlank` does on Android.
    public static func isBlankName(_ name: String?) -> Bool {
        name.map { of($0).isEmpty } ?? true
    }

    /// Step 3's folds after lower-casing: the final sigma, and `l`, which every I, i and l lookalike has become.
    static let lowered: [Unicode.Scalar: Unicode.Scalar] = ["\u{03C2}": "\u{03C3}", "l": "i"]

    /// Whether step 4 drops `scalar`. Mn, Me and Cf come from this platform's Unicode tables; the rest are literal.
    static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .format, .nonspacingMark, .enclosingMark:
            return true
        default:
            return dropped.contains { $0.contains(scalar) }
        }
    }

    /// Unicode 15.1's Default_Ignorable_Code_Point (`DerivedCoreProperties.txt`) and U+2800 BRAILLE PATTERN BLANK, as
    /// literal ranges, so a newer Unicode table here can't move them away from Android's (ADR 2026-10.7uyt's reasoning).
    /// Several are Cf or Mn already. The ones that aren't, such as the Hangul fillers and U+2800, render as nothing.
    static let dropped: [ClosedRange<Unicode.Scalar>] = [
        "\u{00AD}"..."\u{00AD}", "\u{034F}"..."\u{034F}", "\u{061C}"..."\u{061C}", "\u{115F}"..."\u{1160}",
        "\u{17B4}"..."\u{17B5}", "\u{180B}"..."\u{180F}", "\u{200B}"..."\u{200F}", "\u{202A}"..."\u{202E}",
        "\u{2060}"..."\u{206F}", "\u{2800}"..."\u{2800}", "\u{3164}"..."\u{3164}", "\u{FE00}"..."\u{FE0F}",
        "\u{FEFF}"..."\u{FEFF}", "\u{FFA0}"..."\u{FFA0}", "\u{FFF0}"..."\u{FFF8}", "\u{1BCA0}"..."\u{1BCA3}",
        "\u{1D173}"..."\u{1D17A}", "\u{E0000}"..."\u{E0FFF}",
    ]

    /// Every UTS #39 15.1.0 `confusables.txt` entry (sha256 `8289f833…69fd5ed`) whose source is one Latin U+0041–U+007A,
    /// Greek U+0370–U+03FF or Cyrillic U+0400–U+052F code point and whose prototype is one ASCII letter: 73 entries,
    /// literal on both platforms and never derived at run time. U+0049 → `l` is UTS #39's own Latin capital I.
    static let lookalikes: [Unicode.Scalar: Unicode.Scalar] = [
        "\u{0391}": "A", "\u{0410}": "A",
        "\u{03B1}": "a", "\u{0430}": "a",
        "\u{0392}": "B", "\u{0412}": "B",
        "\u{042C}": "b",
        "\u{03F9}": "C", "\u{0421}": "C",
        "\u{03F2}": "c", "\u{0441}": "c",
        "\u{0501}": "d",
        "\u{0395}": "E", "\u{0415}": "E",
        "\u{0435}": "e", "\u{04BD}": "e",
        "\u{03DC}": "F",
        "\u{050C}": "G",
        "\u{0397}": "H", "\u{041D}": "H",
        "\u{04BB}": "h",
        "\u{037A}": "i", "\u{03B9}": "i", "\u{0456}": "i", "\u{04CF}": "i",
        "\u{037F}": "J", "\u{0408}": "J",
        "\u{03F3}": "j", "\u{0458}": "j",
        "\u{039A}": "K", "\u{041A}": "K",
        "\u{0049}": "l", "\u{0399}": "l", "\u{0406}": "l", "\u{04C0}": "l",
        "\u{039C}": "M", "\u{03FA}": "M", "\u{041C}": "M",
        "\u{039D}": "N",
        "\u{039F}": "O", "\u{041E}": "O",
        "\u{03BF}": "o", "\u{03C3}": "o", "\u{043E}": "o",
        "\u{03A1}": "P", "\u{0420}": "P",
        "\u{03C1}": "p", "\u{03F1}": "p", "\u{0440}": "p",
        "\u{051B}": "q",
        "\u{0433}": "r",
        "\u{0405}": "S",
        "\u{0455}": "s",
        "\u{03A4}": "T", "\u{0422}": "T",
        "\u{03C5}": "u",
        "\u{0474}": "V",
        "\u{03BD}": "v", "\u{0475}": "v",
        "\u{051C}": "W",
        "\u{0461}": "w", "\u{051D}": "w",
        "\u{03A7}": "X", "\u{0425}": "X",
        "\u{0445}": "x",
        "\u{03A5}": "Y", "\u{03D2}": "Y", "\u{0423}": "Y", "\u{04AE}": "Y",
        "\u{03B3}": "y", "\u{0443}": "y", "\u{04AF}": "y",
        "\u{0396}": "Z",
    ]
}
