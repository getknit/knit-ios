/// HTML character references (`decodeEntities` in knit-next's `OpenGraphParser.kt`).
extension OpenGraphParser {
    /// `text` with its character references decoded: the common named ones and every numeric one, in one pass, so
    /// `&amp;lt;` reads `&lt;` (`ENTITY.replace`, `&(#[xX]?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);`). An unknown name, a
    /// number that is no character (0, a surrogate, past U+10FFFF) and a decimal reference with a hex digit stay as
    /// written.
    public static func decodeEntities(_ text: String) -> String {
        let units = Array(text.utf16)
        guard units.contains(ampersand) else {
            return text
        }
        var decoded: [UInt16] = []
        decoded.reserveCapacity(units.count)
        var at = 0
        while at < units.count {
            guard units[at] == ampersand, let (name, end) = reference(in: units, at: at) else {
                decoded.append(units[at])
                at += 1
                continue
            }
            if let replacement = replacement(for: name) {
                decoded += replacement.utf16
            } else {
                decoded += units[at..<end]
            }
            at = end
        }
        return String(decoding: decoded, as: UTF16.self)
    }

    /// The reference whose `&` is at `start`: its name, between `&` and `;`, and where it ends, or `nil`.
    private static func reference(in units: [UInt16], at start: Int) -> (name: ArraySlice<UInt16>, end: Int)? {
        let nameStart = start + 1
        var at = nameStart
        if units.indices.contains(at), units[at] == hash {
            at += 1
            // `[xX]?` gives its `x` back only to a run of hex digits, which can't start with the `x`.
            if units.indices.contains(at), units[at] | caseBit == lowerX {
                at += 1
            }
            let digitsEnd = units[at...].firstIndex { !isHexDigit($0) } ?? units.count
            guard digitsEnd > at else {
                return nil
            }
            at = digitsEnd
        } else {
            guard units.indices.contains(at), isASCIILetter(units[at]) else {
                return nil
            }
            at = units[at...].firstIndex { !(isASCIILetter($0) || isDigit($0)) } ?? units.count
        }
        guard units.indices.contains(at), units[at] == semicolon else {
            return nil
        }
        return (units[nameStart..<at], at + 1)
    }

    /// What `name` stands for, or `nil` to keep the reference as written: `#x` (either case) and hex digits, `#` and
    /// decimal digits, or a name from the table, matched in its case.
    private static func replacement(for name: ArraySlice<UInt16>) -> String? {
        let text = String(decoding: name, as: UTF16.self)
        if text.hasPrefix("#x") || text.hasPrefix("#X") {
            return character(text.dropFirst(hexMarkLength), radix: hexRadix)
        }
        if text.hasPrefix("#") {
            return character(text.dropFirst(), radix: decimalRadix)
        }
        return namedEntities[text]
    }

    /// The character numbered `digits` (`codePointOrNull`): 1 through U+10FFFF and no surrogate, or `nil`. Kotlin's
    /// `toIntOrNull` refuses a number past `Int.MAX_VALUE`, which is past U+10FFFF anyway.
    private static func character(_ digits: Substring, radix: Int) -> String? {
        guard let value = UInt32(digits, radix: radix), value >= 1, let scalar = Unicode.Scalar(value) else {
            return nil
        }
        return String(scalar)
    }

    private static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (lowerA...lowerF).contains(unit | caseBit)
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        (zero...nine).contains(unit)
    }

    private static func isASCIILetter(_ unit: UInt16) -> Bool {
        (lowerA...lowerZ).contains(unit | caseBit)
    }

    /// The named references decoded (`NAMED_ENTITIES`). Kotlin maps `nbsp`, `ensp`, `emsp` and `thinsp` to a plain
    /// space, and `shy` to nothing.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "\u{2014}", "ndash": "\u{2013}",
        "hellip": "\u{2026}", "copy": "\u{A9}", "reg": "\u{AE}", "trade": "\u{2122}", "laquo": "\u{AB}", "raquo": "\u{BB}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}", "bull": "\u{2022}",
        "middot": "\u{B7}", "ensp": " ", "emsp": " ", "thinsp": " ", "shy": "", "euro": "\u{20AC}", "pound": "\u{A3}",
        "yen": "\u{A5}", "deg": "\u{B0}", "times": "\u{D7}",
    ]

    /// `#x`, before a hex reference's digits.
    private static let hexMarkLength = 2
    private static let hexRadix = 16
    private static let decimalRadix = 10
    private static let ampersand = UInt16(UInt8(ascii: "&"))
    private static let hash = UInt16(UInt8(ascii: "#"))
    private static let semicolon = UInt16(UInt8(ascii: ";"))
    private static let zero = UInt16(UInt8(ascii: "0"))
    private static let nine = UInt16(UInt8(ascii: "9"))
    private static let lowerA = UInt16(UInt8(ascii: "a"))
    private static let lowerF = UInt16(UInt8(ascii: "f"))
    private static let lowerX = UInt16(UInt8(ascii: "x"))
    private static let lowerZ = UInt16(UInt8(ascii: "z"))
    /// The bit between an ASCII capital and its small letter.
    private static let caseBit: UInt16 = 0x20
}
