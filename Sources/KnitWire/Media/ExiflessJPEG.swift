/// A JPEG with its EXIF left out, everything else byte for byte, and the orientation that EXIF gave it: what a picture
/// is named by on this phone apart from its exact bytes (ADR 2026-10.f3mv, knit-ios #12).
///
/// Photos rewrites a JPEG's EXIF APP1 when it imports one, and leaves every other segment and the scans as they were. A
/// photo saved from Knit and picked again then misses its exact SHA-256, so Save names it by the SHA-256 of ``kept``
/// too, and a pick that matches nothing exactly is looked up by that name. The name is local and answers only a pick:
/// it never reaches the wire, a want or a copy.
///
/// The walk follows `JPEGStrip`'s (`Sources/KnitAppCore/Chats/JPEGStrip.swift`), whose rules for SOI, fill bytes,
/// lengths and standalone markers it ports, and not its policy: only an APP1 whose payload starts `Exif\0\0` goes. XMP
/// and extended XMP, ICC, MPF and every other segment stay, and from the first SOS to the end of the input everything
/// is copied with no walk of the entropy-coded data: later scans, EOI, an Ultra HDR gain map and MPF's images. MPF's
/// offsets count from its own header, so leaving out an EXIF segment ahead of it moves none of them. Fill bytes stay,
/// so ``kept`` is the input less exactly the EXIF segments' bytes.
///
/// Anything the walk does not understand answers `nil`, which means no name and no match: a pick then goes as a new
/// blob, which is what it did before the name existed.
public struct ExiflessJPEG: Sendable, Equatable {
    /// The input with every EXIF APP1 segment left out, and nothing else changed.
    public let kept: [UInt8]
    /// IFD0's orientation, 1 to 8, and 1 when there is no EXIF or it has no orientation tag. Android counts a 0 as
    /// upright (`UPRIGHT`, `AttachmentStore.kt:514`, applied at `:451`, knit-next `5f521cb9`), so it sends such a JPEG
    /// as it is, and ImageIO draws it as 1; here it reads 1.
    public let orientation: Int

    /// `bytes` read, or `nil` when they are no JPEG this walk understands up to its first SOS, or their EXIF's
    /// orientation is not one this walk can vouch for.
    public static func read(_ bytes: [UInt8]) -> Self? {
        guard bytes.count >= Marker.length, bytes[0] == Marker.prefix, bytes[1] == Marker.soi else {
            return nil
        }
        var at = Marker.length
        var dropped: [Range<Int>] = []
        var tagged: Int?
        while true {
            // Each segment starts with an `FF`, and any run of further `FF`s ahead of its marker is fill.
            guard at < bytes.count, bytes[at] == Marker.prefix else {
                return nil
            }
            while at < bytes.count, bytes[at] == Marker.prefix {
                at += 1
            }
            guard at < bytes.count, !Marker.isStandalone(bytes[at]) else {
                return nil
            }
            let marker = bytes[at]
            let start = at - 1
            at += 1
            guard at + Marker.length <= bytes.count else {
                return nil
            }
            let length = Int(bytes[at]) << UInt8.bitWidth | Int(bytes[at + 1])
            guard length >= Marker.length, at + length <= bytes.count else {
                return nil
            }
            let payload = at + Marker.length..<at + length
            at += length
            if marker == Marker.sos {
                return Self(kept: kept(bytes, leavingOut: dropped), orientation: tagged ?? Exif.upright)
            }
            guard marker == Marker.app1, bytes[payload].starts(with: Exif.header) else {
                continue
            }
            // Two EXIF segments disagree on which orientation counts, so neither is vouched for.
            guard tagged == nil, let read = Exif.orientation(in: Array(bytes[payload.dropFirst(Exif.header.count)])) else {
                return nil
            }
            tagged = read
            dropped.append(start..<at)
        }
    }

    /// `bytes` less the ranges in `dropped`, which are in order and apart.
    private static func kept(_ bytes: [UInt8], leavingOut dropped: [Range<Int>]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var from = 0
        for range in dropped {
            out += bytes[from..<range.lowerBound]
            from = range.upperBound
        }
        out += bytes[from...]
        return out
    }

