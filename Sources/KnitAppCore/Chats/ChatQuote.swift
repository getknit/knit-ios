public import KnitStore
public import KnitWire

/// How far a quote shown in a thread was checked against the original it names (`QuoteState`, `ChatViewModel.kt:159`,
/// knit-next ADR 2026-10.gpa3).
public enum QuoteState: Sendable, Equatable {
    /// Rebuilt from the original this phone held, or one of our own replies.
    case verified
    /// The original is not on this phone, so the quote is the sender's word for it, and says so.
    case unverified
    /// It names a message that is not what the quote claims (another author, another thread, a status line), or one of
    /// ours this phone does not hold, which it would if it were ours: nothing of the claim shows.
    case unavailable

    /// How far the quote of `reply` was checked, read by `me` (`quoteViewFor`, `ChatViewModel.kt:212-237`). Our own
    /// replies are trusted: we quoted a row we held. A quote of our own id that never matched is unavailable rather than
    /// unverified, because this phone holds everything it sent, so its original was deleted, swept, or never ours. A
    /// check this build does not know reads as unchecked, as on Android.
    public init(_ reply: MessageRecord, me: NodeId) {
        let authorId = reply.replyTo?.authorId ?? ""
        if reply.senderId == me || reply.replyCheck == .verified {
            self = .verified
        } else if reply.replyCheck == .mismatch || ExactKey(authorId) == ExactKey(me.string) || TextLimits.isBlank(authorId) {
            self = .unavailable
        } else {
            self = .unverified
        }
    }
}

/// The message a reply quotes, as a thread shows it above the reply's words (`QuotedMessage` in knit-next's
/// `ChatScreen.kt`, ADR 2026-10.mn29). It draws from the reply's stored quote: rebuilt from the original once that was
/// held and matched, else the replier's words, marked unverified (knit-next ADR 2026-10.gpa3).
public struct ChatQuote: Sendable, Equatable {
    /// The quoted message's frame id, which a tap takes the thread to.
    public var messageId: String
    /// Who wrote it, by this iPhone's own label for the quoted author's id: "You" for us, a contact's name, else the alias.
    /// Never the name the replier wrote, and empty when the quote is ``QuoteState/unavailable``.
    public var author: String
    /// What it said: the quote's words, the photo's label for a quoted photo with no words, the words for a blocked
    /// author's hidden quote, or what stands in for an unavailable one; `nil` when there is nothing to show beside the
    /// author.
    public var line: String?
    /// Whether its author is blocked here, so its words stay out of sight as theirs do everywhere (ADR 2026-10.5wgg).
    public var blocked: Bool
    /// Whether the original shows in this thread and the quote was verified against it, so a tap can take the thread to
    /// it. A quote of a message never held, deleted, written by someone blocked, or not what the quote claims is no
    /// button.
    public var jumps: Bool
    /// How far it was checked.
    public var state: QuoteState

    /// A quote as it is shown.
    public init(
        messageId: String, author: String, line: String?, blocked: Bool = false, jumps: Bool = false, state: QuoteState = .verified
    ) {
        self.messageId = messageId
        self.author = author
        self.line = line
        self.blocked = blocked
        self.jumps = jumps
        self.state = state
    }

    /// `reply`, checked as far as `state` says, as a thread over `directory` shows it to `me`, among the messages `shown`
    /// there.
    init(_ reply: MessageReply, state: QuoteState, me: NodeId, directory: Directory, shown: Set<ExactKey>) {
        guard state != .unavailable else {
            self.init(messageId: reply.messageId, author: "", line: Copy.Replies.unavailableQuote, state: state)
            return
        }
        let quoted = NodeId(reply.authorId)
        let hidden = quoted.map(directory.blocked.contains) ?? false
        self.init(
            messageId: reply.messageId,
            author: ExactKey(reply.authorId) == ExactKey(me.string) ? Copy.Common.you : directory.labels.label(for: reply.authorId).text,
            line: hidden ? Copy.Replies.blockedQuote : Self.line(of: reply),
            blocked: hidden,
            jumps: state == .verified && !hidden && shown.contains(ExactKey(reply.messageId)),
            state: state
        )
    }

    /// The quote `reply` carries, checked as far as its row says, as a thread over `directory` shows it to `me`, among the
    /// messages `shown` there; `nil` when it quotes nothing.
    init?(quotedBy reply: MessageRecord, me: NodeId, directory: Directory, shown: Set<ExactKey>) {
        guard let quote = reply.replyTo else {
            return nil
        }
        self.init(quote, state: QuoteState(reply, me: me), me: me, directory: directory, shown: shown)
    }

    /// The words under the name: the snippet on one line, or the photo's label for a photo quoted without words, which
    /// the replier leaves to the receiver (`chat_reply_photo`).
    private static func line(of reply: MessageReply) -> String? {
        let snippet = TextLimits.normalizeSingleLine(reply.snippet)
        if !snippet.isEmpty {
            return snippet
        }
        return reply.hasAttachment ? Copy.Attachments.photoPreview : nil
    }

    /// What VoiceOver reads for it: whom it quotes and what, then the unverified cue; or only that it is unavailable.
    public var accessibilityLabel: String {
        switch state {
        case .unavailable:
            Copy.Replies.unavailableQuote
        case .unverified:
            [Copy.Replies.quote(author, line: line), Copy.Replies.unverifiedQuote].joined(separator: ", ")
        case .verified:
            Copy.Replies.quote(author, line: line)
        }
    }
}

/// The quote the composer holds, which Send sends with the draft (`ReplyPreview` in knit-next): what the reply will
/// carry, and how the composer's bar shows it.
public struct ComposerReply: Sendable, Equatable {
    /// What the reply carries.
    public var reply: MessageReply
    /// The quote as the thread will show it.
    public var quote: ChatQuote

    /// A held quote.
    public init(reply: MessageReply, quote: ChatQuote) {
        self.reply = reply
        self.quote = quote
    }
}

extension AttachmentKind {
    /// The label a quote of a message with no words carries for `attachment` (`ChatScreen.kt:1362-1381`): a GIF, a file
    /// or a voice note, in our language, since the wire says only that there was an attachment. A still photo takes none,
    /// and the receiver writes its own; a link's card is no attachment at all. The engine rebuilds a quote it verified with
    /// the same labels (`MeshConfiguration.quoteLabel`, knit-next ADR 2026-10.gpa3).
    public static func quoteLabel(of attachment: MessageAttachment?) -> String? {
        guard let attachment else {
            return nil
        }
        switch Self(attachment) {
        case .photo:
            let label = preview(of: attachment)
            return label == Copy.Attachments.gifPreview ? label : nil
        case .voice, .file:
            return preview(of: attachment)
        case .link:
            return nil
        }
    }
}
