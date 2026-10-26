/// A photo's size in pixels, upright: turned as its orientation says, so a portrait stands taller than it is wide. A
/// thread holds a photo's place at this shape from its first frame, before the photo decodes. Read beside it, from
/// the same bytes, is whether the photo moves, which a line about the message names a GIF (knit-next `0b9d19ea`).
public struct PhotoDimensions: Sendable, Hashable {
    /// The width, in pixels.
    public let width: Int
    /// The height, in pixels.
    public let height: Int
    /// Whether it has more than one frame: a GIF, an animated WebP or an APNG that plays.
    public let animated: Bool

    /// A size, or `nil` unless both sides are at least a pixel.
    public init?(width: Int, height: Int, animated: Bool = false) {
        guard width > 0, height > 0 else {
            return nil
        }
        self.width = width
        self.height = height
        self.animated = animated
    }
}
