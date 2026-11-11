#if os(iOS) && DEBUG
    import CoreGraphics
    import Foundation
    import KnitAppCore
    import KnitWebP
    import KnitWire

    /// The card's picture made small on the phone (`PreviewImage.shrink` in knit-next, ADR 2026-11.hcvg): decoded upright
    /// and bounded by ImageIO, refused under ``CardPicture/minSide``, and written as a JPEG, or as a lossy WebP when it has
    /// transparency; past ``LinkPreviewBlob/imageMaxBytes``, once more at ``CardPicture/retrySide`` and
    /// ``CardPicture/retryQuality``, then not at all.
    internal enum CardPictureMaker {
        /// The card's picture from `bytes`, or `nil` when there is nothing worth carrying.
        @concurrent
        static func shrink(_ bytes: [UInt8]) async -> ShrunkPicture? {
            let decoded = PhotoDecoder.thumbnail(
                Data(bytes), side: CardPicture.side, types: PhotoDecoder.meshTypes, pixels: PhotoDecoder.meshPixels)
            guard let image = decoded, image.width >= CardPicture.minSide, image.height >= CardPicture.minSide else {
                return nil
            }
            return encode(image, side: CardPicture.side, jpeg: CardPicture.imageIOQuality, webP: CardPicture.quality)
                ?? encode(image, side: CardPicture.retrySide, jpeg: CardPicture.retryImageIOQuality, webP: CardPicture.retryQuality)
        }

        /// `image` drawn at no more than `side` pixels on its long side and written, or `nil` when it does not fit a card.
        private static func encode(_ image: CGImage, side: Int, jpeg: Double, webP: Double) -> ShrunkPicture? {
            let longest = max(image.width, image.height)
            let scale = min(1, Double(side) / Double(longest))
            let width = max(1, Int((Double(image.width) * scale).rounded()))
            let height = max(1, Int((Double(image.height) * scale).rounded()))
            let transparent = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
            guard let canvas = PictureCanvas(width: width, height: height, transparent: transparent) else {
                return nil
            }
            let written: ShrunkPicture?
            if transparent {
                written = canvas.draw(image).flatMap { WebPEncoder.still($0, quality: webP) }
                    .map { ShrunkPicture(bytes: $0, mime: "image/webp") }
            } else {
                written = canvas.image(of: image).flatMap { DeviceImageCodec.jpeg($0, quality: jpeg) }
                    .map { JPEGStrip.stripped($0)?.bytes ?? $0 }
                    .map { ShrunkPicture(bytes: $0, mime: "image/jpeg") }
            }
            return written.flatMap { $0.bytes.count <= LinkPreviewBlob.imageMaxBytes ? $0 : nil }
        }
    }
#endif
