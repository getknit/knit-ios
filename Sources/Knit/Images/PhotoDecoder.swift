#if os(iOS)
    import Foundation
    import ImageIO
    import UniformTypeIdentifiers

    /// Decodes image bytes only as bounded ImageIO thumbnails, turned upright by their orientation tag. A blob comes
    /// from whoever sent it, so its type and its declared size are checked before anything is decoded: a small file
    /// can declare a huge image, and ImageIO decodes some types whole before it scales them.
    internal enum PhotoDecoder {
        /// What a photo from the mesh may be: what Android sends, JPEG, WebP, and a GIF when WebP cannot carry it
        /// (`AttachmentStore.kt`), and PNG and HEIC besides.
        static let meshTypes: Set<String> = [
            UTType.jpeg.identifier, UTType.png.identifier, UTType.gif.identifier, UTType.webP.identifier,
            UTType.heic.identifier, UTType.heif.identifier,
        ]
        /// The most pixels a photo from the mesh may declare. Android sends no photo past 1280 on its long side, and no
        /// profile photo past 256.
        static let meshPixels = 25_000_000
        /// The most pixels a picked photo may declare: past an iPhone's 48-megapixel photos and its panoramas.
        static let pickedPixels = 100_000_000

        /// `data` as an upright image no larger than `side` pixels on its long side, or `nil` when it is no image, a
        /// type outside `types` (any type ImageIO reads, for `nil`), or one declaring more than `pixels` pixels.
        static func thumbnail(_ data: Data, side: Int, types: Set<String>?, pixels: Int) -> CGImage? {
            guard let source = source(of: data, types: types, pixels: pixels) else {
                return nil
            }
            let thumbnail =
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(side, 1),
                ] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail)
        }

        /// Whether `data` is a GIF declaring at most `pixels` pixels, which a chat sends as it is to keep its frames.
        static func isGIF(_ data: Data, pixels: Int) -> Bool {
            source(of: data, types: [UTType.gif.identifier], pixels: pixels) != nil
        }

        /// Whether `data` is an image of a type a photo from the mesh may be, declaring at most ``meshPixels``: what the
        /// viewer lets Save add to the library.
        static func isMeshPhoto(_ data: Data) -> Bool {
            source(of: data, types: meshTypes, pixels: meshPixels) != nil
        }

        /// An ImageIO source over `data`, once its type is among `types` (any, for `nil`) and its first frame declares a
        /// size of at most `pixels` pixels; nothing is decoded yet.
        private static func source(of data: Data, types: Set<String>?, pixels: Int) -> CGImageSource? {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) > 0,
                let type = CGImageSourceGetType(source) as String?, types?.contains(type) ?? true,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0
            else {
                return nil
            }
            let (area, overflow) = width.multipliedReportingOverflow(by: height)
            return !overflow && area <= pixels ? source : nil
        }
    }
#endif
