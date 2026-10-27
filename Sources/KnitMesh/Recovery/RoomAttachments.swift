public import KnitWire

/// The attachments a Nearby room post may carry on the receiver (`RoomAttachments.kt:18-63` at knit-next `4408e0fca`, from
/// `eccabcd72`, knit-next ADR 2026-10.79j9): the kinds the room's composer offers and the receive side screens, a picture,
/// a link-preview card or a video. A room attachment is key-less, so its type is its author's claim, and a modified client
/// could name a voice note or a file, which nothing screens. Anything else is left off the row, so it is never fetched,
/// kept or drawn (knit-ios #21), and off what our custody's frames name (``MeshEngine/carriedBlobs()``). The frame itself
/// is untouched: custody and the relay carry the signed bytes as they came, and every node decides this from the frame
/// alone. Android admits `video/*`, which this build shows as a file (knit-ios #9).
public enum RoomAttachments {
    /// The link-preview card's type (`LinkPreviewBlob.MIME`).
    static let linkPreviewMime = "application/vnd.knit.link-preview"

    /// Whether a room post may name an attachment of `mime` (`admits`, `RoomAttachments.kt:20-21`). No type is a
    /// picture, screened as one. The prefixes are case-sensitive, as Kotlin's `startsWith` is, so `IMAGE/PNG` is refused.
    /// It reads the type as the frame carries it, never a row's clipped copy.
    public static func admits(_ mime: String?) -> Bool {
        guard let mime else {
            return true
        }
        // By their bytes, as Kotlin compares UTF-16 units, never Swift's canonical equality.
        return mime.utf8.starts(with: "image/".utf8) || mime.utf8.elementsEqual(linkPreviewMime.utf8)
            || mime.utf8.starts(with: "video/".utf8)
    }

    /// Whether `envelope` is a cleartext room post (a chat to nobody, in no group, sealed to nobody) whose attachment the
    /// room does not admit (`refuses`, `RoomAttachments.kt:27-36`). It tests the raw hash the frame names, as Kotlin
    /// does, not the parsed ``BlobHash``.
    public static func refuses(_ envelope: RelayEnvelope, _ chat: ChatContent) -> Bool {
        envelope.isRoomPost && chat.enc == nil && chat.attachmentHash != nil && !admits(chat.attachmentMime)
    }

    /// Whether `envelope` is a room post that is nothing but a refused attachment (`dropsWhole`, `RoomAttachments.kt:42-45`):
    /// with its attachment dropped there is nothing left to draw, so it keeps no row, and is acknowledged as a blocked
    /// sender's post is (`InboundPipeline.kt:1115-1124`). The body alone counts, untruncated, by Kotlin's `isBlank()`
    /// (``TextLimits/isBlank(_:)``); a quote does not.
    public static func dropsWhole(_ envelope: RelayEnvelope, _ chat: ChatContent) -> Bool {
        refuses(envelope, chat) && TextLimits.isBlank(chat.body)
    }
}
