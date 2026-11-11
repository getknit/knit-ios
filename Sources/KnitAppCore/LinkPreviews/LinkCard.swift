public import KnitWire

/// A link's preview card as a thread draws it (`LinkCard` in knit-next): what the sender's phone fetched, cleaned at the
/// boundary (``LinkPreviewBlob/decode(_:)``), and free of bytes, so a row that carries one stays cheap to compare. The
/// picture is read again from the blob when the card is drawn.
public struct LinkCard: Sendable, Equatable, Hashable {
    /// The blob that holds the card.
    public var hash: BlobHash
    /// The base64 key that opens it in a DM or a group, or `nil` for the room's, which is not sealed.
    public var key: String?
    /// The link the card describes, as the sender normalized it: what a tap opens.
    public var url: String
    /// The host the card is labelled with, read from ``url`` and never from the page.
    public var host: String
    /// The page's title, or the host when it has none (`toCard`).
    public var title: String
    /// The page's description.
    public var description: String?
    /// Whether the card carries a picture.
    public var hasImage: Bool
    /// What the content filter reads of it: the title as the page gave it and the description (``LinkPreviewBlob/moderationText``).
    public var moderationText: String
    /// Whether it was posted in the Nearby room, whose words the filter reads with the room's lists (``TextScreening``).
    public var inRoom: Bool

    /// `blob`, held under `hash` and opened with `key`, posted in the room when `inRoom`.
    public init(_ blob: LinkPreviewBlob, hash: BlobHash, key: String?, inRoom: Bool) {
        self.hash = hash
        self.key = key
        url = blob.url
        host = blob.host
        title = blob.displayTitle
        description = blob.description
        hasImage = blob.image != nil
        moderationText = blob.moderationText
        self.inRoom = inRoom
    }
}
