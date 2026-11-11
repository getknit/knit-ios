import KnitWire

/// A page's text encoding, as ``OpenGraphParser/charsetOf(_:contentType:decoder:)`` names it: one this module decodes
/// itself, or one only the platform's decoder reads, by the name the page gave it.
public enum PageCharset: Sendable, Equatable {
    /// UTF-8, which a page with no other word is read as.
    case utf8
    /// UTF-16, big-endian; a page labelled UTF-16 with no byte-order mark reads this way, as ICU reads it.
    case utf16BigEndian
    /// UTF-16, little-endian.
    case utf16LittleEndian
    /// ISO-8859-1: each byte is the code point of its value, 0x80 to 0x9F the C1 controls.
    case isoLatin1
    /// windows-1252 as ICU maps it, the five bytes Microsoft leaves out read as C1 controls.
    case windows1252
    /// US-ASCII, each byte past 0x7F read as U+FFFD.
    case usASCII
    /// A charset by the name the page gave it, which only the decoder handed to ``OpenGraphParser`` reads.
    case named(String)
}

/// Charsets (`charsetOf` and `decode` in knit-next's `OpenGraphParser.kt`).
extension OpenGraphParser {
    /// The platform's text decoder for the charsets this module leaves to it: `bytes` as text in the charset IANA names
    /// `ianaName`, malformed input replaced, or `nil` when it can't read them, which sends the sniff on to the next source
    /// as an unknown name does. On the iPhone it is CFString's. ``charsetOf(_:contentType:decoder:)`` calls it too.
    public typealias CharsetDecoder = @Sendable (_ ianaName: String, _ bytes: [UInt8]) -> String?

    /// The charset `bytes` are read with (`charsetOf`): a byte-order mark first, then a `charset` parameter in
    /// `contentType`, then a `<meta charset>` or `http-equiv` found in the first ``charsetSniffBytes``, then UTF-8. A name
    /// that neither ART's lookup of this module's charsets nor `decoder` knows falls through to the next source, as a
    /// name the JVM doesn't know does.
    ///
    /// Android's fetcher hands over the type alone (`text/html`), its parameters dropped, so in practice the order is the
    /// mark, the page's own word, then UTF-8. The parameter's rule is kept as Kotlin has it.
    public static func charsetOf(_ bytes: [UInt8], contentType: String?, decoder: CharsetDecoder? = nil) -> PageCharset {
        sniff(bytes, contentType: contentType, decoder: decoder).charset
    }

    /// `bytes` as text under ``charsetOf(_:contentType:decoder:)``, the byte-order mark dropped and malformed input
    /// replaced with U+FFFD, never thrown (`decode`).
    public static func decode(_ bytes: [UInt8], contentType: String?, decoder: CharsetDecoder? = nil) -> String {
        let sniffed = sniff(bytes, contentType: contentType, decoder: decoder)
        return sniffed.text ?? decodeHere(sniffed.charset, bytes[sniffed.bodyStart...])
    }

    /// What the sniff found: the charset, where the text starts past a byte-order mark, and the text when the platform's
    /// decoder already read it.
    private struct Sniffed {
        var charset: PageCharset
        var bodyStart = 0
        var text: String?
    }

    /// `charsetOf`'s order, source by source.
    private static func sniff(_ bytes: [UInt8], contentType: String?, decoder: CharsetDecoder?) -> Sniffed {
        for (mark, charset) in byteOrderMarks where bytes.starts(with: mark) {
            return Sniffed(charset: charset, bodyStart: mark.count)
        }
        let names = [contentType.flatMap { charsetParameter(in: ICUText($0)) }, metaCharset(in: bytes)]
        for case let name? in names {
            if let charset = PageCharset(artName: name) {
                return Sniffed(charset: charset)
            }
            if let text = decoder?(name, bytes) {
                return Sniffed(charset: .named(name), text: text)
            }
        }
        return Sniffed(charset: .utf8)
    }

    /// `CHARSET_PARAM.find(contentType)`, `charset\s*=\s*["']?([\w.:-]+)` without regard to case: the first name.
    private static func charsetParameter(in text: ICUText) -> String? {
        for start in 0..<text.count {
            if let name = charsetName(in: text, at: start) {
                return text.string(name)
            }
        }
        return nil
    }

    /// `META_CHARSET.find(head)`, `<meta\b[^>]*charset\s*=\s*["']?([\w.:-]+)` without regard to case, over the first
    /// ``charsetSniffBytes`` read as ISO-8859-1. The first `<meta` that holds one wins, and within it the last `charset`
    /// before its `>`, since the greedy `[^>]*` gives back from the right.
    private static func metaCharset(in bytes: [UInt8]) -> String? {
        let head = ICUText(units: bytes.prefix(charsetSniffBytes).map(UInt16.init))
        var at = 0
        while let open = head.firstIndex(of: lessThan, from: at) {
            at = open + 1
            guard let nameEnd = head.matchCaseless(metaOpen, at: open), head.isWordBoundary(afterWordAt: nameEnd) else {
                continue
            }
            let tagEnd = head.firstIndex(of: greaterThan, from: nameEnd) ?? head.count
            if let name = (nameEnd..<tagEnd).reversed().lazy.compactMap({ charsetName(in: head, at: $0) }).first {
                return head.string(name)
            }
        }
        return nil
    }

