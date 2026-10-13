public import KnitStore
import KnitWire

/// The message a reply quotes, as a thread shows it above the reply's words (`QuotedMessage` in knit-next's
/// `ChatScreen.kt`, ADR 2026-10.mn29). It draws from the reply's own snapshot, never from the original, which may never
/// have reached this phone.
public struct ChatQuote: Sendable, Equatable {
    /// The quoted message's frame id, which a tap takes the thread to.
    public var messageId: String
    /// Who wrote it: "You" for us, this iPhone's label for a peer it has pinned, and the replier's name for anyone else.
    /// The replier chose that name, so it stands in only for someone this phone does not know.
    public var author: String
    /// What it said: the replier's snippet, the photo's label for a quoted photo with no words, or the words for a
    /// blocked author's hidden quote; `nil` when there is nothing to show beside the author.
    public var line: String?
    /// Whether its author is blocked here, so its words stay out of sight as theirs do everywhere (ADR 2026-10.5wgg).
    public var blocked: Bool
    /// Whether the original shows in this thread, so a tap can take the thread to it. A quote of a message never held,
    /// deleted, or written by someone blocked is no button.
    public var jumps: Bool

    /// A quote as it is shown.
    public init(messageId: String, author: String, line: String?, blocked: Bool = false, jumps: Bool = false) {
        self.messageId = messageId
        self.author = author
        self.line = line
        self.blocked = blocked
        self.jumps = jumps
    }

    /// `reply` as a thread over `directory` shows it, to `me`, among the messages `shown` there.
    init(_ reply: MessageReply, me: NodeId, directory: Directory, shown: Set<ExactKey>) {
        let quoted = NodeId(reply.authorId)
        let hidden = quoted.map(directory.blocked.contains) ?? false
        self.init(
            messageId: reply.messageId,
            author: Self.author(of: reply, quoted, me: me, directory: directory),
            line: hidden ? Copy.Replies.blockedQuote : Self.line(of: reply),
            blocked: hidden,
            jumps: !hidden && shown.contains(ExactKey(reply.messageId))
        )
    }

    /// The name over the quote (`quoteAuthorLabel`, where Android shows the replier's name for anyone but us).
    private static func author(of reply: MessageReply, _ author: NodeId?, me: NodeId, directory: Directory) -> String {
        if author == me {
            return Copy.Common.you
        }
        if let author, directory.peers[author] != nil {
            return directory.label(for: author).text
        }
        let named = TextLimits.normalizeSingleLine(reply.author)
        // A replier who named nobody leaves the alias every phone derives from the id, when the id is one.
        return named.isEmpty ? author.map { directory.label(for: $0).text } ?? "" : named
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
    /// and the receiver writes its own; a link's card is no attachment at all.
    static func quoteLabel(of attachment: MessageAttachment?) -> String? {
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
