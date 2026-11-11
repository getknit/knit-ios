import KnitWire

/// A text as UTF-16 units, read the way `java.util.regex` reads it on ART, which runs ICU (`Pattern.java`,
/// android-37.2), for the few pieces of pattern ``OpenGraphParser`` needs. A hand-written scanner rather than
/// `NSRegularExpression` or Swift's `Regex`, whose classes differ from ICU's on Linux:
/// - `\s` is Unicode White_Space, ``TextLimits/isJavaRegexWhitespace(_:)`` (ADR 2026-10.7uyt);
/// - `\w` is `[\p{Alphabetic}\p{gc=Mark}\p{Nd}\p{Pc}\p{Join_Control}]`;
/// - `CASE_INSENSITIVE` is Unicode's full case folding on ART, which ignores `UNICODE_CASE`, so `<ſcript>` opens a
///   script and `<ﬆyle>` a style, where the desktop JDK's ASCII-only folding would read neither.
///
/// The Unicode properties come from Swift's tables, which can be a version apart from ART's ICU; only letters new to
/// one of them would read differently.
internal struct ICUText {
    /// The text, unit by unit, as Kotlin's `charAt` sees it.
    let units: [UInt16]

    /// `text`'s units.
    init(_ text: String) {
        units = Array(text.utf16)
    }

    /// `units` as they are.
    init(units: [UInt16]) {
        self.units = units
    }

    /// The number of units.
    var count: Int { units.count }

    /// The unit at `index`, or `nil` past the end.
    func unit(at index: Int) -> UInt16? {
        index < units.count ? units[index] : nil
    }

    /// The units from `range` as a string.
    func string(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    /// The code point starting at `index` and its width in units, or `nil` at the end. A lone surrogate is `nil` too:
    /// ICU reads it as a code point that no class here holds, and no boundary rule skips.
    func scalar(at index: Int) -> (scalar: Unicode.Scalar, width: Int)? {
        guard index < units.count else {
            return nil
        }
        let lead = units[index]
        guard UTF16.isLeadSurrogate(lead), index + 1 < units.count, UTF16.isTrailSurrogate(units[index + 1]) else {
            return Unicode.Scalar(lead).map { ($0, 1) }
        }
        let high = (UInt32(lead) - Self.leadBase) << Self.leadShift
        return Unicode.Scalar(Self.supplementaryBase + high + UInt32(units[index + 1]) - Self.trailBase).map { ($0, Self.pairWidth) }
    }

    /// The first index at or after `start` that holds `unit`.
    func firstIndex(of unit: UInt16, from start: Int) -> Int? {
        units[min(start, units.count)...].firstIndex(of: unit)
    }

    /// Where `literal`, ASCII written in lower case, ends when it matches at `index` without regard to case, or `nil`.
    /// ICU folds the text with Unicode's full case folding and compares it unit by unit with the folded pattern, and a
    /// character whose folding runs past the pattern's end fails (`URX_STRING_I`, `CaseFoldingUTextIterator`).
    func matchCaseless(_ literal: [UInt8], at index: Int) -> Int? {
        var at = index
        var matched = 0
        while matched < literal.count {
            guard let (point, width) = scalar(at: at), let folding = Self.asciiFolding(of: point),
                matched + folding.count <= literal.count, literal[matched..<matched + folding.count].elementsEqual(folding)
            else {
                return nil
            }
            matched += folding.count
            at += width
        }
        return at
    }

    /// Whether ICU's `\b` holds at `index`, just after a word character, as every literal before a `\b` here ends in a
    /// letter: at the end of the text, or before a character that is neither a word character, a grapheme extender nor a
    /// format character. ICU never puts a boundary before one of the last two (`RegexMatcher::isWordBoundary`).
    func isWordBoundary(afterWordAt index: Int) -> Bool {
        guard let (point, _) = scalar(at: index) else {
            return true
        }
        return !(Self.isWord(point) || point.properties.isGraphemeExtend || point.properties.generalCategory == .format)
    }

    /// Past every regex `\s` from `start`.
    func skippingWhitespace(from start: Int) -> Int {
        skipping(from: start, while: TextLimits.isJavaRegexWhitespace)
    }

    /// Past every code point from `start` that `isMember` takes.
    func skipping(from start: Int, while isMember: (Unicode.Scalar) -> Bool) -> Int {
        var at = start
        while let (point, width) = scalar(at: at), isMember(point) {
            at += width
        }
        return at
    }

    /// ICU's `\w`: `[\p{Alphabetic}\p{gc=Mark}\p{Nd}\p{Pc}\p{Join_Control}]` (`Pattern.java`'s table, android-37.2).
    static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation:
            return true
        default:
            return properties.isAlphabetic || properties.isJoinControl
        }
    }

    /// `scalar`'s full case folding when it is all ASCII, the only foldings that can meet a pattern written in ASCII
    /// letters, or `nil`: ASCII itself, lower-cased, and the letters past ASCII that fold to ASCII letters alone
    /// (CaseFolding.txt, statuses C and F). A folding that mixes in a combining mark, such as U+0130's, can never
    /// complete a match against ASCII, so it is left out with every other character.
    private static func asciiFolding(of scalar: Unicode.Scalar) -> [UInt8]? {
        guard scalar.isASCII else {
            return foldings[scalar].map { Array($0.utf8) }
        }
        let byte = UInt8(scalar.value)
        return [(UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + caseOffset : byte]
    }

    /// The characters past ASCII whose full case folding is ASCII letters alone, and their foldings.
    private static let foldings: [Unicode.Scalar: String] = [
        "\u{DF}": "ss", "\u{17F}": "s", "\u{1E9E}": "ss", "\u{212A}": "k", "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl",
        "\u{FB03}": "ffi", "\u{FB04}": "ffl", "\u{FB05}": "st", "\u{FB06}": "st",
    ]
    private static let caseOffset = UInt8(ascii: "a") - UInt8(ascii: "A")
    private static let supplementaryBase: UInt32 = 0x1_0000
    private static let leadBase: UInt32 = 0xD800
    private static let trailBase: UInt32 = 0xDC00
    private static let leadShift: UInt32 = 10
    /// A surrogate pair's width in units.
    private static let pairWidth = 2
}
