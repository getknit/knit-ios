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

    /// knit-next's `normalizeSingleLine`: trim with Kotlin's `trim()`, whose whitespace is Unicode-wide, then
    /// collapse each run of Java regex `\s` (ASCII whitespace only) to one space.
    public static func normalizeSingleLine(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isKotlinWhitespace($0) }),
            let last = scalars.lastIndex(where: { !isKotlinWhitespace($0) })
        else {
            return ""
        }
        var output = String.UnicodeScalarView()
        var inRun = false
        for scalar in scalars[first...last] {
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

    /// knit-next's `isValidReactionEmoji`: not blank, and within ``reaction`` UTF-16 code units.
    public static func isValidReaction(_ emoji: String) -> Bool {
        !isBlank(emoji) && emoji.utf16.count <= reaction
    }

    /// Kotlin's `isBlank()`: empty, or nothing but whitespace in Kotlin's Unicode-wide sense. A name that is
    /// blank shows the alias instead.
    public static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(isKotlinWhitespace)
    }

    /// Kotlin's `Char.isWhitespace` on the JVM: Java's `isWhitespace` or `isSpaceChar`, which together are the
    /// Unicode separators plus the ASCII controls `\t`–`\r` and `\u{1C}`–`\u{1F}`.
    static func isKotlinWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        if asciiControlWhitespace.contains(scalar.value) || informationSeparators.contains(scalar.value) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    /// Java's regex `\s` without `UNICODE_CHARACTER_CLASS`: `[ \t\n\x0B\f\r]`.
    static func isJavaRegexWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || asciiControlWhitespace.contains(scalar.value)
    }

    /// `\t`, `\n`, `\u{0B}`, `\f` and `\r`.
    private static let asciiControlWhitespace: ClosedRange<UInt32> = 0x09...0x0D
    /// The information separators `\u{1C}` to `\u{1F}`, which Java counts as whitespace.
    private static let informationSeparators: ClosedRange<UInt32> = 0x1C...0x1F
}
