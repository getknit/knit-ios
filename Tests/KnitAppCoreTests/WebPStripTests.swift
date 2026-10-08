import Testing

@testable import KnitAppCore

/// A picked WebP leaves with its metadata gone, as Android's `ImageStrip` strips one (knit-next ADRs 2026-10.unqn and
/// 2026-10.8hmx), and anything the walk does not fully understand answers `nil`, so it takes the long way instead.
@Suite struct WebPStripTests {
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
        let sticker = try #require(WebPStrip.animated(picked))
        #expect((sticker.width, sticker.height, sticker.frames, sticker.quality) == (480, 270, 2, nil))
        let stripped = sticker.bytes
        let expected = riff([
            vp8x(Self.animationFlag), chunk("ICCP", [9, 9, 9]), chunk("ANIM", anim), frame([chunk("ALPH", [7]), lossless]),
            frame([lossless]),
        ])
        #expect(stripped == expected)
        #expect(WebPStrip.animated(stripped)?.bytes == stripped, "stripping is idempotent")
    }

    @Test func aStillWebPIsNotOne() {
        #expect(WebPStrip.animated(riff([vp8x(0), chunk("ANIM", anim), frame([lossless])])) == nil)
        #expect(WebPStrip.animated(riff([chunk("VP8L", [0x2F, 1])])) == nil)
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
            ("a frame opening on metadata", riff([header, chunk("ANIM", anim), frame([chunk("EXIF", [1]), lossless])])),
            ("alpha after the image", riff([header, chunk("ANIM", anim), frame([lossless, chunk("ALPH", [7])])])),
            ("a short VP8X", riff([chunk("VP8X", [Self.animationFlag, 0, 0, 0]), chunk("ANIM", anim), frame([lossless])])),
        ]
        for (reason, bytes) in refused {
            #expect(WebPStrip.animated(bytes) == nil, "\(reason)")
        }
    }

    /// Truncated or lying bytes answer `nil` at every length, never trap.
    @Test func truncatedOrLyingBytesAnswerNil() throws {
        let whole = riff([vp8x(Self.animationFlag), chunk("ANIM", anim), frame([lossless])])
        #expect(WebPStrip.animated(whole) != nil)
        for length in 0..<whole.count {
            #expect(WebPStrip.animated(Array(whole.prefix(length))) == nil)
        }
        var lying = whole
        lying[4] = 0xFF
        lying[7] = 0xFF
        #expect(WebPStrip.animated(lying) == nil, "a RIFF longer than the bytes")
        var hugeChunk = whole
        let anmf = try #require(hugeChunk.indices.dropLast(4).first { Array(hugeChunk[$0..<$0 + 4]) == Array("ANMF".utf8) })
        hugeChunk.replaceSubrange(anmf + 4..<anmf + 8, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(WebPStrip.animated(hugeChunk) == nil, "a chunk longer than the file")
    }

    // MARK: Stills

    /// A lossy key frame's header for a 480 by 270 picture, and a byte of bitstream.
    private let keyFrame: [UInt8] = [0x50, 0, 0, 0x9D, 0x01, 0x2A, 0xE0, 0x01, 0x0E, 0x01, 7]
    private static let alphaFlag: UInt8 = 0x10

    @Test func aSimpleStillIsKeptWhole() throws {
        let picked = riff([chunk("VP8 ", keyFrame)])
        let still = try #require(WebPStrip.still(picked))
        #expect(still == StrippedPicture(bytes: picked, width: 480, height: 270, frames: 1, quality: nil))
        #expect(WebPStrip.still(picked + [1, 2, 3])?.bytes == picked, "nothing past the RIFF goes")
    }

    @Test func anExtendedStillLosesItsMetadata() throws {
        let picked = riff([
            vp8x(Self.alphaFlag | Self.exifFlag | Self.xmpFlag), chunk("ICCP", [9, 9, 9]), chunk("ALPH", [7]), chunk("VP8 ", keyFrame),
            chunk("EXIF", Array("GPS 51.5N".utf8)), chunk("XMP ", Array("<x/>".utf8)),
        ])
        let still = try #require(WebPStrip.still(picked))
        #expect(still.bytes == riff([vp8x(Self.alphaFlag), chunk("ICCP", [9, 9, 9]), chunk("ALPH", [7]), chunk("VP8 ", keyFrame)]))
        #expect((still.width, still.height, still.frames) == (480, 270, 1))
        #expect(WebPStrip.still(still.bytes) == still, "stripping is idempotent")
    }

    @Test func aStillTheWalkDoesNotTakeIsRefused() {
        let interFrame = [keyFrame[0] | 1] + keyFrame.dropFirst()
        let refused: [(String, [UInt8])] = [
            ("lossless", riff([chunk("VP8L", [0x2F, 1])])),
            ("lossless, extended", riff([vp8x(0), lossless])),
            ("animated", riff([vp8x(Self.animationFlag), chunk("ANIM", anim), frame([lossless])])),
            ("two frames", riff([vp8x(0), chunk("VP8 ", keyFrame), chunk("VP8 ", keyFrame)])),
            ("no frame", riff([vp8x(0), chunk("ICCP", [1])])),
            ("an inter frame", riff([chunk("VP8 ", interFrame)])),
            ("no start code", riff([chunk("VP8 ", [0, 0, 0, 1, 2, 3, 0xE0, 0x01, 0x0E, 0x01])])),
            ("a second header", riff([vp8x(0), vp8x(0), chunk("VP8 ", keyFrame)])),
        ]
        for (reason, bytes) in refused {
            #expect(WebPStrip.still(bytes) == nil, "\(reason)")
        }
    }

    @Test func aTruncatedOrLyingStillAnswersNil() throws {
        let whole = riff([vp8x(0), chunk("ALPH", [7]), chunk("VP8 ", keyFrame)])
        #expect(WebPStrip.still(whole) != nil)
        for length in 0..<whole.count {
            #expect(WebPStrip.still(Array(whole.prefix(length))) == nil)
        }
        var hugeChunk = whole
        let alph = try #require(hugeChunk.indices.dropLast(4).first { Array(hugeChunk[$0..<$0 + 4]) == Array("ALPH".utf8) })
        hugeChunk.replaceSubrange(alph + 4..<alph + 8, with: [0xFF, 0xFF, 0, 0])
        #expect(WebPStrip.still(hugeChunk) == nil, "a chunk longer than the file")
    }
}
