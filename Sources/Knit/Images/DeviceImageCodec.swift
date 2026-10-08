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
    /// upright and bounded, CoreGraphics crops, scales and encodes the profile photo, and ``PickedPhoto`` makes a chat's
    /// photo, all off the main actor.
    internal struct DeviceImageCodec: ImageCodec {
        /// Where a chat's photo says what it was picked as and what it goes as.
        private let log: any KnitLog = UnifiedLog(clock: SystemClock())

        func prepare(_ data: Data) async -> (any PreparedImage)? {
            await Self.decode(data)
        }

        func chatPhoto(from data: Data) async -> Result<OutgoingPhoto, PhotoFailure> {
            await Self.chatPhoto(data, log: log)
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

        /// A picked photo made ready for a chat, off the main actor: a GIF's frames take a moment to shrink.
        @concurrent
        private static func chatPhoto(_ data: Data, log: any KnitLog) async -> Result<OutgoingPhoto, PhotoFailure> {
            PickedPhoto.prepare(data, log: log)
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
