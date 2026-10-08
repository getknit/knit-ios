/// A JPEG's own bytes with every metadata segment taken out and nothing else touched (`ImageStrip.jpeg` in knit-next, its
/// ADR 2026-10.unqn), so a clean picture goes out as itself instead of losing a generation to a decode and a fresh
/// encode, and keeps its hash however often it is picked again.
///
/// Kept are SOI, the tables (DQT, DHT, DRI), one baseline, extended or progressive Huffman frame at 8 bits with 1 or 3
/// components, every scan with its entropy-coded data, EOI, and three segments that change how the pixels decode while
/// saying nothing about the photographer: a thumbnail-less `JFIF` APP0, the `ICC_PROFILE` APP2 chunks and the 12-byte
/// `Adobe` APP14. EXIF, XMP, MPF, comments and every other APPn go, and so does everything after the image's EOI (a gain
/// map, a Live Photo's trailer). Anything else, from arithmetic coding to a truncation, answers `nil`, which sends the
/// picture the long way: the worst a surprise can cost is the generation this saves, never a GPS position.
public enum JPEGStrip {
    /// `bytes` stripped, or `nil` when they are not a JPEG this walk fully understands.
    public static func stripped(_ bytes: [UInt8]) -> StrippedPicture? {
        guard bytes.count > Marker.length, bytes[0] == Marker.prefix, bytes[1] == Marker.soi, bytes[Marker.length] == Marker.prefix else {
            return nil
        }
        var walk = Walk(bytes: bytes)
        return walk.run()
    }

    /// The libjpeg quality `table` was scaled to from the Annex K luminance table: the table's sum over the standard's,
    /// as a percentage, run back through libjpeg's `q < 50 ? 5000 / q : 200 - 2q`. A table that is no scaled Annex K
    /// table, as Apple's encoder writes, still lands near the quality its coarseness amounts to, which is all a threshold
    /// needs.
    static func quality(of table: [Int]) -> Int {
        let scale = percent * Double(table.reduce(0, +)) / Double(annexKLumaSum)
        let quality = scale <= percent ? (doublePercent - scale) / slope : halfOfTenThousand / scale
        return min(max(Int(quality.rounded()), 1), Int(percent))
    }

    /// The sum of ITU T.81 Annex K's Table K.1, the luminance table libjpeg scales by quality.
    private static let annexKLumaSum = 3688
    private static let percent = 100.0
    private static let doublePercent = 200.0
    private static let halfOfTenThousand = 5000.0
    /// Above quality 50, libjpeg's scale falls 2 percent a point.
    private static let slope = 2.0

    /// The markers the walk names: each follows an `FF`.
    private enum Marker {
        static let prefix: UInt8 = 0xFF
        static let tem: UInt8 = 0x01
        static let sof0: UInt8 = 0xC0
        static let sof2: UInt8 = 0xC2
        static let dht: UInt8 = 0xC4
        static let rst0: UInt8 = 0xD0
        static let rst7: UInt8 = 0xD7
        static let soi: UInt8 = 0xD8
        static let eoi: UInt8 = 0xD9
        static let sos: UInt8 = 0xDA
        static let dqt: UInt8 = 0xDB
        static let dri: UInt8 = 0xDD
        static let app0: UInt8 = 0xE0
        static let app1: UInt8 = 0xE1
        static let app2: UInt8 = 0xE2
        static let app14: UInt8 = 0xEE
        static let app15: UInt8 = 0xEF
        static let com: UInt8 = 0xFE
        /// A segment's length: two bytes, big-endian, counting themselves.
        static let length = 2
    }

    /// `JFIF\0`, version, units, densities and a 0 by 0 thumbnail.
    private static let jfif = Array("JFIF".utf8) + [0]
    private static let jfifSize = 14
    /// Where JFIF's thumbnail width and height sit.
    private static let thumbnailAt = 12
    private static let iccProfile = Array("ICC_PROFILE".utf8) + [0]
    /// `Adobe`, version, two flag words and the transform byte.
    private static let adobe = Array("Adobe".utf8)
    private static let adobeSize = 12
    /// A frame header: precision, height and width, then the component count, then three bytes per component.
    private static let frameFixed = 6
    private static let heightAt = 1
    private static let widthAt = 3
    private static let componentsAt = 5
    private static let bytesPerComponent = 3
    private static let precision: UInt8 = 8
    /// A quantization table's entries, at 8 bits each, or twice the bytes at 16.
    private static let tableEntries = 64
    private static let wideTableBytes = 128
    /// A DQT table's first byte: its precision in the high half, its id in the low.
    private static let precisionShift: UInt8 = 4
    private static let idMask: UInt8 = 0x0F

    /// What the walk does with a segment.
    private enum Verdict {
        case keep, drop, refuse
    }

    /// One pass over a JPEG, copying what it keeps.
    private struct Walk {
        let bytes: [UInt8]
        var out: [UInt8] = [Marker.prefix, Marker.soi]
        var at = Marker.length
        var size: (width: Int, height: Int)?
        var luma: [Int]?
        var scanned = false

        init(bytes: [UInt8]) {
            self.bytes = bytes
            out.reserveCapacity(bytes.count)
        }

        mutating func run() -> StrippedPicture? {
            while at < bytes.count, bytes[at] == Marker.prefix {
                // Fill bytes ahead of a marker.
                while at < bytes.count, bytes[at] == Marker.prefix {
                    at += 1
                }
                guard at < bytes.count else {
                    return nil
                }
                let marker = bytes[at]
                at += 1
                if marker == Marker.eoi {
                    return finish()
                }
                guard segment(marker) else {
                    return nil
                }
            }
            return nil
        }

