import KnitWire

/// JPEGs built segment by segment, as `JPEGStripTests` builds them, and the two real EXIF blocks from knit-ios #12, for
/// every target that tests a picture's EXIF-less name (``ExiflessJPEG``, ADR 2026-10.f3mv).
public enum JPEGFixture {
    /// A segment: `FF`, its marker, its big-endian length counting itself, then `payload`.
    public static func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let length = payload.count + 2
        return [0xFF, marker, UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)] + payload
    }

    /// An EXIF APP1 around `tiff`.
    public static func exif(_ tiff: [UInt8]) -> [UInt8] {
        segment(0xE1, Array("Exif".utf8) + [0, 0] + tiff)
    }

    /// One IFD entry: its tag, its type, its count and its 4-byte value field, in the TIFF's byte order.
    public struct TIFFEntry: Sendable {
        public let tag: Int
        public let type: Int
        public let count: Int
        public let value: [UInt8]

        /// An entry.
        public init(tag: Int, type: Int, count: Int, value: [UInt8]) {
            self.tag = tag
            self.type = type
            self.count = count
            self.value = value
        }
    }

    /// A TIFF structure whose IFD0 holds `entries`, little-endian (`II`) or big-endian (`MM`).
    public static func tiff(little: Bool, entries: [TIFFEntry]) -> [UInt8] {
        func number(_ value: Int, _ size: Int) -> [UInt8] {
            let bytes = (0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * (size - 1 - $0))) }
            return little ? bytes.reversed() : bytes
        }
        let header = little ? Array("II*\0".utf8) : Array("MM\0*".utf8)
        var tiff = header + number(8, 4) + number(entries.count, 2)
        for entry in entries {
            tiff += number(entry.tag, 2) + number(entry.type, 2) + number(entry.count, 4) + entry.value
        }
        return tiff + number(0, 4)
    }

    /// A TIFF whose IFD0 holds only an orientation, one SHORT, in either byte order.
    public static func orientationTIFF(_ orientation: Int, little: Bool) -> [UInt8] {
        let value = [UInt8(truncatingIfNeeded: orientation >> 8), UInt8(truncatingIfNeeded: orientation)]
        return tiff(
            little: little, entries: [TIFFEntry(tag: 0x0112, type: 3, count: 1, value: (little ? value.reversed() : value) + [0, 0])])
    }

    public static let soi: [UInt8] = [0xFF, 0xD8]
    public static let eoi: [UInt8] = [0xFF, 0xD9]
    /// A bare JFIF APP0.
    public static let app0 = segment(0xE0, Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
    /// An XMP APP1, which is no EXIF and stays.
    public static let xmp = segment(0xE1, Array("http://ns.adobe.com/xap/1.0/\0<x:xmpmeta/>".utf8))
    /// An MPF APP2, whose offsets count from its own header.
    public static let mpf = segment(0xE2, Array("MPF\0".utf8) + [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8])
    public static let dqt = segment(0xDB, [0] + [UInt8](repeating: 9, count: 64))
    public static let frame = segment(0xC0, [8, 0x01, 0xE0, 0x02, 0x80, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
    public static let dht = segment(0xC4, [UInt8](repeating: 3, count: 20))
    public static let sos = segment(0xDA, [3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0])
    /// Entropy-coded data with a stuffed `FF 00`, a restart marker and an `FF E1` that is no segment, all the scan's.
    public static let entropy: [UInt8] = [0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56, 0xFF, 0x00, 0xE1, 0x78]

    /// A baseline JPEG: SOI, then `exif` where an encoder puts it, the tables, `extra` after them as an APP2 follows the
    /// DHTs in #12's files, a frame, a scan with `scan` as its entropy-coded data, EOI and `trailer`.
    public static func jpeg(
        exif: [[UInt8]] = [], extra: [[UInt8]] = [], scan: [UInt8] = entropy, trailer: [UInt8] = []
    ) -> [UInt8] {
        soi + app0 + exif.flatMap(\.self) + xmp + mpf + dqt + frame + dht + extra.flatMap(\.self) + sos + scan + eoi + trailer
    }

    /// The EXIF APP1 Knit for Android wrote on a Pixel 9 (#12), 54 bytes from its `FF E1`: big-endian, IFD0 holding only
    /// the ExifIFD pointer, whose IFD holds only ExifVersion `0232`. It has no orientation tag.
    public static let androidExif = hex(
        "ffe100344578696600004d4d002a00000008000187690004000000010000001a00000000000190000007000000043032333200000000")

    /// The EXIF APP1 Photos wrote over ``androidExif`` on import (#12), 302 bytes: big-endian, IFD0 holding Orientation 1,
    /// the resolutions, YCbCrPositioning and the ExifIFD pointer, which holds the version, ComponentsConfiguration,
    /// FlashpixVersion, ColorSpace, the pixel dimensions and SceneCaptureType, and IFD1 a thumbnail. The thumbnail is
    /// replaced by `FFD8FFD9`, its length set to 4. It holds no position, date or device id.
    public static let appleExif = hex(
        "ffe1012c4578696600004d4d002a000000080006011200030000000100010000011a00050000000100000056011b0005000000010000005e"
            + "012800030000000100020000021300030000000100010000876900040000000100000066000000c00000004800000001000000480000"
            + "00010007900000070000000430323332910100070000000401020300a00000070000000430313030a00100030000000100010000a002"
            + "000400000001000003c3a00300040000000100000500a40600030000000100000000000000000006010300030000000100060000011a"
            + "0005000000010000010e011b0005000000010000011601280003000000010002000002010004000000010000011e02020004000000"
            + "01000000040000000000000048000000010000004800000001ffd8ffd90000")

    private static func hex(_ text: String) -> [UInt8] {
        guard let bytes = Hex.decode(text) else {
            fatalError("a pinned block is hex")
        }
        return bytes
    }
}
