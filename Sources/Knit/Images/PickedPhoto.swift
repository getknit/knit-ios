#if os(iOS)
    import CoreGraphics
    import Foundation
    import ImageIO
    import KnitAppCore
    import KnitMesh
    import KnitWebP
    import UniformTypeIdentifiers

    /// A picked picture made ready for a chat, as Android's `AttachmentStore.ingest` makes one (ADR 2026-10.m4ah): the
    /// picture's own bytes pick the door, whatever the picker called it.
    ///
    /// - A moving picture keeps its frames (``ChatAnimation``). A GIF becomes an animated WebP at 480 pixels, unless the
    ///   WebP would be no smaller; an animated WebP within ``Sticker``'s bounds goes as itself, stripped, and past them is
    ///   resampled like a GIF; an APNG is always resampled, since Android plays none.
    /// - A clean still goes as its own bytes with its metadata gone (``StrippedPicture/isClean``), so a picture sent
    ///   again loses no generation and keeps its hash.
    /// - Anything else is drawn upright at no more than ``ChatPhoto/side`` and written afresh: a JPEG, or a lossy WebP
    ///   when it has transparency. Nothing of the picked picture's metadata goes.
    ///
    /// A moving picture no route takes goes as its first frame, as on Android.
    internal enum PickedPhoto {
        /// `data` made ready to send, or why it cannot be, each said on `log`.
        static func prepare(_ data: Data, log: any KnitLog) -> Result<OutgoingPhoto, PhotoFailure> {
            let picked: PhotoDecoder.Picked
            switch PhotoDecoder.picked(data) {
            case .success(let opened):
                picked = opened
            case .failure(let failure):
                log.log(.info, "picked photo (\(data.count) B) refused: \(failure)")
                return .failure(failure)
            }
            let result = prepare(picked, [UInt8](data))
            let made = (try? result.get()).map { "\($0.mime), \($0.bytes.count) B" } ?? "refused"
            log.log(
                .info, "picked photo: \(picked.type) \(picked.width)x\(picked.height), \(picked.frames) frames, \(data.count) B -> \(made)")
            return result
        }

        private static func prepare(_ picked: PhotoDecoder.Picked, _ bytes: [UInt8]) -> Result<OutgoingPhoto, PhotoFailure> {
            if picked.frames > 1, let moving = animated(picked, bytes) {
                return .success(moving)
            }
            if let clean = clean(picked, bytes) {
                return .success(clean)
            }
            return still(picked)
        }

        // MARK: Moving

        /// `bytes` with their frames kept, or `nil` when no route takes them.
        private static func animated(_ picked: PhotoDecoder.Picked, _ bytes: [UInt8]) -> OutgoingPhoto? {
            // Bytes that go as they are must be within what a receiving phone decodes.
            let whole = picked.width * picked.height <= PhotoDecoder.meshPixels
            switch picked.type {
            case UTType.gif.identifier:
                if let webp = resampled(picked), webp.count < bytes.count {
                    return fits(webp, Mime.webp)
                }
                return whole ? fits(bytes, Mime.gif) : nil
            case UTType.webP.identifier:
                let stripped = whole ? WebPStrip.animated(bytes) : nil
                if let stripped, isSticker(stripped) {
                    return OutgoingPhoto(bytes: stripped.bytes, mime: Mime.webp)
                }
                let candidates = [resampled(picked), stripped?.bytes].compactMap(\.self).filter { $0.count <= OutgoingPhoto.maxBytes }
                return candidates.min { $0.count < $1.count }.map { OutgoingPhoto(bytes: $0, mime: Mime.webp) }
            case UTType.png.identifier:
                return resampled(picked).flatMap { fits($0, Mime.webp) }
            default:
                return nil
            }
        }

        /// Whether `stripped` is within the bounds an animated WebP goes as itself within.
        private static func isSticker(_ stripped: StrippedPicture) -> Bool {
            max(stripped.width, stripped.height) <= Sticker.side && stripped.frames <= Sticker.maxFrames
                && stripped.bytes.count <= Sticker.maxBytes
        }

        /// The picture sampled as ``FrameSchedule`` says and written as an animated WebP at ``ChatAnimation``'s size and
        /// quality, a frame at a time, so memory follows the output, not the clip.
        private static func resampled(_ picked: PhotoDecoder.Picked) -> [UInt8]? {
            guard max(picked.width, picked.height) <= ChatAnimation.maxSourceSide,
                let schedule = FrameSchedule(delays: PhotoDecoder.delays(of: picked.source, count: picked.frames)),
                let first = PhotoDecoder.frame(picked.source, at: 0, side: ChatAnimation.side),
                let canvas = Canvas(width: first.width, height: first.height),
                let writer = AnimatedWebPWriter(width: first.width, height: first.height, quality: ChatAnimation.quality)
            else {
                return nil
            }
            for frame in schedule.frames {
                let added = autoreleasepool {
                    PhotoDecoder.frame(picked.source, at: frame.source, side: ChatAnimation.side)
                        .flatMap(canvas.draw)
                        .map { writer.add($0, milliseconds: frame.milliseconds) } ?? false
                }
                guard added else {
                    return nil
                }
            }
            return writer.finish()
        }

        // MARK: Still

        /// The picture as its own bytes, stripped, when it is clean enough to go so: a JPEG or a still lossy WebP within
        /// the bound, upright, no sharper than the re-encode, and decoding at the size it declares.
        private static func clean(_ picked: PhotoDecoder.Picked, _ bytes: [UInt8]) -> OutgoingPhoto? {
            guard picked.frames == 1, picked.upright, max(picked.width, picked.height) <= ChatPhoto.side else {
                return nil
            }
            let stripped: StrippedPicture?
            let mime: String
            switch picked.type {
            case UTType.jpeg.identifier:
                (stripped, mime) = (JPEGStrip.stripped(bytes), Mime.jpeg)
            case UTType.webP.identifier:
                (stripped, mime) = (WebPStrip.still(bytes), Mime.webp)
            default:
                return nil
            }
            guard let stripped, stripped.isClean, PhotoDecoder.decodes(stripped.bytes, width: stripped.width, height: stripped.height)
            else {
                return nil
            }
            return OutgoingPhoto(bytes: stripped.bytes, mime: mime)
        }

        /// The first frame drawn upright into sRGB at no more than ``ChatPhoto/side`` and written with nothing of the
        /// source's own: a JPEG, or a lossy WebP when it has transparency, which a JPEG would fill in black.
        private static func still(_ picked: PhotoDecoder.Picked) -> Result<OutgoingPhoto, PhotoFailure> {
            guard let image = PhotoDecoder.frame(picked.source, at: 0, side: ChatPhoto.side),
                let canvas = Canvas(width: image.width, height: image.height, transparent: hasAlpha(image))
            else {
                return .failure(.unreadable)
            }
            let encoded: OutgoingPhoto?
            if canvas.transparent {
                encoded = canvas.draw(image)
                    .flatMap { WebPEncoder.still($0, quality: ChatPhoto.quality) }
                    .map { OutgoingPhoto(bytes: $0, mime: Mime.webp) }
            } else {
                // ImageIO adds a little EXIF of its own, the color space and the size, which the strip takes out: the
                // photo is then what it would be picked again, so a re-pick goes as these bytes, with this hash.
                encoded = canvas.image(of: image)
                    .flatMap { DeviceImageCodec.jpeg($0, quality: ChatPhoto.imageIOQuality) }
                    .map { JPEGStrip.stripped($0)?.bytes ?? $0 }
                    .map { OutgoingPhoto(bytes: $0, mime: Mime.jpeg) }
            }
            guard let encoded else {
                return .failure(.unreadable)
            }
            return encoded.bytes.count <= OutgoingPhoto.maxBytes ? .success(encoded) : .failure(.tooLarge)
        }

        private static func hasAlpha(_ image: CGImage) -> Bool {
            [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
        }

        /// `bytes` as a photo of type `mime`, when they fit a message.
        private static func fits(_ bytes: [UInt8], _ mime: String) -> OutgoingPhoto? {
            bytes.count <= OutgoingPhoto.maxBytes ? OutgoingPhoto(bytes: bytes, mime: mime) : nil
        }

        /// The types a chat's photo goes under.
        private enum Mime {
            static let jpeg = "image/jpeg"
            static let gif = "image/gif"
            static let webp = "image/webp"
        }
    }

    /// An sRGB drawing surface of one size, 8 bits a channel and rows packed, so its pixels can go to libwebp as they are.
    /// Opaque unless `transparent`, when its alpha is premultiplied, as `CGContext` keeps it.
    private final class Canvas {
        private static let bitsPerComponent = 8
        private static let channels = 4

        let width: Int
        let height: Int
        let transparent: Bool
        private let context: CGContext

        init?(width: Int, height: Int, transparent: Bool = true) {
            let alpha: CGImageAlphaInfo = transparent ? .premultipliedLast : .noneSkipLast
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let drawing = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: Self.bitsPerComponent,
                    bytesPerRow: width * Self.channels,
                    space: space,
                    bitmapInfo: alpha.rawValue
                )
            else {
                return nil
            }
            drawing.interpolationQuality = .high
            self.width = width
            self.height = height
            self.transparent = transparent
            context = drawing
        }

        /// `image` drawn to fill the canvas, as RGBA for libwebp.
        func draw(_ image: CGImage) -> RGBAImage? {
            paint(image)
            guard let data = context.data else {
                return nil
            }
            let count = width * height * Self.channels
            let pixels = [UInt8](UnsafeRawBufferPointer(start: data, count: count))
            return RGBAImage(width: width, height: height, pixels: pixels)
        }

        /// `image` drawn to fill the canvas, as an image ImageIO can write.
        func image(of image: CGImage) -> CGImage? {
            paint(image)
            return context.makeImage()
        }

        private func paint(_ image: CGImage) {
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.clear(bounds)
            context.draw(image, in: bounds)
        }
    }
#endif