        /// The picture, once EOI is reached with a frame, a scan and a luminance table behind it.
        private func finish() -> StrippedPicture? {
            guard let size, scanned, let luma else {
                return nil
            }
            let quality = JPEGStrip.quality(of: luma)
            return StrippedPicture(
                bytes: out + [Marker.prefix, Marker.eoi], width: size.width, height: size.height, frames: 1, quality: quality)
        }

        /// Reads the segment `marker` opens, copying it when it is kept; `false` when the walk must give up.
        private mutating func segment(_ marker: UInt8) -> Bool {
            // A standalone marker out of place.
            guard marker != Marker.soi, marker != Marker.tem, !(Marker.rst0...Marker.rst7).contains(marker),
                at + Marker.length <= bytes.count
            else {
                return false
            }
            let length = bigEndian(at: at)
            guard length >= Marker.length, at + length <= bytes.count else {
                return false
            }
            let payload = at + Marker.length
            let payloadSize = length - Marker.length
            let verdict = verdict(on: marker, payload: payload, size: payloadSize)
            guard verdict != .refuse else {
                return false
            }
            if verdict == .keep {
                out += [Marker.prefix, marker] + bytes[at..<at + length]
            }
            at += length
            guard marker == Marker.sos else {
                return true
            }
            guard let end = entropyEnd() else {
                return false
            }
            out += bytes[at..<end]
            at = end
            scanned = true
            return true
        }

        /// Whether the segment is kept or dropped, or refused when the walk does not understand it.
        private mutating func verdict(on marker: UInt8, payload: Int, size: Int) -> Verdict {
            switch marker {
            case Marker.dqt:
                guard let table = lumaTable(payload, size) else {
                    return .refuse
                }
                luma = table ?? luma
                return .keep
            case Marker.dht, Marker.dri:
                return .keep
            case Marker.sof0...Marker.sof2:
                return frame(payload, size) ? .keep : .refuse
            case Marker.sos:
                return size > 0 && self.size != nil ? .keep : .refuse
            case Marker.app0:
                let bare = size == jfifSize && matches(jfif, at: payload) && bigEndian(at: payload + thumbnailAt) == 0
                return bare ? .keep : .drop
            case Marker.app2:
                return matches(iccProfile, at: payload) ? .keep : .drop
            case Marker.app14:
                // The decode depends on it, so one that carries more than it should is not dropped but refused.
                guard matches(adobe, at: payload) else {
                    return .drop
                }
                return size == adobeSize ? .keep : .refuse
            case Marker.app1...Marker.app15, Marker.com:
                return .drop
            default:
                // Arithmetic, lossless, hierarchical, DNL, extensions: the long way.
                return .refuse
            }
        }

        /// Reads one frame header: 8 bits, 1 or 3 components, a size; `false` for anything else or a second frame.
        private mutating func frame(_ payload: Int, _ count: Int) -> Bool {
            guard size == nil, count >= frameFixed else {
                return false
            }
            let components = Int(bytes[payload + componentsAt])
            guard bytes[payload] == precision, components == 1 || components == bytesPerComponent,
                count == frameFixed + bytesPerComponent * components
            else {
                return false
            }
            let height = bigEndian(at: payload + heightAt)
            let width = bigEndian(at: payload + widthAt)
            guard width > 0, height > 0 else {
                return false
            }
            size = (width, height)
            return true
        }

        /// Table 0's entries when this DQT defines it at 8 bits, `.some(nil)` when it defines only others, and `nil`
        /// when its tables do not tile it exactly or table 0 is 16-bit.
        private func lumaTable(_ start: Int, _ count: Int) -> [Int]?? {
            var cursor = start
            var found: [Int]?
            while cursor < start + count {
                let wide = bytes[cursor] >> precisionShift != 0
                let entries = wide ? wideTableBytes : tableEntries
                guard cursor + 1 + entries <= start + count else {
                    return nil
                }
                if bytes[cursor] & idMask == 0 {
                    guard !wide else {
                        return nil
                    }
                    found = bytes[cursor + 1..<cursor + 1 + entries].map(Int.init)
                }
                cursor += 1 + entries
            }
            return cursor == start + count ? .some(found) : nil
        }

        /// Where a scan's entropy-coded data ends: the first `FF` that starts a real marker. A stuffed `FF 00` and a
        /// restart marker belong to the scan, and an `FF` before another is fill. `nil` when the bytes end first.
        private func entropyEnd() -> Int? {
            var index = at
            while index + 1 < bytes.count {
                guard bytes[index] == Marker.prefix else {
                    index += 1
                    continue
                }
                let next = bytes[index + 1]
                if next == 0 || (Marker.rst0...Marker.rst7).contains(next) {
                    index += Marker.length
                } else if next == Marker.prefix {
                    index += 1
                } else {
                    return index
                }
            }
            return nil
        }

        /// The big-endian 16-bit number at `offset`, which the caller has bounds-checked.
        private func bigEndian(at offset: Int) -> Int {
            Int(bytes[offset]) << UInt8.bitWidth | Int(bytes[offset + 1])
        }

        private func matches(_ prefix: [UInt8], at offset: Int) -> Bool {
            offset + prefix.count <= bytes.count && bytes[offset..<offset + prefix.count].elementsEqual(prefix)
        }
    }
}