    /// `charset\s*=\s*["']?([\w.:-]+)` at `start`: where the name sits, or `nil`. A quote is skipped when a name follows
    /// it; without one, the quote is no name character and nothing matches.
    private static func charsetName(in text: ICUText, at start: Int) -> Range<Int>? {
        guard let keyEnd = text.matchCaseless(charsetKey, at: start) else {
            return nil
        }
        let equalsAt = text.skippingWhitespace(from: keyEnd)
        guard text.unit(at: equalsAt) == equalsSign else {
            return nil
        }
        var nameStart = text.skippingWhitespace(from: equalsAt + 1)
        if text.unit(at: nameStart) == doubleQuote || text.unit(at: nameStart) == singleQuote {
            nameStart += 1
        }
        let nameEnd = text.skipping(from: nameStart) { charsetNameCharacters.contains($0) || ICUText.isWord($0) }
        return nameEnd > nameStart ? nameStart..<nameEnd : nil
    }

    /// `body` read in one of this module's charsets. A named charset never arrives here: its decoder read it already.
    private static func decodeHere(_ charset: PageCharset, _ body: ArraySlice<UInt8>) -> String {
        switch charset {
        case .utf16BigEndian:
            utf16(body, bigEndian: true)
        case .utf16LittleEndian:
            utf16(body, bigEndian: false)
        case .isoLatin1:
            String(decoding: body.map(UInt16.init), as: UTF16.self)
        case .windows1252:
            String(decoding: body.map { windows1252C1.contains($0) ? windows1252High[Int($0 - c1Start)] : UInt16($0) }, as: UTF16.self)
        case .usASCII:
            String(decoding: body.map { $0 < asciiEnd ? UInt16($0) : replacementCharacter }, as: UTF16.self)
        case .utf8, .named:
            // swiftlint:disable:next optional_data_string_conversion - malformed bytes become U+FFFD, as ART's decoder makes them
            String(decoding: body, as: UTF8.self)
        }
    }

    /// `body` as UTF-16 units, each unpaired surrogate replaced. A last odd byte is replaced too, with an unpaired lead
    /// surrogate before it in the same U+FFFD, as ICU reports the two as one truncated character.
    private static func utf16(_ body: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        let bytes = Array(body)
        var units = stride(from: 0, to: bytes.count - 1, by: unitBytes).map { index in
            let first = UInt16(bytes[index])
            let second = UInt16(bytes[index + 1])
            return bigEndian ? first << byteShift | second : second << byteShift | first
        }
        if !bytes.count.isMultiple(of: unitBytes) {
            if let last = units.last, UTF16.isLeadSurrogate(last) {
                units.removeLast()
            }
            units.append(replacementCharacter)
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// The byte-order marks, U+FEFF in UTF-8 and in each order of UTF-16, longest first, and what each says.
    private static let byteOrderMarks: [([UInt8], PageCharset)] = [
        (Array("\u{FEFF}".utf8), .utf8), (bigEndianMark, .utf16BigEndian), (bigEndianMark.reversed(), .utf16LittleEndian),
    ]
    /// U+FEFF, big-endian.
    private static let bigEndianMark: [UInt8] = [0xFE, 0xFF] // swiftlint:disable:this no_magic_numbers - U+FEFF's bytes
    private static let charsetKey = Array("charset".utf8)
    /// What a charset name holds besides `\w`: `[\w.:-]`.
    private static let charsetNameCharacters: Set<Unicode.Scalar> = [".", ":", "-"]
    /// The bytes 0x80 to 0x9F, where windows-1252 departs from ISO-8859-1.
    private static let windows1252C1: ClosedRange<UInt8> = 0x80...0x9F
    private static let c1Start: UInt8 = 0x80
    /// windows-1252's 0x80 to 0x9F in order, as ICU's table (`ibm-5348_P100-1997`) maps them; the five Microsoft leaves
    /// out (0x81, 0x8D, 0x8F, 0x90, 0x9D) are the C1 controls of their own values. Every other byte is ISO-8859-1's.
    private static let windows1252High = Array(
        ("\u{20AC}\u{81}\u{201A}\u{192}\u{201E}\u{2026}\u{2020}\u{2021}\u{2C6}\u{2030}\u{160}\u{2039}\u{152}\u{8D}\u{17D}\u{8F}"
            + "\u{90}\u{2018}\u{2019}\u{201C}\u{201D}\u{2022}\u{2013}\u{2014}\u{2DC}\u{2122}\u{161}\u{203A}\u{153}\u{9D}\u{17E}\u{178}")
            .utf16)
    private static let asciiEnd: UInt8 = 0x80
    /// A UTF-16 unit's bytes.
    private static let unitBytes = 2
    private static let byteShift: UInt16 = 8
    private static let replacementCharacter: UInt16 = 0xFFFD
}
