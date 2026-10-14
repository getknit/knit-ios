/// Length limits and normalization for user text (`TextLimits.kt` in knit-next).
///
/// Every limit counts UTF-16 code units, because that is what Kotlin's `String.length` counts. Counting Swift
/// `Character`s instead would let an iPhone send a name Android truncates differently.
public enum TextLimits {
    /// A display name.
    public static let displayName = 32
    /// A status line.
    public static let status = 100
    /// A group name.
    public static let groupName = 32
    /// A message body.
    public static let message = 2000
    /// A reaction.
    public static let reaction = 32

    /// knit-next's `normalizeSingleLine` (`TextLimits.kt:47`): `trim()`, then each run of Java regex `\s` collapsed to
    /// one space. On ART both sets are Unicode-wide, and they differ: see ``isKotlinWhitespace(_:)`` and
    /// ``isJavaRegexWhitespace(_:)`` (ADR 2026-10.7uyt).
    public static func normalizeSingleLine(_ text: String) -> String {
        collapsingWhitespaceRuns(trimmed(text))
    }

    /// Kotlin's `trim()`: ``isKotlinWhitespace(_:)`` off both ends, the inside untouched.
    public static func trimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isKotlinWhitespace($0) }),
            let last = scalars.lastIndex(where: { !isKotlinWhitespace($0) })
        else {
            return ""
        }
        return String(scalars[first...last])
    }

    /// Kotlin's `replace(Regex("\\s+"), " ")`: each run of ``isJavaRegexWhitespace(_:)`` becomes one space.
    public static func collapsingWhitespaceRuns(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var inRun = false
        for scalar in text.unicodeScalars {
            if isJavaRegexWhitespace(scalar) {
                if !inRun {
                    output.append(" ")
                }
                inRun = true
            } else {
                output.append(scalar)
                inRun = false
            }
        }
        return String(output)
    }

    /// The longest prefix of `text` within `limit` UTF-16 code units. Kotlin's `take` can split a surrogate
    /// pair; this stops before one, which only differs on a name that ends mid-emoji.
    public static func truncated(_ text: String, toUTF16 limit: Int) -> String {
        guard text.utf16.count > limit else {
            return text
        }
        var units = 0
        var output = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            units += UTF16.width(scalar)
            guard units <= limit else {
                break
            }
            output.append(scalar)
        }
        return String(output)
    }

    /// Kotlin's `indexOf(other, startIndex)`: the first UTF-16 offset at or after `start` where `needle`'s code units
    /// occur in `text`'s, or `nil`. Kotlin compares code units. Swift's `String.contains` compares characters up to
    /// canonical equivalence, so it misses an "@Ann" followed by a combining accent, which Kotlin finds.
    public static func utf16Index(of needle: [UInt16], in text: [UInt16], from start: Int = 0) -> Int? {
        guard !needle.isEmpty, start >= 0, text.count - needle.count >= start else {
            return nil
        }
        return (start...(text.count - needle.count)).first { offset in
            text[offset..<(offset + needle.count)].elementsEqual(needle)
        }
    }

    /// The name a rename sends (`GroupDetailsViewModel.kt:158-159`): normalized to one line and cut to ``groupName``
    /// units, or `nil` when that leaves nothing, since a group name is never cleared.
    public static func outgoingGroupName(_ text: String) -> String? {
        let name = truncated(normalizeSingleLine(text), toUTF16: groupName)
        return isBlank(name) ? nil : name
    }

    /// The name a group frame carries, as a receiver takes it (`InboundPipeline.kt:2042`): `nil` when absent or blank,
    /// which never clears a name, and otherwise cut to ``groupName`` units without normalizing.
    public static func incomingGroupName(_ text: String?) -> String? {
        guard let text, !isBlank(text) else {
            return nil
        }
        return truncated(text, toUTF16: groupName)
    }

    /// knit-next's `isValidReactionEmoji`: not blank, and within ``reaction`` UTF-16 code units.
    public static func isValidReaction(_ emoji: String) -> Bool {
        !isBlank(emoji) && emoji.utf16.count <= reaction
    }

    /// Whether this port takes `emoji` as a reaction: knit-next's rule, and one emoji besides (``isSingleEmoji(_:)``).
    /// Android takes any short text, but its picker only ever sends an emoji, so the extra rule refuses only words a
    /// modified build might send, which a chip would otherwise show to everyone in the thread.
    public static func isAcceptedReaction(_ emoji: String) -> Bool {
        isValidReaction(emoji) && isSingleEmoji(emoji)
    }

    /// Whether `text` is one emoji: a single grapheme cluster whose first scalar shows as an emoji by default, or one
    /// that a variation selector, a keycap, a skin tone or a joiner makes into one, such as ❤️ or 1️⃣. A first scalar
    /// the standard library's Unicode tables do not know yet passes when it lies in the emoji planes, so an emoji newer
    /// than this build, from Android's picker, is not refused. A bare digit, letter or symbol that defaults to text
    /// does not pass.
    public static func isSingleEmoji(_ text: String) -> Bool {
        guard text.count == 1, let first = text.unicodeScalars.first else {
            return false
        }
        let properties = first.properties
        if properties.isEmojiPresentation {
            return true
        }
        if properties.isEmoji, text.unicodeScalars.count > 1 {
            return true
        }
        return properties.generalCategory == .unassigned && emojiPlanes.contains(first.value)
    }

    /// The blocks where new emoji are assigned: Mahjong Tiles through Symbols and Pictographs Extended-A.
    private static let emojiPlanes: ClosedRange<UInt32> = 0x1F000...0x1FAFF

    /// Kotlin's `isBlank()`: empty, or nothing but whitespace in Kotlin's Unicode-wide sense. A name that is
    /// blank shows the alias instead.
    public static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(isKotlinWhitespace)
    }

    /// Kotlin's `Char.isWhitespace` on ART: Java's `isWhitespace` or `isSpaceChar`, which take `\u{1C}`–`\u{1F}` but not
    /// U+0085. Pinned to the set knit-next's `ArtTextSemanticsTest` reads on ART. U+180E is not whitespace, as on ART
    /// from API 37's mainline module; an older module still counts it, a residue ADR 2026-10.7uyt accepts. No code point
    /// above the BMP is whitespace. Public for the composer, whose mention query stops where Android's does
    /// (`activeMentionQuery`, `MentionText.kt`).
    public static func isKotlinWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\u{09}"..."\u{0D}", "\u{1C}"..."\u{20}", "\u{A0}", "\u{1680}", "\u{2000}"..."\u{200A}", "\u{2028}",
            "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}":
            true
        default:
            false
        }
    }

    /// Java's regex `\s` on ART, where `java.util.regex` is ICU and `\s` is Unicode White_Space (android-36.1
    /// `Pattern.java:178-179`), not the desktop JDK's ASCII `[ \t\n\x0B\f\r]`. It takes U+0085, which Kotlin's
    /// `isWhitespace` does not, and leaves out `\u{1C}`–`\u{1F}`, which it takes. Pinned to the set knit-next's
    /// `ArtTextSemanticsTest` reads on ART.
    static func isJavaRegexWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\u{09}"..."\u{0D}", "\u{20}", "\u{85}", "\u{A0}", "\u{1680}", "\u{2000}"..."\u{200A}", "\u{2028}", "\u{2029}",
            "\u{202F}", "\u{205F}", "\u{3000}":
            true
        default:
            false
        }
    }
}
