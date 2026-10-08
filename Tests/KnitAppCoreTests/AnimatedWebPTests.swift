import Testing

@testable import KnitAppCore

/// A picked animated WebP leaves with its metadata gone, as Android's `ImageStrip.animatedWebp` strips one (knit-next ADR
/// 2026-10.8hmx), and anything the walk does not fully understand answers `nil`, so it goes as a still instead.
@Suite struct AnimatedWebPTests {
    private static let exifFlag: UInt8 = 0x08
    private static let xmpFlag: UInt8 = 0x04
    private static let animationFlag: UInt8 = 0x02

    private func chunk(_ tag: String, _ payload: [UInt8]) -> [UInt8] {
        let size = payload.count
        return Array(tag.utf8) + (0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) } + payload
            + (size % 2 == 1 ? [0] : [])
    }

    private func riff(_ chunks: [[UInt8]]) -> [UInt8] {
        let body = chunks.flatMap(\.self)
        let size = 4 + body.count
        return Array("RIFF".utf8) + (0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) } + Array("WEBP".utf8) + body
    }

    /// `VP8X` with `flags`, for a 480 by 270 canvas.
    private func vp8x(_ flags: UInt8) -> [UInt8] {
        chunk("VP8X", [flags, 0, 0, 0, 0xDF, 0x01, 0x00, 0x0D, 0x01, 0x00])
    }

    private let anim = [UInt8](repeating: 0, count: 6)
    private let frameHeader = [UInt8](repeating: 1, count: 16)

    private func frame(_ chunks: [[UInt8]]) -> [UInt8] {
        chunk("ANMF", frameHeader + chunks.flatMap(\.self))
    }

    private var lossless: [UInt8] {
        chunk("VP8L", [0x2F, 1, 2, 3, 4])
    }

    @Test func metadataIsDroppedAndItsFlagsCleared() throws {
        let flags = Self.animationFlag | Self.exifFlag | Self.xmpFlag
        let picked = riff([
            vp8x(flags), chunk("ICCP", [9, 9, 9]), chunk("ANIM", anim), frame([chunk("ALPH", [7]), lossless]),
            chunk("EXIF", Array("GPS 51.5N".utf8)), frame([lossless]), chunk("XMP ", Array("<x/>".utf8)), chunk("ZZZZ", [1]),
        ])
        let stripped = try #require(AnimatedWebP.stripped(picked))
        let expected = riff([
            vp8x(Self.animationFlag), chunk("ICCP", [9, 9, 9]), chunk("ANIM", anim), frame([chunk("ALPH", [7]), lossless]),
            frame([lossless]),
        ])
        #expect(stripped == expected)
        #expect(AnimatedWebP.stripped(stripped) == stripped, "stripping is idempotent")
    }

    @Test func aStillWebPIsNotOne() {
        #expect(AnimatedWebP.stripped(riff([vp8x(0), chunk("ANIM", anim), frame([lossless])])) == nil)
        #expect(AnimatedWebP.stripped(riff([chunk("VP8L", [0x2F, 1])])) == nil)
    }

    @Test func whatTheWalkDoesNotUnderstandIsRefused() {
        let header = vp8x(Self.animationFlag)
        let refused: [(String, [UInt8])] = [
            ("no frames", riff([header, chunk("ANIM", anim)])),
            ("a frame before ANIM", riff([header, frame([lossless]), chunk("ANIM", anim)])),
            ("a second ANIM", riff([header, chunk("ANIM", anim), chunk("ANIM", anim), frame([lossless])])),
            ("a short ANIM", riff([header, chunk("ANIM", [0, 0]), frame([lossless])])),
            ("a second header", riff([header, header, chunk("ANIM", anim), frame([lossless])])),
            ("a bitstream outside a frame", riff([header, chunk("ANIM", anim), lossless])),
            ("a frame with no image", riff([header, chunk("ANIM", anim), frame([chunk("ALPH", [7])])])),
            ("a frame with two images", riff([header, chunk("ANIM", anim), frame([lossless, lossless])])),
            ("a frame with metadata", riff([header, chunk("ANIM", anim), frame([lossless, chunk("EXIF", [1])])])),
            ("alpha after the image", riff([header, chunk("ANIM", anim), frame([lossless, chunk("ALPH", [7])])])),
            ("a short VP8X", riff([chunk("VP8X", [Self.animationFlag, 0, 0, 0]), chunk("ANIM", anim), frame([lossless])])),
        ]
        for (reason, bytes) in refused {
            #expect(AnimatedWebP.stripped(bytes) == nil, "\(reason)")
        }
    }

    /// Truncated or lying bytes answer `nil` at every length, never trap.
    @Test func truncatedOrLyingBytesAnswerNil() throws {
        let whole = riff([vp8x(Self.animationFlag), chunk("ANIM", anim), frame([lossless])])
        #expect(AnimatedWebP.stripped(whole) != nil)
        for length in 0..<whole.count {
            #expect(AnimatedWebP.stripped(Array(whole.prefix(length))) == nil)
        }
        var lying = whole
        lying[4] = 0xFF
        lying[7] = 0xFF
        #expect(AnimatedWebP.stripped(lying) == nil, "a RIFF longer than the bytes")
        var hugeChunk = whole
        let anmf = try #require(hugeChunk.indices.dropLast(4).first { Array(hugeChunk[$0..<$0 + 4]) == Array("ANMF".utf8) })
        hugeChunk.replaceSubrange(anmf + 4..<anmf + 8, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(AnimatedWebP.stripped(hugeChunk) == nil, "a chunk longer than the file")
    }
}
