import Testing

@testable import KnitAppCore

/// A clean JPEG leaves as its own bytes with its metadata gone, as Android's `ImageStrip.jpeg` strips one (knit-next ADR
/// 2026-10.unqn): the scans byte for byte, nothing that says who or where, and anything the walk does not fully
/// understand answers `nil`, so it is decoded and written again instead.
@Suite struct JPEGStripTests {
    /// ITU T.81 Annex K's luminance table, in the order libjpeg scales it.
    private static let annexK = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100,
        103, 99,
    ]

    /// Annex K scaled as libjpeg's `jpeg_set_quality` scales it.
    private func table(quality: Int) -> [UInt8] {
        let scale = quality < 50 ? 5000 / quality : 200 - 2 * quality
        return Self.annexK.map { UInt8(min(max(($0 * scale + 50) / 100, 1), 255)) }
    }

    private func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let length = payload.count + 2
        return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }

    private let soi: [UInt8] = [0xFF, 0xD8]
    private let eoi: [UInt8] = [0xFF, 0xD9]
    private let jfif = Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
    private let huffman = [UInt8](repeating: 3, count: 20)
    /// A 640 by 480 baseline frame of three components.
    private let frame: [UInt8] = [8, 0x01, 0xE0, 0x02, 0x80, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]
    private let scanHeader: [UInt8] = [3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0]
    /// Entropy-coded data with a stuffed `FF 00` and a restart marker, both of which belong to the scan.
    private let entropy: [UInt8] = [0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56]

    private func dqt(_ quality: Int) -> [UInt8] {
        segment(0xDB, [0x00] + table(quality: quality))
    }

    /// The parts every JPEG here needs, around `extra` segments placed after the tables.
    private func jpeg(quality: Int = 85, before: [[UInt8]] = [], extra: [[UInt8]] = [], trailer: [UInt8] = []) -> [UInt8] {
        soi + before.flatMap(\.self) + dqt(quality) + extra.flatMap(\.self) + segment(0xC0, frame) + segment(0xC4, huffman)
            + segment(0xDA, scanHeader) + entropy + eoi + trailer
    }

    @Test func metadataGoesAndThePixelsStay() throws {
        let icc = segment(0xE2, Array("ICC_PROFILE".utf8) + [0, 1, 1, 9, 9])
        let adobe = segment(0xEE, Array("Adobe".utf8) + [0, 100, 0, 0, 0, 0, 1])
        let picked = jpeg(
            before: [segment(0xE0, jfif), segment(0xE1, Array("Exif\0\0GPS 51.5N".utf8))],
            extra: [icc, adobe, segment(0xE1, Array("http://ns.adobe.com/xap/1.0/\0<x/>".utf8)), segment(0xFE, Array("Pixel 9".utf8))],
            trailer: Array("a Live Photo's trailer".utf8)
        )
        let stripped = try #require(JPEGStrip.stripped(picked))
        #expect(stripped.bytes == jpeg(before: [segment(0xE0, jfif)], extra: [icc, adobe]))
        #expect((stripped.width, stripped.height, stripped.frames, stripped.quality) == (640, 480, 1, 85))
        #expect(JPEGStrip.stripped(stripped.bytes) == stripped, "stripping is idempotent")
        #expect(stripped.bytes.firstRange(of: entropy) != nil, "the scan goes byte for byte")
    }

    @Test func anotherAppsSegmentAndFillBytesAreReadPast() throws {
        let ducky = segment(0xEE, Array("Ducky".utf8) + [0, 1, 0, 4, 0, 0, 0, 85])
        let picked =
            soi + dqt(85) + ducky + segment(0xC0, frame) + segment(0xC4, huffman) + segment(0xDA, scanHeader) + entropy
            + [0xFF] + eoi
        let stripped = try #require(JPEGStrip.stripped(picked))
        #expect(stripped.bytes.firstRange(of: Array("Ducky".utf8)) == nil, "an APP14 that is not Adobe's goes")
    }

    @Test func aJFIFWithAThumbnailGoes() throws {
        let thumbnail = Array(jfif.dropLast(2)) + [1, 1, 0, 0, 0]
        let stripped = try #require(JPEGStrip.stripped(jpeg(before: [segment(0xE0, thumbnail)])))
        #expect(stripped.bytes == jpeg())
    }

    @Test(arguments: [50, 75, 85, 90, 95])
    func theQualityReadsAsLibjpegScaledIt(quality: Int) throws {
        let stripped = try #require(JPEGStrip.stripped(jpeg(quality: quality)))
        let read = try #require(stripped.quality)
        #expect(abs(read - quality) <= 1)
    }

    @Test func whatTheWalkDoesNotUnderstandIsRefused() {
        let arithmetic = soi + dqt(85) + segment(0xC9, frame) + segment(0xDA, scanHeader) + entropy + eoi
        let twelveBit = replacingFrame(of: jpeg(), with: [12] + frame.dropFirst())
        let cmyk: [UInt8] = [8, 0x01, 0xE0, 0x02, 0x80, 4, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1, 4, 0x11, 1]
        let refused: [(String, [UInt8])] = [
            ("not a JPEG", Array("GIF89a".utf8)),
            ("arithmetic coding", arithmetic),
            ("12-bit", twelveBit),
            ("four components", soi + dqt(85) + segment(0xC0, cmyk) + segment(0xDA, scanHeader) + entropy + eoi),
            ("two frames", soi + dqt(85) + segment(0xC0, frame) + segment(0xC0, frame) + segment(0xDA, scanHeader) + entropy + eoi),
            ("a scan before its frame", soi + dqt(85) + segment(0xDA, scanHeader) + entropy + segment(0xC0, frame) + eoi),
            ("no scan", soi + dqt(85) + segment(0xC0, frame) + eoi),
            ("no tables", soi + segment(0xC0, frame) + segment(0xDA, scanHeader) + entropy + eoi),
            (
                "a 16-bit luminance table",
                soi + segment(0xDB, [0x10] + [UInt8](repeating: 1, count: 128)) + segment(0xC0, frame)
                    + segment(0xDA, scanHeader) + entropy + eoi
            ),
            (
                "a table that overruns",
                soi + segment(0xDB, [0x00] + [UInt8](repeating: 1, count: 70)) + segment(0xC0, frame)
                    + segment(0xDA, scanHeader) + entropy + eoi
            ),
            ("an Adobe segment too long", jpeg(extra: [segment(0xEE, Array("Adobe".utf8) + [UInt8](repeating: 0, count: 9))])),
            ("a second SOI", jpeg(extra: [soi])),
            ("no width", replacingFrame(of: jpeg(), with: [8, 0x01, 0xE0, 0, 0])),
        ]
        for (reason, bytes) in refused {
            #expect(JPEGStrip.stripped(bytes) == nil, "\(reason)")
        }
    }

    @Test func truncatedBytesAnswerNilAtEveryLength() {
        let whole = jpeg(before: [segment(0xE0, jfif)])
        #expect(JPEGStrip.stripped(whole) != nil)
        for length in 0..<whole.count {
            #expect(JPEGStrip.stripped(Array(whole.prefix(length))) == nil)
        }
    }

    // MARK: Clean enough to go as it is

    private func picture(_ width: Int, _ height: Int, bytes: Int = 10, quality: Int?, frames: Int = 1) -> StrippedPicture {
        StrippedPicture(bytes: [UInt8](repeating: 0, count: bytes), width: width, height: height, frames: frames, quality: quality)
    }

    @Test func aBoundedPictureNoSharperThanOursIsClean() {
        #expect(picture(1280, 960, quality: 85).isClean)
        #expect(picture(1280, 960, quality: ChatPhoto.sharpestPassThrough).isClean, "a point or two either side of 85")
        #expect(!picture(1280, 960, quality: ChatPhoto.sharpestPassThrough + 1).isClean, "a camera original takes one re-encode")
        #expect(!picture(1281, 960, quality: 80).isClean, "past the bound")
        #expect(picture(100, 100, bytes: 5000, quality: nil).isClean, "a WebP at half a byte a pixel")
        #expect(!picture(100, 100, bytes: 5001, quality: nil).isClean, "a heavier WebP is worth the re-encode")
        #expect(!picture(100, 100, quality: 80, frames: 2).isClean, "a moving picture has a door of its own")
    }

    /// `bytes` with the first SOF0 segment's payload replaced by `payload`, its length unchanged.
    private func replacingFrame(of bytes: [UInt8], with payload: [UInt8]) -> [UInt8] {
        guard let at = bytes.indices.dropLast().first(where: { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xC0 }) else {
            return bytes
        }
        var out = bytes
        out.replaceSubrange(at + 4..<at + 4 + payload.count, with: payload)
        return out
    }
}
