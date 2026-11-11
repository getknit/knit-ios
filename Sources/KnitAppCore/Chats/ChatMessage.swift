public import KnitWire

/// One message as a thread shows it.
public struct ChatMessage: Sendable, Equatable, Identifiable {
    /// The frame id.
    public var id: String
    /// The text.
    public var body: String
    /// When it was sent, by its author's clock.
    public var sentAt: Int64
    /// Whether we wrote it.
    public var isMine: Bool
    /// Who wrote it.
    public var author: NodeId
    /// The author's label, over someone else's message in the room or a group; `nil` in a DM, where the title says who.
    public var authorLabel: String?
    /// How far it got, when it is ours.
    public var status: DeliveryStatus?
    /// A status line's words, which the thread shows in place of a bubble; `nil` for a message.
    public var notice: String?
    /// The author's face, beside someone else's message in the room or a group; `nil` in a DM, for our own messages,
    /// and for a status line.
    public var authorFace: Face?
    /// What the message carries beside its words, or `nil`.
    public var attachment: ChatAttachment?
    /// Why the content filter keeps its words out of sight, or `nil` while they show (ADR 2026-10.e4kz).
    public var hiddenWords: HiddenWords?
    /// The emoji people reacted with, each where it first appeared; empty for none and for a status line
    /// (ADR 2026-10.ehe6).
    public var reactions: [ReactionChip] = []
    /// The message it replies to, as this phone checked the quote, or `nil` (ADR 2026-10.mn29, knit-next ADR 2026-10.gpa3).
    /// Its words hide with the reply's, and a reply whose quoted words are flagged hides whole.
    public var quote: ChatQuote?
    /// Where the names it mentions sit in ``body``, in UTF-16 offsets, which the bubble sets apart (ADR 2026-10.nbhj).
    public var mentionSpans: [Range<Int>] = []
    /// The web addresses in ``body``, which the bubble makes links, as Android's does (ADR 2026-11.w5ew).
    public var links: [MessageLink] = []
    /// The preview card the sender fetched for one of ``links``, or `nil` (ADR 2026-11.hcvg). Only a build with link
    /// previews draws one, once its blob is here and opens as a card describing a link the words hold.
    public var card: LinkCard?
}
