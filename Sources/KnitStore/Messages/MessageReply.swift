import KnitWire

/// The message a reply quotes, as the reply carries it (`ReplyRef` in knit-next's `Wire.kt`, kept in
/// `MessageEntity.replyTo*`): a snapshot the replier took, which a thread draws without looking the original up. Only a
/// tap on the quote reads ``messageId``, to find the original when it is held (ADR 2026-10.mn29).
///
/// Every field is the replier's to write, and nothing checks one on arrival, as on Android: the original may never have
/// reached this phone, or may sit in another thread.
public struct MessageReply: Sendable, Equatable {
    /// The quoted message's frame id.
    public var messageId: String
    /// The quoted message's author, as the replier named them: a node id, kept unparsed, which compares by its bytes
    /// (ADR 2026-09.jc2x).
    public var authorId: String
    /// The author's name as the replier saw it: their stored name or their alias, never "You".
    public var author: String
    /// The quoted words on one line, or a label for what the message carried; empty when the words were hidden from the
    /// replier, or when there were none.
    public var snippet: String
    /// Whether the quoted message carried a photo or a file, which a link's card does not count as.
    public var hasAttachment: Bool

    /// A quote.
    public init(messageId: String, authorId: String, author: String, snippet: String, hasAttachment: Bool = false) {
        self.messageId = messageId
        self.authorId = authorId
        self.author = author
        self.snippet = snippet
        self.hasAttachment = hasAttachment
    }
}

extension MessageReply {
    /// The most UTF-16 units of the quoted words a reply carries (`REPLY_SNIPPET_MAX`, `ReplyFormatting.kt`). A thread
    /// shows two lines of them.
    public static let snippetLimit = 120

    /// The quote a reply to `parent` carries (`ChatScreen.kt:1352-1388` and `buildReplySnippet`): the author by
    /// `authorName`, and the words flattened to one line and cut at ``snippetLimit``. Words the replier could not see
    /// (`hidesWords`) are left out, so a quote never shows what a tap on the original would have had to reveal. With no
    /// words, `attachmentLabel` stands in, which names a GIF, a file or a voice note in the replier's language, since the
    /// wire says only whether there was an attachment; a still photo takes none, and the receiver writes its own.
    ///
    /// Kotlin's `take` can split a surrogate pair at the cut; ``TextLimits/truncated(_:toUTF16:)`` stops before one.
    public static func quoting(_ parent: MessageRecord, authorName: String, hidesWords: Bool, attachmentLabel: String?) -> Self {
        let snippet: String
        if hidesWords {
            snippet = ""
        } else if TextLimits.isBlank(parent.body), let attachmentLabel {
            snippet = TextLimits.truncated(attachmentLabel, toUTF16: snippetLimit)
        } else {
            snippet = TextLimits.truncated(TextLimits.normalizeSingleLine(parent.body), toUTF16: snippetLimit)
        }
        return MessageReply(
            messageId: parent.id,
            authorId: parent.senderId.string,
            author: authorName,
            snippet: snippet,
            // A link's card reads as its text, not as an attachment (`LinkPreviewBlob.MIME`).
            hasAttachment: parent.attachment.map { $0.mime != MessageAttachment.linkCardType } ?? false
        )
    }
}

extension MessageAttachment {
    /// The one type a link's preview card goes under (`LinkPreviewBlob.MIME` in knit-next).
    public static let linkCardType = "application/vnd.knit.link-preview"
}
