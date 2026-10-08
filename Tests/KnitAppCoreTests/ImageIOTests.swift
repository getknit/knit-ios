#if canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO
    import Testing

    @testable import KnitAppCore

    /// ImageIO's JPEG quality is not libjpeg's, so the app writes at the ImageIO quality whose tables read as Android's 85
    /// (``ChatPhoto/imageIOQuality``), and what it writes is clean enough to go as itself when it is picked again. On the
    /// Mac only, where ImageIO is.
    @Suite struct ImageIOTests {
        /// A 640 by 480 gradient, the kind of picture whose tables, not whose pixels, decide the reading.
        private func painted() throws -> CGImage {
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(
                CGContext(
                    data: nil,
                    width: 640,
                    height: 480,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
            )
            for row in 0..<48 {
                context.setFillColor(red: Double(row) / 48, green: 0.4, blue: 1 - Double(row) / 48, alpha: 1)
                context.fill(CGRect(x: 0, y: row * 10, width: 640, height: 10))
            }
            return try #require(context.makeImage())
        }

        private func jpeg(_ image: CGImage, quality: Double) throws -> [UInt8] {
            let output = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            return [UInt8](output as Data)
        }

        /// What the strip reads of a picture ImageIO wrote at `quality`.
        private func written(at quality: Double) throws -> StrippedPicture {
            let bytes = try jpeg(try painted(), quality: quality)
            return try #require(JPEGStrip.stripped(bytes))
        }

        @Test func theAppsQualityReadsAsAndroids() throws {
            let read = try #require(try written(at: ChatPhoto.imageIOQuality).quality)
            #expect(abs(read - Int((ChatPhoto.quality * 100).rounded())) <= 1, "ImageIO's \(ChatPhoto.imageIOQuality) read as \(read)")
            let plain = try #require(try written(at: ChatPhoto.quality).quality)
            #expect(plain > ChatPhoto.sharpestPassThrough, "ImageIO's own 0.85 is sharper than Android's 85")
        }

        @Test func whatTheAppWritesGoesAsItselfWhenPickedAgain() throws {
            let ours = try written(at: ChatPhoto.imageIOQuality)
            #expect(ours.isClean)
            #expect(JPEGStrip.stripped(ours.bytes) == ours, "picked again, the same bytes and so the same hash")
            let source = try #require(CGImageSourceCreateWithData(Data(ours.bytes) as CFData, nil))
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 640, "ImageIO reads the stripped bytes")
        }
    }
#endif
