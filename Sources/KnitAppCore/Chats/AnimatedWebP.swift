/// An animated WebP's own bytes with its metadata gone, so a picked sticker goes as it is but carries nothing of where or
/// when it was made (`ImageStrip.animatedWebp` in knit-next, its ADR 2026-10.8hmx). ImageIO can write no WebP, so the
/// iPhone cannot shrink one as Android does; it sends one as it is, stripped by this walk, or as a still.
///
/// Kept are `VP8X`, its EXIF and XMP bits cleared, `ICCP`, `ANIM` and every `ANMF`, whose payload must hold only a frame's
/// `ALPH` and `VP8 ` or `VP8L` bitstream. A frame carrying anything else answers `nil` rather than being rebuilt, so
/// nothing the walk does not understand goes out. `EXIF`, `XMP ` and unknown top-level chunks are dropped. Every read is
/// bounds-checked, so truncated or hostile bytes answer `nil`, and stripping is idempotent, as Android's is.
public enum AnimatedWebP {
    /// `bytes` stripped, or `nil` when they are not an animated WebP this walk fully understands.
    public static func stripped(_ bytes: [UInt8]) -> [UInt8]? {
        guard word(in: bytes, at: 0) == Tag.riff, word(in: bytes, at: brandAt) == Tag.webp,
            let length = word(in: bytes, at: wordBytes).map(Int.init)
        else {
            return nil
        }
        let end = brandAt + length
        guard end <= bytes.count, end >= headerEnd, word(in: bytes, at: vp8xAt) == Tag.vp8x,
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
        var out = riff(kept, from: bytes)
        // VP8X is the first chunk in both, so its flags sit at the same offset in what goes out.
        out[flagsAt] &= ~(Flag.exif | Flag.xmp)
        return out
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
