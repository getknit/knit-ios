/// A WebP's own bytes with its metadata gone, so a picked picture goes as it is but carries nothing of where or when it
/// was made (`ImageStrip` in knit-next, its ADRs 2026-10.unqn and 2026-10.8hmx). Kept is only what a decoder needs to
/// draw the same pixels in the same colours, and anything the walk does not fully understand answers `nil`, which
/// sends the picture the long way: decoded and written again. Every read is bounds-checked, so truncated or hostile
/// bytes answer `nil`, and stripping is idempotent, as Android's is, so a picture picked again keeps its hash.
public enum WebPStrip {
    /// `bytes` stripped as an animated WebP, or `nil` when they are not one this walk fully understands.
    ///
    /// Kept are `VP8X`, its EXIF and XMP bits cleared, `ICCP`, `ANIM` and every `ANMF`, whose payload must hold only a
    /// frame's `ALPH` and `VP8 ` or `VP8L` bitstream. A frame carrying anything else answers `nil` rather than being
    /// rebuilt. `EXIF`, `XMP ` and unknown top-level chunks are dropped.
    public static func animated(_ bytes: [UInt8]) -> StrippedPicture? {
        guard let end = riffEnd(bytes), word(in: bytes, at: vp8xAt) == Tag.vp8x,
            word(in: bytes, at: vp8xAt + wordBytes) == UInt32(vp8xSize), bytes[flagsAt] & Flag.animation != 0
        else {
            return nil
        }
        var kept = [Chunk(tag: Tag.vp8x, start: flagsAt, size: vp8xSize)]
        var animation = false
        var frames = 0
        var at = headerEnd
        while at < end {
            guard let chunk = chunk(in: bytes, at: at, end: end) else {
                return nil
            }
            switch chunk.tag {
            case Tag.iccp:
                kept.append(chunk)
            case Tag.anim:
                guard !animation, frames == 0, chunk.size == animSize else {
                    return nil
                }
                animation = true
                kept.append(chunk)
            case Tag.anmf:
                guard animation, holdsOnlyAnImage(bytes, chunk) else {
                    return nil
                }
                frames += 1
                kept.append(chunk)
            case Tag.vp8x, Tag.vp8, Tag.vp8l, Tag.alph:
                // A second header, or a still's bitstream outside a frame.
                return nil
            default:
                // EXIF, XMP and anything unknown: dropped.
                break
            }
            at = chunk.next
        }
        guard frames > 0 else {
            return nil
        }
        return extended(kept, from: bytes, frames: frames, quality: nil)
    }

    /// `bytes` stripped as a still lossy WebP, or `nil` when they are not one this walk fully understands.
    ///
    /// A simple lossy file carries no metadata and is kept whole. An extended one keeps `VP8X`, its EXIF and XMP bits
    /// cleared, `ICCP`, `ALPH` and its one `VP8 ` frame. A lossless (`VP8L`) WebP answers `nil`, since it is PNG-sized
    /// and worth the re-encode, and so does an animated one, which ``animated(_:)`` takes.
    public static func still(_ bytes: [UInt8]) -> StrippedPicture? {
        guard let end = riffEnd(bytes), let first = chunk(in: bytes, at: vp8xAt, end: end) else {
            return nil
        }
        if first.tag == Tag.vp8 {
            guard let (width, height) = vp8Size(bytes, first) else {
                return nil
            }
            return StrippedPicture(bytes: riff([first], from: bytes), width: width, height: height, frames: 1, quality: nil)
        }
        guard first.tag == Tag.vp8x, first.size == vp8xSize, bytes[flagsAt] & Flag.animation == 0 else {
            return nil
        }
        var kept: [Chunk] = []
        var frames = 0
        var at = vp8xAt
        while at < end {
            guard let chunk = chunk(in: bytes, at: at, end: end) else {
                return nil
            }
            switch chunk.tag {
            case Tag.vp8x where kept.isEmpty, Tag.iccp, Tag.alph:
                kept.append(chunk)
            case Tag.vp8:
                frames += 1
                kept.append(chunk)
            case Tag.vp8x, Tag.vp8l, Tag.anim, Tag.anmf:
                return nil
            default:
                // EXIF, XMP and anything unknown: dropped.
                break
            }
            at = chunk.next
        }
        guard frames == 1 else {
            return nil
        }
        return extended(kept, from: bytes, frames: frames, quality: nil)
    }

    /// Where a RIFF/WEBP file's chunks end, when its header says so and the bytes hold them.
    private static func riffEnd(_ bytes: [UInt8]) -> Int? {
        guard word(in: bytes, at: 0) == Tag.riff, word(in: bytes, at: brandAt) == Tag.webp,
            let length = word(in: bytes, at: wordBytes).map(Int.init)
        else {
            return nil
        }
        let end = brandAt + length
        return end <= bytes.count && end >= headerEnd ? end : nil
    }

    /// An extended file holding `kept`, `VP8X` first, with its EXIF and XMP bits cleared, and its canvas's size.
    private static func extended(_ kept: [Chunk], from bytes: [UInt8], frames: Int, quality: Int?) -> StrippedPicture? {
        var out = riff(kept, from: bytes)
        // VP8X is the first chunk in both, so its flags sit at the same offset in what goes out.
        out[flagsAt] &= ~(Flag.exif | Flag.xmp)
        return StrippedPicture(
            bytes: out,
            width: 1 + triple(in: bytes, at: canvasAt),
            height: 1 + triple(in: bytes, at: canvasAt + tripleBytes),
            frames: frames,
            quality: quality
        )
    }

