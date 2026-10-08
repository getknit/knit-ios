/// A picture's own bytes with its metadata gone (``JPEGStrip``, ``WebPStrip``), and what the walk read of it: its size,
/// its frames, and for a JPEG the quality its tables were scaled to.
public struct StrippedPicture: Sendable, Equatable {
    /// The bytes that would go out.
    public let bytes: [UInt8]
    /// Its width, in pixels, as its header declares it.
    public let width: Int
    /// Its height, in pixels.
    public let height: Int
    /// How many frames it holds: one for a still.
    public let frames: Int
    /// The libjpeg quality a JPEG's luminance table reads as, or `nil` for a WebP, whose quantizer the walk leaves.
    public let quality: Int?

    /// Whether a still goes out as these bytes rather than decoded and written again (`AttachmentStore.passThrough`,
    /// ADR 2026-10.unqn): no larger than ``ChatPhoto/side`` on its long side, and no sharper than the re-encode would
    /// make it. So a camera original still takes one re-encode, and the app's own output never takes another. The
    /// app checks the rest, which needs a decoder: that it is upright and decodes at the size it declares.
    public var isClean: Bool {
        guard frames == 1, max(width, height) <= ChatPhoto.side else {
            return false
        }
        if let quality {
            return quality <= ChatPhoto.sharpestPassThrough
        }
        return Double(bytes.count) <= Double(width * height) * ChatPhoto.heaviestWebP
    }
}
