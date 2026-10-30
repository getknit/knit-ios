import KnitWire

/// How far a received quote was checked against the original it names (`MessageEntity.replyCheck`, knit-next ADR
/// 2026-10.gpa3): not yet, because the original is not held; held and matching; or held and not what the quote claims.
///
/// The codes are knit-next's (`REPLY_UNCHECKED`, `REPLY_VERIFIED`, `REPLY_MISMATCH`, `MessageEntity.kt:315-321` at
/// `7439fd9cc`), so the two stores read alike, and none leaves this phone. A code this build does not know reads as
/// unchecked, as `quoteViewFor` reads one.
public struct QuoteCheck: RawRepresentable, Hashable, Sendable, ExpressibleByIntegerLiteral {
    /// The original is not held, so the quote is the sender's word for it.
    public static let unchecked: Self = 0
    /// The original is held, in the reply's thread, under the author the quote names; the quote was rebuilt from it.
    public static let verified: Self = 1
    /// A held message answers to the quoted id but not to its author, its thread or its kind; nothing of the claim is kept.
    public static let mismatch: Self = 2

    /// The stored code.
    public let rawValue: Int

    /// Wraps a stored code, known or not.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A code written out, for the registry above.
    public init(integerLiteral value: Int) {
        self.init(rawValue: value)
    }
}

/// What a reply's quote columns become once its original has been judged (`QuoteSettlement`, `QuoteCheck.kt:114-119`).
public struct QuoteSettlement: Sendable, Equatable {
    /// The verdict.
    public var check: QuoteCheck
    /// The words, rebuilt from the original when it matched, and empty when it did not.
    public var snippet: String
    /// Whether the original carried a photo or a file, from the original itself.
    public var hasAttachment: Bool
    /// The original's own verdict on its words, never one it inherited from a quote of its own.
    public var moderation: MessageModeration

    /// A settlement.
    public init(check: QuoteCheck, snippet: String, hasAttachment: Bool, moderation: MessageModeration) {
        self.check = check
        self.snippet = snippet
        self.hasAttachment = hasAttachment
        self.moderation = moderation
    }

    /// What a mismatch keeps of the claim: nothing.
    public static let mismatch = Self(check: .mismatch, snippet: "", hasAttachment: false, moderation: .clear)
}

extension MessageReply {
    /// Whether `original` is the message `reply` quotes, as this phone holds it (`quoteVerdict`, `QuoteCheck.kt:104-111`).
    /// A frame id is random and bound to nobody, so the id alone proves nothing: the original must sit in the reply's own
    /// thread, under the author the quote names, be somebody's words and not be the reply itself. Ids and threads compare
    /// by their bytes (ADR 2026-09.jc2x).
    ///
    /// Somebody's words is an ordinary message. A status line is not: its sender column names whom the event is about.
    /// Android also leaves out a heard Meshtastic post, whose sender column is the phone by convention; this port has no
    /// such row, so a status line is the only one left out.
    public static func verdict(of reply: MessageRecord, against original: MessageRecord) -> QuoteCheck {
        guard let quote = reply.replyTo else {
            return .mismatch
        }
        let somebodysWords = !original.kind.isNotice
        let named =
            ExactKey(original.conversationId) == ExactKey(reply.conversationId)
            && ExactKey(original.senderId.string) == ExactKey(quote.authorId)
        return somebodysWords && named && ExactKey(original.id) != ExactKey(reply.id) ? .verified : .mismatch
    }

    /// The quote `reply` shows once `original` is judged (`settleQuote`, `QuoteCheck.kt:128-155`). A verified quote is
    /// rebuilt from the original by the composer's own rule (``quoting(_:authorName:hidesWords:attachmentLabel:)``, with
    /// nothing hidden), so the composer and the receiver cannot drift, and `attachmentLabel` names a GIF, a file or a voice
    /// note in the reader's language. It carries the original's own verdict on its words, so a reply to a reply hidden only
    /// for its quote is not hidden too. A mismatch keeps nothing of the claim.
    public static func settlement(
        of reply: MessageRecord, against original: MessageRecord, attachmentLabel: (MessageAttachment) -> String?
    ) -> QuoteSettlement {
        guard verdict(of: reply, against: original) == .verified else {
            return .mismatch
        }
        let rebuilt = quoting(original, authorName: "", hidesWords: false, attachmentLabel: original.attachment.flatMap(attachmentLabel))
        return QuoteSettlement(
            check: .verified, snippet: rebuilt.snippet, hasAttachment: rebuilt.hasAttachment, moderation: original.moderation.ofQuote)
    }
}

extension MessageModeration {
    /// What this verdict on an original makes of a quote of it: flagged, still waiting, or clear, a code this build does
    /// not know included, which reads as clear (`replyToFlagged = original.moderation == MODERATION_TEXT_FLAGGED`).
    public var ofQuote: Self {
        self == .flagged || self == .waiting ? self : .clear
    }
}

extension MessageRecord {
    /// This row with `settlement` written into its quote's columns (`settledWith`, `QuoteCheck.kt:158-165`). A row that
    /// quotes nothing is left as it is.
    public func settled(with settlement: QuoteSettlement) -> Self {
        guard var quote = replyTo else {
            return self
        }
        var settled = self
        quote.snippet = settlement.snippet
        quote.hasAttachment = settlement.hasAttachment
        settled.replyTo = quote
        settled.replyCheck = settlement.check
        settled.quoteModeration = settlement.moderation
        return settled
    }

    /// Whether the content filter's verdict on a reply's quote is one this phone still has to screen: the sender's words,
    /// unchecked against an original, and not yet read. A verified quote waits on its original's screen instead.
    public var quoteAwaitsScreening: Bool {
        replyTo != nil && replyCheck == .unchecked && quoteModeration == .waiting
    }
}
