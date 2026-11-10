public import Foundation
import KnitWire

/// A web address in a message's words (`UrlSpan` in knit-next's `MentionText.kt`): where it sits, in UTF-16 offsets as
/// written, and the address a tap opens.
public struct MessageLink: Sendable, Equatable {
    /// Where the address sits in the words, as the sender wrote it.
    public var range: Range<Int>
    /// What a tap opens: the words themselves, or `https://` before them for a bare `www.` address.
    public var url: String

    /// A link.
    public init(range: Range<Int>, url: String) {
        self.range = range
        self.url = url
    }

    /// The address as the sender wrote it in `text`, the words it was found in, or ``url`` when they no longer hold it.
    public func written(in text: String) -> String {
        let units = Array(text.utf16)
        guard range.upperBound <= units.count else {
            return url
        }
        return String(decoding: units[range], as: UTF16.self)
    }

    /// ``url`` as Foundation reads it, or `nil` when it cannot, and the words stay words. Foundation percent-encodes what a
    /// URL may not hold, so an address with a space-free non-ASCII path still opens.
    public var target: URL? {
        URL(string: url)
    }
}

/// Android's rule for which words are a web address, `findUrls` in `MentionText.kt` (knit-next `057c70b8e`, ADR
/// 2026-11.w5ew): `(?i)(?:https?://|www\.)[^\s<>]+`, scanned left to right, each match trimmed of the punctuation that
/// ends a sentence and of closing brackets it does not open. Offsets count UTF-16 code units, as Kotlin's do, so a link
/// sits where Android draws it.
public enum LinkText {
    /// The web addresses in `text`, in order (`findUrls`, `MentionText.kt:270-288`). An address starts at `http://`,
    /// `https://` or `www.`, in any case, and runs to whitespace, `<` or `>`. Whitespace is regex `\s` on ART, Unicode
    /// White_Space (ADR 2026-10.7uyt), not the desktop JDK's ASCII set that knit-next's unit tests run under. An email
    /// address or a `geo:` position is no link.
    public static func links(in text: String) -> [MessageLink] {
        let units = Array(text.utf16)
        var links: [MessageLink] = []
        var start = 0
        while start < units.count {
            guard let prefix = prefixLength(in: units, at: start), start + prefix < units.count, !ends(units[start + prefix]) else {
                start += 1
                continue
            }
            var matched = start + prefix
            while matched < units.count, !ends(units[matched]) {
                matched += 1
            }
            let end = trimmed(units, from: start, to: matched)
            // Only the prefix survived the trim, as in "www..": no link (`raw.length <= schemeLen`).
            if end - start > prefix {
                let written = String(decoding: units[start..<end], as: UTF16.self)
                links.append(MessageLink(range: start..<end, url: prefix == www.count ? "https://" + written : written))
            }
            // The next match starts where this one's run ended, before the trim, as `findAll` resumes.
            start = matched
        }
        return links
    }

    /// The length of the prefix that opens an address at `index`, `https://`, `http://` or `www.`, or `nil`. Letters
    /// match in either case. ICU's case folding takes a few other letters too, such as U+017F for "s": a crafted address
    /// spelled with one is a link on Android and words here.
    private static func prefixLength(in units: [UInt16], at index: Int) -> Int? {
        [https, http, www].first { opens(units, at: index, with: $0) }?.count
    }

    /// Whether `units` holds `prefix` at `index`, ASCII letters in either case.
    private static func opens(_ units: [UInt16], at index: Int, with prefix: [UInt16]) -> Bool {
        guard index + prefix.count <= units.count else {
            return false
        }
        return prefix.indices.allSatisfy { offset in
            let unit = units[index + offset]
            let folded = (upperA...upperZ).contains(unit) ? unit + caseOffset : unit
            return folded == prefix[offset]
        }
    }

    /// Whether `unit` ends an address: regex `\s` on ART, `<` or `>`. Half of a surrogate pair never does, as Java's regex
    /// reads a pair, or a lone half, as one code point that is no whitespace.
    private static func ends(_ unit: UInt16) -> Bool {
        unit == lessThan || unit == greaterThan || (Unicode.Scalar(unit).map(TextLimits.isJavaRegexWhitespace) ?? false)
    }

    /// `end` moved back past trailing sentence punctuation and closing brackets the address does not open, never below
    /// `start` (`trimTrailing`, `MentionText.kt:291-321`): "(see https://x.com)." keeps "https://x.com", and
    /// "Mesh_(networking)" keeps its own bracket. Each kind of bracket counts apart.
    private static func trimmed(_ units: [UInt16], from start: Int, to end: Int) -> Int {
        // Opening brackets are never trimmed, so their counts hold; a closing one leaves its count as it goes. Both are
        // keyed by the closing bracket.
        var opened: [UInt16: Int] = [:]
        var closed: [UInt16: Int] = [:]
        for unit in units[start..<end] {
            if let answer = closing[unit] {
                opened[answer, default: 0] += 1
            } else if closing.values.contains(unit) {
                closed[unit, default: 0] += 1
            }
        }
        var end = end
        while end > start {
            let unit = units[end - 1]
            if trailingPunctuation.contains(unit) {
                end -= 1
            } else if let count = closed[unit], opened[unit, default: 0] < count {
                closed[unit] = count - 1
                end -= 1
            } else {
                break
            }
        }
        return end
    }

    private static let https = Array("https://".utf16)
    private static let http = Array("http://".utf16)
    private static let www = Array("www.".utf16)
    private static let upperA = UInt16(UInt8(ascii: "A"))
    private static let upperZ = UInt16(UInt8(ascii: "Z"))
    private static let caseOffset = UInt16(UInt8(ascii: "a") - UInt8(ascii: "A"))
    private static let lessThan = UInt16(UInt8(ascii: "<"))
    private static let greaterThan = UInt16(UInt8(ascii: ">"))

    /// Each opening bracket and the closing one that answers it.
    private static let closing: [UInt16: UInt16] = [
        UInt16(UInt8(ascii: "(")): UInt16(UInt8(ascii: ")")),
        UInt16(UInt8(ascii: "[")): UInt16(UInt8(ascii: "]")),
        UInt16(UInt8(ascii: "{")): UInt16(UInt8(ascii: "}")),
    ]

    /// Punctuation that ends a sentence after an address and is no part of it (`TRAILING_PUNCT`, `MentionText.kt:261`):
    /// `.,;:!?"'` and the closing quotes ” ’ ».
    private static let trailingPunctuation = Set(".,;:!?\"'\u{201D}\u{2019}\u{BB}".utf16)
}
