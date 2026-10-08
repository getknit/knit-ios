#if canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO
    import KnitWebP
    import Testing

    /// ImageIO, which plays every photo on the iPhone, reads what libwebp writes: an animation's frames and their
    /// timing, and a still's alpha. On the Mac only, where ImageIO is.
    @Suite struct ImageIOTests {
        private func fill(_ side: Int, _ rgba: [UInt8]) throws -> RGBAImage {
            try #require(RGBAImage(width: side, height: side, pixels: Array([[UInt8]](repeating: rgba, count: side * side).joined())))
        }

        @Test func anAnimationPlaysAsWritten() throws {
            let writer = try #require(AnimatedWebPWriter(width: 16, height: 16, quality: 0.7))
            #expect(writer.add(try fill(16, [255, 0, 0, 255]), milliseconds: 100))
            #expect(writer.add(try fill(16, [0, 255, 0, 255]), milliseconds: 200))
            #expect(writer.add(try fill(16, [0, 0, 255, 255]), milliseconds: 70))
            let bytes = try #require(writer.finish())
            let source = try #require(CGImageSourceCreateWithData(Data(bytes) as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == "org.webmproject.webp")
            #expect(CGImageSourceGetCount(source) == 3)
            let delays = (0..<3).map { index -> Double in
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let webp = properties?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
                return webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double ?? 0
            }
            #expect(zip(delays, [0.1, 0.2, 0.07]).allSatisfy { abs($0 - $1) < 0.002 }, "\(delays)")
        }

        @Test func aStillKeepsItsAlpha() throws {
            let bytes = try #require(WebPEncoder.still(try fill(8, [128, 0, 0, 128]), quality: 0.85))
            let source = try #require(CGImageSourceCreateWithData(Data(bytes) as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect((image.width, image.height) == (8, 8))
            #expect(image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst)
        }
    }
#endif