    /// A lossy key frame's width and height, from its header (RFC 6386 section 9.1), or `nil` for anything else.
    private static func vp8Size(_ bytes: [UInt8], _ frame: Chunk) -> (Int, Int)? {
        let at = frame.start
        guard frame.size >= keyFrameHeader, bytes[at] & 1 == 0,
            Array(bytes[at + startCodeAt..<at + startCodeAt + startCode.count]) == startCode
        else {
            return nil
        }
        let width = littleEndian(in: bytes, at: at + sizeAt) & sizeMask
        let height = littleEndian(in: bytes, at: at + sizeAt + halfWordBytes) & sizeMask
        return width > 0 && height > 0 ? (width, height) : nil
    }

    /// The little-endian 16-bit number at `offset`, which the caller has bounds-checked.
    private static func littleEndian(in bytes: [UInt8], at offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << UInt8.bitWidth
    }

    /// The little-endian 24-bit number at `offset`, which the caller has bounds-checked.
    private static func triple(in bytes: [UInt8], at offset: Int) -> Int {
        bytes[offset..<offset + tripleBytes].reversed().reduce(0) { $0 << UInt8.bitWidth | Int($1) }
    }

    /// The tags this walk knows: four ASCII characters, read as a little-endian word.
    private enum Tag {
        static let riff = word("RIFF")
        static let webp = word("WEBP")
        static let vp8x = word("VP8X")
        static let iccp = word("ICCP")
        static let anim = word("ANIM")
        static let anmf = word("ANMF")
        static let alph = word("ALPH")
        static let vp8 = word("VP8 ")
        static let vp8l = word("VP8L")

        private static func word(_ tag: String) -> UInt32 {
            tag.utf8.reversed().reduce(0) { $0 << UInt8.bitWidth | UInt32($1) }
        }
    }

    /// `VP8X`'s flag bits.
    private enum Flag {
        static let animation: UInt8 = 0x02
        static let xmp: UInt8 = 0x04
        static let exif: UInt8 = 0x08
    }

    /// A tag, and a length, each a little-endian word.
    private static let wordBytes = 4
    /// A chunk's header: its tag and its length.
    private static let chunkHeader = wordBytes + wordBytes
    /// Where the RIFF header names the file a WebP, and where its length counts from.
    private static let brandAt = 8
    /// Where `VP8X` starts: the first chunk.
    private static let vp8xAt = 12
    /// Where `VP8X`'s data starts, its flags byte first.
    private static let flagsAt = vp8xAt + chunkHeader
    private static let vp8xSize = 10
    /// Where the first chunk after `VP8X` starts.
    private static let headerEnd = flagsAt + vp8xSize
    private static let animSize = 6
    /// Where `VP8X` gives its canvas's width and then its height, each less one, in three bytes.
    private static let canvasAt = flagsAt + wordBytes
    private static let tripleBytes = 3
    /// A lossy key frame's header: its frame tag, start code and size.
    private static let keyFrameHeader = 10
    private static let startCodeAt = 3
    // swiftlint:disable:next no_magic_numbers
    private static let startCode: [UInt8] = [0x9D, 0x01, 0x2A] // RFC 6386's start code, which no name would explain
    private static let sizeAt = 6
    private static let halfWordBytes = 2
    /// A key frame's width and height are 14 bits, under 2 bits of scale.
    private static let sizeMask = 0x3FFF
    /// A frame's position, size, duration and flags, ahead of its bitstream in an `ANMF`.
    private static let frameHeader = 16

    /// One chunk: its tag, where its data sits and how long it is, and where the chunk after it starts.
    private struct Chunk {
        var tag: UInt32
        var start: Int
        var size: Int

        var next: Int {
            start + size + size & 1
        }
    }

    /// The chunk whose header is at `at`, when it ends by `end`.
    private static func chunk(in bytes: [UInt8], at: Int, end: Int) -> Chunk? {
        guard at + chunkHeader <= end, let tag = word(in: bytes, at: at), let size = word(in: bytes, at: at + wordBytes),
            at + chunkHeader + Int(size) <= end
        else {
            return nil
        }
        return Chunk(tag: tag, start: at + chunkHeader, size: Int(size))
    }

    /// Whether `frame`, an `ANMF`, holds its header and then only `ALPH`, `VP8 ` or `VP8L`, one image at most and the
    /// alpha ahead of it.
    private static func holdsOnlyAnImage(_ bytes: [UInt8], _ frame: Chunk) -> Bool {
        var at = frame.start + frameHeader
        let end = frame.start + frame.size
        var image = false
        while at < end {
            guard let chunk = chunk(in: bytes, at: at, end: end), !image else {
                return false
            }
            switch chunk.tag {
            case Tag.alph:
                break
            case Tag.vp8, Tag.vp8l:
                image = true
            default:
                return false
            }
            at = chunk.next
        }
        return image
    }

    /// A RIFF/WEBP file holding `chunks` copied from `source`, each padded to an even length.
    private static func riff(_ chunks: [Chunk], from source: [UInt8]) -> [UInt8] {
        var body: [UInt8] = []
        for chunk in chunks {
            body += littleEndian(chunk.tag) + littleEndian(UInt32(chunk.size)) + source[chunk.start..<chunk.start + chunk.size]
            if chunk.size & 1 == 1 {
                body.append(0)
            }
        }
        return littleEndian(Tag.riff) + littleEndian(UInt32(wordBytes + body.count)) + littleEndian(Tag.webp) + body
    }

    /// The little-endian word at `offset`, or `nil` past the end.
    private static func word(in bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + wordBytes <= bytes.count else {
            return nil
        }
        return bytes[offset..<offset + wordBytes].reversed().reduce(0) { $0 << UInt8.bitWidth | UInt32($1) }
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<wordBytes).map { UInt8(truncatingIfNeeded: value >> ($0 * UInt8.bitWidth)) }
    }
}
