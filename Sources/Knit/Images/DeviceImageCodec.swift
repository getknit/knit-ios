#if os(iOS)
    import CoreGraphics
    import Foundation
    import ImageIO
    import KnitAppCore
    import KnitMesh
    import UniformTypeIdentifiers

    /// A picked photo, decoded upright for the cropper.
    internal struct DeviceImage: PreparedImage {
        let image: CGImage

        var pixelWidth: Int { image.width }
        var pixelHeight: Int { image.height }
    }

    /// The phone's image codec (`AvatarStore.kt` and `AttachmentStore.kt` in knit-next): ImageIO decodes a picked photo
    /// upright and bounded, and CoreGraphics crops, scales and encodes the profile photo and a chat's photo, all off the
    /// main actor.
    internal struct DeviceImageCodec: ImageCodec {
        func prepare(_ data: Data) async -> (any PreparedImage)? {
            await Self.decode(data)
        }

        func chatPhoto(from data: Data) async -> OutgoingPhoto? {
            await Self.chatPhoto(data)
        }

        func profilePhoto(from image: any PreparedImage, crop: CropRect) async -> [UInt8]? {
            guard let device = image as? DeviceImage else {
                return nil
            }
            return await Self.encode(device.image, crop: crop)
        }

        @concurrent
        private static func decode(_ data: Data) async -> DeviceImage? {
            PhotoDecoder.thumbnail(data, side: ProfilePhoto.sourceSide, types: nil, pixels: PhotoDecoder.pickedPixels).map(DeviceImage.init)
        }

        /// Each channel's depth.
        private static let bitsPerComponent = 8

        /// `crop` of `image`, drawn onto white at ``ProfilePhoto/side`` pixels square, so a transparent picture is not
        /// black, and encoded as a JPEG of pixels alone. ImageIO adds an EXIF block of the color space and the pixel
        /// size, and nothing of the photo's own: a GPS-tagged picture came out without its place, time or orientation
        /// (2026-10-03).
        @concurrent
        private static func encode(_ image: CGImage, crop: CropRect) async -> [UInt8]? {
            let side = ProfilePhoto.side
            let bounds = CGRect(x: 0, y: 0, width: side, height: side)
            let region = CGRect(x: crop.left, y: crop.top, width: crop.width, height: crop.height)
            guard let square = image.cropping(to: region), let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil,
                    width: side,
                    height: side,
                    bitsPerComponent: bitsPerComponent,
                    bytesPerRow: 0,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
            else {
                return nil
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            context.interpolationQuality = .high
            context.draw(square, in: bounds)
            return context.makeImage().flatMap { jpeg($0, quality: ProfilePhoto.quality) }
        }

        /// A picked photo made ready for a chat (`AttachmentStore.ingest`). A GIF goes as it is, frames and all, when the
        /// mesh takes it whole and a phone may decode it; Android's shrinks one into an animated WebP, which ImageIO
        /// cannot write. Anything else, a GIF too heavy or too large among it, is drawn upright at no more than
        /// ``ChatPhoto/side`` and encoded afresh, which leaves its metadata behind.
        @concurrent
        private static func chatPhoto(_ data: Data) async -> OutgoingPhoto? {
            if data.count <= OutgoingPhoto.maxBytes, PhotoDecoder.isGIF(data, pixels: PhotoDecoder.meshPixels) {
                return OutgoingPhoto(bytes: [UInt8](data), mime: Mime.gif)
            }
            return PhotoDecoder.thumbnail(data, side: ChatPhoto.side, types: nil, pixels: PhotoDecoder.pickedPixels)
                .flatMap(chatPhoto(drawing:))
                .flatMap { $0.bytes.count <= OutgoingPhoto.maxBytes ? $0 : nil }
        }

        /// `image` drawn into sRGB and encoded with nothing of the source's own: a JPEG at ``ChatPhoto/quality``, or a PNG
        /// when it has transparency, which a JPEG would fill in black.
        private static func chatPhoto(drawing image: CGImage) -> OutgoingPhoto? {
            let transparent = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
            let alpha: CGImageAlphaInfo = transparent ? .premultipliedLast : .noneSkipLast
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: bitsPerComponent,
                    bytesPerRow: 0,
                    space: space,
                    bitmapInfo: alpha.rawValue
                )
            else {
                return nil
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let drawn = context.makeImage() else {
                return nil
            }
            if transparent {
                return encode(drawn, as: .png, properties: [:]).map { OutgoingPhoto(bytes: $0, mime: Mime.png) }
            }
            return jpeg(drawn, quality: ChatPhoto.quality).map { OutgoingPhoto(bytes: $0, mime: Mime.jpeg) }
        }

        /// The types a chat's photo goes under.
        private enum Mime {
            static let jpeg = "image/jpeg"
            static let png = "image/png"
            static let gif = "image/gif"
        }

        /// `image` as a JPEG at `quality`, and nothing else.
        static func jpeg(_ image: CGImage, quality: Double) -> [UInt8]? {
            encode(image, as: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
        }

        /// `image` encoded as `type` with `properties`, and nothing else.
        private static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any]) -> [UInt8]? {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            return CGImageDestinationFinalize(destination) ? [UInt8](output as Data) : nil
        }
    }
#endif