    /// The markers the walk names: each follows an `FF`.
    private enum Marker {
        static let prefix: UInt8 = 0xFF
        static let stuffed: UInt8 = 0x00
        static let tem: UInt8 = 0x01
        static let rst0: UInt8 = 0xD0
        static let soi: UInt8 = 0xD8
        static let eoi: UInt8 = 0xD9
        static let sos: UInt8 = 0xDA
        static let app1: UInt8 = 0xE1
        /// A segment's length: two bytes, big-endian, counting themselves.
        static let length = 2

        /// Whether `marker` stands alone, with no length after it, which has no place before the first SOS: a stuffed
        /// `FF 00`, TEM, a restart marker, a second SOI, or EOI. RST0 to RST7, SOI and EOI run on from `D0` to `D9`.
        static func isStandalone(_ marker: UInt8) -> Bool {
            marker == stuffed || marker == tem || (rst0...eoi).contains(marker)
        }
    }

    /// The TIFF structure an EXIF APP1 carries, as far as IFD0's orientation (CIPA DC-008, tag `0x0112`).
    private enum Exif {
        /// What an EXIF APP1's payload starts with.
        static let header = Array("Exif".utf8) + [0, 0]
        /// `II` and 42 little-endian, or `MM` and 42 big-endian.
        static let littleEndian = Array("II*\0".utf8)
        static let bigEndian = Array("MM\0*".utf8)
        /// The TIFF header: its byte order and 42, then IFD0's offset.
        static let tiffHeaderSize = 8
        static let ifdOffsetAt = 4
        /// An IFD's entry count, then 12 bytes an entry: tag, type, count, then the value or where it is.
        static let countSize = 2
        static let entrySize = 12
        static let typeAt = 2
        static let countAt = 4
        static let valueAt = 8
        static let orientationTag = 0x0112
        static let short = 3
        static let upright = 1
        static let orientations = 1...8

        /// IFD0's orientation in `tiff`, 1 when it has none and when it says 0, or `nil` when the structure is out of
        /// bounds, the tag is not one SHORT, appears twice, or says anything above 8.
        static func orientation(in tiff: [UInt8]) -> Int? {
            guard tiff.count >= tiffHeaderSize else {
                return nil
            }
            let order = Array(tiff[0..<littleEndian.count])
            guard order == littleEndian || order == bigEndian else {
                return nil
            }
            let reader = Reader(bytes: tiff, little: order == littleEndian)
            let ifd = reader.u32(at: ifdOffsetAt)
            guard ifd <= tiff.count - countSize else {
                return nil
            }
            let entries = reader.u16(at: ifd)
            let first = ifd + countSize
            guard entries <= (tiff.count - first) / entrySize else {
                return nil
            }
            var found: Int?
            for entry in stride(from: first, to: first + entries * entrySize, by: entrySize)
            where reader.u16(at: entry) == orientationTag {
                guard found == nil, reader.u16(at: entry + typeAt) == short, reader.u32(at: entry + countAt) == 1 else {
                    return nil
                }
                found = reader.u16(at: entry + valueAt)
            }
            guard let found else {
                return upright
            }
            if found == 0 {
                return upright
            }
            return orientations.contains(found) ? found : nil
        }
    }

    /// Reads TIFF numbers in one byte order, at offsets the caller has bounds-checked.
    private struct Reader {
        let bytes: [UInt8]
        let little: Bool

        func u16(at offset: Int) -> Int {
            number(at: offset, size: MemoryLayout<UInt16>.size)
        }

        func u32(at offset: Int) -> Int {
            number(at: offset, size: MemoryLayout<UInt32>.size)
        }

        private func number(at offset: Int, size: Int) -> Int {
            let ordered = little ? Array(bytes[offset..<offset + size].reversed()) : Array(bytes[offset..<offset + size])
            return ordered.reduce(0) { $0 << UInt8.bitWidth | Int($1) }
        }
    }
}
