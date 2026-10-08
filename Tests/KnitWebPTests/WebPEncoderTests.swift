import KnitWebP
import Testing

/// What the iPhone writes where Android writes WebP (ADR 2026-10.m4ah): a lossy still that keeps its alpha, and an
/// animation that keeps its frames, its timing and its loop.
@Suite struct WebPEncoderTests {
    /// A `width` × `height` image of one premultiplied colour.
    private func fill(_ width: Int, _ height: Int, _ rgba: [UInt8]) throws -> RGBAImage {
        try #require(RGBAImage(width: width, height: height, pixels: Array([[UInt8]](repeating: rgba, count: width * height).joined())))
    }

    /// A `side`-square image of noise, which compresses little, so quality shows in the bytes.
    private func noise(_ side: Int, seed: UInt64) throws -> RGBAImage {
        var state = seed
        let pixels = (0..<side * side).flatMap { _ -> [UInt8] in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return [
                UInt8(truncatingIfNeeded: state >> 24), UInt8(truncatingIfNeeded: state >> 32), UInt8(truncatingIfNeeded: state >> 40), 255,
            ]
        }
        return try #require(RGBAImage(width: side, height: side, pixels: pixels))
    }

    @Test func anImageIsExactlyItsPixels() {
        #expect(RGBAImage(width: 2, height: 2, pixels: [UInt8](repeating: 0, count: 15)) == nil)
        #expect(RGBAImage(width: 0, height: 2, pixels: []) == nil)
        #expect(RGBAImage(width: 1, height: 1, pixels: [1, 2, 3, 4]) != nil)
    }

    @Test func aStillKeepsItsSizeAndItsAlpha() throws {
        // Half-transparent red, premultiplied: 128 of red at alpha 128.
        let image = try fill(16, 8, [128, 0, 0, 128])
        let bytes = try #require(WebPEncoder.still(image, quality: 0.85))
        #expect(bytes.starts(with: Array("RIFF".utf8)))
        let decoded = try #require(DecodedWebP(bytes))
        #expect((decoded.width, decoded.height, decoded.frames.count) == (16, 8, 1))
        let pixel = try #require(decoded.frames.first?.pixels.prefix(4))
        #expect(abs(Int(pixel[pixel.startIndex]) - 255) <= 8, "the colour comes back straight, not premultiplied")
        #expect(abs(Int(pixel[pixel.startIndex + 3]) - 128) <= 2, "the alpha survives")
    }

    @Test func aLowerQualityWeighsLess() throws {
        let image = try noise(64, seed: 7)
        let low = try #require(WebPEncoder.still(image, quality: 0.7))
        let high = try #require(WebPEncoder.still(image, quality: 0.9))
        #expect(low.count < high.count)
    }

    @Test func anAnimationKeepsItsFramesTimingAndLoop() throws {
        let writer = try #require(AnimatedWebPWriter(width: 8, height: 8, quality: 0.7))
        #expect(writer.add(try fill(8, 8, [255, 0, 0, 255]), milliseconds: 100))
        #expect(writer.add(try fill(8, 8, [0, 255, 0, 255]), milliseconds: 200))
        #expect(writer.add(try fill(8, 8, [0, 0, 255, 255]), milliseconds: 67))
        let bytes = try #require(writer.finish())
        let decoded = try #require(DecodedWebP(bytes))
        #expect((decoded.width, decoded.height, decoded.loops) == (8, 8, 0))
        #expect(decoded.frames.map(\.start) == [0, 100, 300])
        #expect(decoded.frames.map { $0.pixels[1] > 128 } == [false, true, false], "each frame is its own colour")
    }

    @Test func aWriterRefusesWhatItCannotTake() throws {
        #expect(AnimatedWebPWriter(width: 0, height: 8, quality: 0.7) == nil)
        let writer = try #require(AnimatedWebPWriter(width: 8, height: 8, quality: 0.7))
        #expect(writer.finish() == nil, "an animation of no frames")
        #expect(!writer.add(try fill(4, 8, [0, 0, 0, 255]), milliseconds: 100), "another size")
        #expect(!writer.add(try fill(8, 8, [0, 0, 0, 255]), milliseconds: 0), "no time on screen")
    }

    @Test func aTransparentPixelKeepsNoColour() throws {
        let image = try fill(4, 4, [0, 0, 0, 0])
        let bytes = try #require(WebPEncoder.still(image, quality: 0.85))
        let pixel = try #require(DecodedWebP(bytes)?.frames.first?.pixels.prefix(4))
        #expect(Array(pixel)[3] == 0)
    }
}
