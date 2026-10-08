/// Pixels to encode: 8-bit RGBA, rows packed with no padding, alpha premultiplied, which is how `CGContext` draws.
public struct RGBAImage: Sendable, Equatable {
    /// The bytes a pixel takes.
    static let channels = 4

    /// Its width, in pixels.
    public let width: Int
    /// Its height, in pixels.
    public let height: Int
    /// `width` × `height` × 4 bytes, premultiplied.
    public let pixels: [UInt8]

    /// `pixels` as an image `width` × `height`, or `nil` when they are not exactly that many.
    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0, pixels.count == width * height * Self.channels else {
            return nil
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The same pixels with alpha taken back out of each colour, as libwebp's `WebPPictureImportRGBA` reads them. A
    /// transparent pixel keeps no colour.
    var straight: [UInt8] {
        var out = pixels
        for pixel in stride(from: 0, to: out.count, by: Self.channels) {
            let alpha = Int(out[pixel + Self.channels - 1])
            guard alpha < Int(UInt8.max) else {
                continue
            }
            for channel in pixel..<(pixel + Self.channels - 1) {
                out[channel] = alpha == 0 ? 0 : UInt8(min(Int(UInt8.max), (Int(out[channel]) * Int(UInt8.max) + (alpha >> 1)) / alpha))
            }
        }
        return out
    }
}
