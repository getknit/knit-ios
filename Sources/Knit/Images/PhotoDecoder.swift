#if os(iOS)
    import Foundation
    import ImageIO
    import KnitAppCore
    import KnitStore
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
            source(of: data, types: types, pixels: pixels).flatMap { frame($0, at: 0, side: side) }
        }

        /// Frame `index` of `source`, as it shows on screen, upright and no larger than `side` pixels on its long side.
        /// ImageIO draws a GIF's, a WebP's or an APNG's frame over the ones before it, as a player shows it.
        static func frame(_ source: CGImageSource, at index: Int, side: Int) -> CGImage? {
            let thumbnail =
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(side, 1),
                ] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(source, index, thumbnail)
        }

        /// A picked picture, opened but not decoded: its type, how many frames it has, its declared size, and whether
        /// its orientation tag leaves it as it is stored.
        struct Picked {
            let source: CGImageSource
            let type: String
            let frames: Int
            let width: Int
            let height: Int
            let upright: Bool
        }

        /// `data` opened as a picked picture, or why it cannot be sent: no image ImageIO reads, or one declaring more than
        /// ``pickedPixels`` pixels.
        static func picked(_ data: Data) -> Result<Picked, PhotoFailure> {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) > 0,
                let type = CGImageSourceGetType(source) as String?,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0
            else {
                return .failure(.unreadable)
            }
            let (area, overflow) = width.multipliedReportingOverflow(by: height)
            guard !overflow, area <= pickedPixels else {
                return .failure(.tooLarge)
            }
            let orientation = properties[kCGImagePropertyOrientation] as? UInt32
            let picked = Picked(
                source: source,
                type: type,
                frames: CGImageSourceGetCount(source),
                width: width,
                height: height,
                upright: orientation.map { $0 == CGImagePropertyOrientation.up.rawValue } ?? true
            )
            return .success(picked)
        }

        /// How long each of `source`'s `count` frames stays, in seconds, as its header says.
        static func delays(of source: CGImageSource, count: Int) -> [Double] {
            (0..<count).map { index in
                (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]).map(delay(in:)) ?? 0
            }
        }

        /// Whether `bytes` decode, at exactly `width` by `height`: the check a picture passes before it leaves as its own
        /// bytes (`decodesAt` in knit-next). Read at an eighth of the size, so nothing large is held, though the decoder
        /// still walks the whole stream.
        static func decodes(_ bytes: [UInt8], width: Int, height: Int) -> Bool {
            guard let source = source(of: Data(bytes), types: nil, pixels: pickedPixels),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                properties[kCGImagePropertyPixelWidth] as? Int == width, properties[kCGImagePropertyPixelHeight] as? Int == height
            else {
                return false
            }
            return frame(source, at: 0, side: max(width, height) / checkScale) != nil
        }

        /// How much smaller ``decodes(_:width:height:)`` reads a picture than it is (`PASS_THROUGH_CHECK_SAMPLE`).
        private static let checkScale = 8

        /// The size the first frame of `source` stands at once turned upright, read from its header without decoding it.
        private static func uprightSize(of source: CGImageSource) -> CGSize? {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
            else {
                return nil
            }
            let orientation = (properties[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init)
            let turned = orientation.map(quarterTurns.contains) ?? false
            return turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }

        /// The upright size of `bytes`, a photo from the mesh, and whether it has more than one frame, read from its header:
        /// what the session stores on each message that carries it (ADR 2026-10.6cas). `nil` for bytes
        /// ``thumbnail(_:side:types:pixels:)`` would refuse.
        static func dimensions(_ bytes: [UInt8]) -> PhotoDimensions? {
            guard let source = source(of: Data(bytes), types: meshTypes, pixels: meshPixels), let size = uprightSize(of: source) else {
                return nil
            }
            return PhotoDimensions(width: Int(size.width), height: Int(size.height), animated: CGImageSourceGetCount(source) > 1)
        }

        /// `data`'s frames and when each shows, for a photo from the mesh that moves and is small enough to play
        /// (``AnimationTiming``); `nil` for a still, for one past its limits, which shows its first frame, and for bytes
        /// ``thumbnail(_:side:types:pixels:)`` would refuse. Nothing is decoded: each frame's delay is read from its
        /// header, the unclamped one first, as browsers read it.
        static func animation(_ data: Data) -> AnimatedPhoto? {
            guard let source = source(of: data, types: meshTypes, pixels: meshPixels) else {
                return nil
            }
            let count = CGImageSourceGetCount(source)
            guard count > 1, count <= AnimationTiming.maxFrames,
                let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = first[kCGImagePropertyPixelWidth] as? Int, let height = first[kCGImagePropertyPixelHeight] as? Int
            else {
                return nil
            }
            let delays = delays(of: source, count: count)
            return AnimationTiming(delays: delays, width: width, height: height).map { AnimatedPhoto(bytes: data, timing: $0) }
        }

        /// Where a type that moves keeps a frame's delay: its dictionary, its unclamped delay and its delay.
        private struct DelayKeys {
            var dictionary: CFString
            var unclamped: CFString
            var clamped: CFString
        }

        /// Built where it is read: a `CFString` is not `Sendable`, so a stored global cannot hold one.
        private static var delayKeys: [DelayKeys] {
            [
                DelayKeys(
                    dictionary: kCGImagePropertyGIFDictionary,
                    unclamped: kCGImagePropertyGIFUnclampedDelayTime,
                    clamped: kCGImagePropertyGIFDelayTime
                ),
                DelayKeys(
                    dictionary: kCGImagePropertyWebPDictionary,
                    unclamped: kCGImagePropertyWebPUnclampedDelayTime,
                    clamped: kCGImagePropertyWebPDelayTime
                ),
                DelayKeys(
                    dictionary: kCGImagePropertyPNGDictionary,
                    unclamped: kCGImagePropertyAPNGUnclampedDelayTime,
                    clamped: kCGImagePropertyAPNGDelayTime
                ),
            ]
        }

        /// A frame's delay in seconds from its `properties`, or 0, which plays as a short delay does.
        private static func delay(in properties: [CFString: Any]) -> Double {
            for keys in delayKeys {
                if let frame = properties[keys.dictionary] as? [CFString: Any] {
                    return (frame[keys.unclamped] as? Double) ?? (frame[keys.clamped] as? Double) ?? 0
                }
            }
            return 0
        }

        /// The orientations that stand an image on its side, so it is upright with its width and height swapped.
        private static let quarterTurns: Set<CGImagePropertyOrientation> = [.left, .leftMirrored, .right, .rightMirrored]

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
