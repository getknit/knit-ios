public import KnitMesh
public import KnitStore
public import KnitWire

/// What a message's attachment is, for every surface that shows one or names it in a line (`AttachmentKind.kt` in
/// knit-next). The order of the tests is the rule: a file by the name only a file carries, a voice message by its type,
/// a link's card by its one type, and a photo for an image or no type at all. Anything else is a file.
public enum AttachmentKind: Sendable, Equatable {
    /// A photo or a GIF, which a thread draws.
    case photo
    /// A voice message, which this build names and cannot play.
    case voice
    /// A file, which this build names and cannot open.
    case file
    /// A link's preview card (`LinkPreviewBlob.MIME`), which a thread leaves to the link in the text.
    case link

    /// The one type a link's card goes under.
    static let linkCardType = "application/vnd.knit.link-preview"

    /// What `attachment` is (`attachmentKindOf`).
    public init(_ attachment: MessageAttachment) {
        let mime = attachment.mime
        if attachment.name != nil {
            self = .file
        } else if mime?.hasPrefix("audio/") == true {
            self = .voice
        } else if mime == Self.linkCardType {
            self = .link
        } else if mime.map({ $0.hasPrefix("image/") }) ?? true {
            self = .photo
        } else {
            self = .file
        }
    }

    /// What a message carrying `attachment` and no words says in a line: a list's preview, or a notification
    /// (`attachmentPreview` in knit-next). A photo whose bytes have been read is a GIF when it moves, as Android labels one
    /// from its frames (knit-next `0b9d19ea`), since Android sends every GIF as an animated WebP. Until then only the type
    /// speaks for one: a notification is written before the bytes are in.
    public static func preview(of attachment: MessageAttachment) -> String {
        switch Self(attachment) {
        case .photo:
            attachment.dimensions.map(\.animated) ?? (attachment.mime == "image/gif")
                ? Copy.Attachments.gifPreview : Copy.Attachments.photoPreview
        case .voice:
            Copy.Attachments.voicePreview
        case .file:
            Copy.Attachments.filePreview(attachment.name ?? Copy.Attachments.file)
        case .link:
            Copy.Attachments.linkPreview
        }
    }

    /// The line a list or a notification shows for `message`: its words, or, when it has none, what it carries. When
    /// `hiding`, the content filter's word for them stands in their place.
    static func line(of message: MessageRecord, hiding: Bool) -> String {
        if hiding {
            return Copy.Moderation.hiddenMessage
        }
        guard TextLimits.isBlank(message.body), let attachment = message.attachment else {
            return message.body
        }
        return preview(of: attachment)
    }
}

extension MessageRecord {
    /// Whether the content filter hides these words from `me` (ADR 2026-10.e4kz): it is on, someone else wrote them, and
    /// it flagged them or has yet to screen them. Nothing shows someone else's words before the filter has read them.
    func hidesWords(filtering: Bool, me: NodeId) -> Bool {
        filtering && senderId != me && (moderation == .flagged || moderation == .waiting)
    }
}

/// A message's attachment as a thread shows it. View state carries the hash, and the app reads and decodes the bytes
/// when it draws them, as it does a face's photo.
public struct ChatAttachment: Sendable, Equatable {
    /// The blob.
    public var hash: BlobHash
    /// What it is.
    public var kind: AttachmentKind
    /// The base64 key that opens a photo sealed in a DM or a group, or `nil` for the room's, which is not sealed.
    public var key: String?
    /// Whether its bytes are on this phone.
    public var isHeld: Bool
    /// What it is, in words: a file's name, or what a voice message or a photo is called.
    public var label: String
    /// A photo's upright size, once its bytes have been read on this phone: the shape its bubble holds from its first
    /// frame, before the photo decodes.
    public var dimensions: PhotoDimensions?
}

extension ChatAttachment {
    /// `attachment` as shown, with `isHeld` saying whether its bytes are here, or `nil` for a link's card, which shows
    /// nothing the link in the text does not.
    public init?(_ attachment: MessageAttachment, isHeld: Bool) {
        let kind = AttachmentKind(attachment)
        switch kind {
        case .photo:
            label = Copy.Attachments.photo
        case .voice:
            label = Copy.Attachments.voiceMessage
        case .file:
            label = attachment.name ?? Copy.Attachments.file
        case .link:
            return nil
        }
        hash = attachment.hash
        self.kind = kind
        key = attachment.key
        self.isHeld = isHeld
        dimensions = attachment.dimensions
    }
}

/// A photo the composer holds until Send: what goes out, and the hash of its bytes, which the composer draws it by
/// before anything is stored.
public struct StagedPhoto: Sendable, Equatable {
    /// The photo as it leaves this phone.
    public var photo: OutgoingPhoto
    /// The hash of ``photo``'s bytes.
    public var hash: BlobHash
}
