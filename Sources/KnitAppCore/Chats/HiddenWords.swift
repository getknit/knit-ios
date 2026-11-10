import KnitStore

/// Why a thread keeps someone else's words out of sight while the content filter is on.
public enum HiddenWords: Sendable, Equatable {
    /// The filter flagged them, and a tap shows them.
    case flagged
    /// The filter has not read them yet, which takes a moment after they land; they show, or stay hidden, once it has.
    case unscreened

    /// Why `message`'s words are hidden, given that they are: unscreened while the filter has yet to read its words or
    /// its quote's, so a tap shows neither, and flagged once it has read both (knit-next ADR 2026-10.gpa3).
    init(_ message: MessageRecord) {
        self = message.moderation == .waiting || message.quoteModeration == .waiting ? .unscreened : .flagged
    }
}
