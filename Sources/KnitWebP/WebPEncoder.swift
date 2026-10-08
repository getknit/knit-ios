internal import libwebp

/// Lossy WebP, as Android writes it with `Bitmap.compress(WEBP_LOSSY, …)`: what ImageIO cannot write.
public enum WebPEncoder {
    /// `image` as a lossy WebP at `quality` (0 to 1), its alpha kept, or `nil` when libwebp fails.
    public static func still(_ image: RGBAImage, quality: Double) -> [UInt8]? {
        guard var config = Self.config(quality: quality), var picture = Self.picture(image) else {
            return nil
        }
        defer { WebPPictureFree(&picture) }
        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        let encoded = withUnsafeMutablePointer(to: &writer) { sink in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(sink)
            return WebPEncode(&config, &picture) != 0
        }
        guard encoded, let memory = writer.mem else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: memory, count: writer.size))
    }

    /// libwebp's default settings, lossy, at `quality` (0 to 1).
    static func config(quality: Double) -> WebPConfig? {
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else {
            return nil
        }
        config.quality = Float(min(max(quality, 0), 1) * Self.scale)
        config.lossless = 0
        return WebPValidateConfig(&config) != 0 ? config : nil
    }

    /// A picture holding `image`, in ARGB as the lossy encoder takes it, which the caller frees.
    static func picture(_ image: RGBAImage) -> WebPPicture? {
        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else {
            return nil
        }
        picture.use_argb = 1
        picture.width = Int32(image.width)
        picture.height = Int32(image.height)
        let imported = image.straight.withUnsafeBufferPointer { rows in
            rows.baseAddress.map { WebPPictureImportRGBA(&picture, $0, Int32(image.width * RGBAImage.channels)) != 0 } ?? false
        }
        guard imported else {
            WebPPictureFree(&picture)
            return nil
        }
        return picture
    }

    /// libwebp's quality runs to 100.
    private static let scale = 100.0
}
