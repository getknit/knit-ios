import KnitWire

/// What the composer lets through (`ChatViewModel.send` in knit-next): a message is trimmed at its ends and at most
/// ``TextLimits/message`` UTF-16 units, which is what Android counts. A blank one is not a message.
public enum Composer {
    /// How near the limit the composer starts saying what is left.
    public static let warnWithin = 100

    /// The body `draft` sends, or `nil` when it is blank.
    public static func body(of draft: String) -> String? {
        let body = TextLimits.truncated(trimmed(draft), toUTF16: TextLimits.message)
        return TextLimits.isBlank(body) ? nil : body
    }

    /// `draft` cut to the limit, so the field refuses the overflow instead of sending less than it shows.
    public static func clamp(_ draft: String) -> String {
        TextLimits.truncated(draft, toUTF16: TextLimits.message)
    }

    /// The UTF-16 units `draft` has left, once it is within ``warnWithin`` of the limit.
    public static func remaining(_ draft: String) -> Int? {
        let left = TextLimits.message - draft.utf16.count
        return left <= warnWithin ? max(left, 0) : nil
    }

    /// A single-line field's text as it is saved: normalized like every name and status, and cut to `limit`.
    public static func singleLine(_ text: String, limit: Int) -> String {
        TextLimits.truncated(TextLimits.normalizeSingleLine(text), toUTF16: limit)
    }

    /// Kotlin's `trim()`: whitespace in Kotlin's sense off both ends, the inside untouched.
    static func trimmed(_ text: String) -> String {
        TextLimits.trimmed(text)
    }
}
