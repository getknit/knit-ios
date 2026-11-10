/// Java's `lowMask`/`highMask` pairs: a bit per ASCII character, and bit 0, which no character uses since U+0000 never
/// matches, meaning "escapes and other characters are allowed" (`L_ESCAPED`).
internal struct JavaURIMask {
    var low: UInt64 = 0
    var high: UInt64 = 0

    static let escaped = Self(low: 1)
    static let digit = range("0", "9")
    static let alpha = range("a", "z") | range("A", "Z")
    static let alphanumeric = digit | alpha
    static let hex = digit | range("a", "f") | range("A", "F")
    static let mark = chars("-_.!~*'()")
    static let unreserved = alphanumeric | mark
    static let reserved = chars(";/?:@&=+$,[]")
    static let uric = reserved | unreserved | escaped
    static let pchar = unreserved | escaped | chars(":@&=+$,")
    static let path = pchar | chars(";/")
    static let dash = chars("-")
    static let underscore = chars("_")
    static let dot = chars(".")
    static let userInfo = unreserved | escaped | chars(";:&=+$,")
    static let registryName = unreserved | escaped | chars("$,;:@&=+")
    static let server = userInfo | alphanumeric | dash | chars(".:@[]")
    static let serverPercent = server | chars("%")
    static let scheme = alpha | digit | chars("+-.")

    var allowsEscapes: Bool { low & Self.escaped.low != 0 }

    static func | (lhs: Self, rhs: Self) -> Self {
        Self(low: lhs.low | rhs.low, high: lhs.high | rhs.high)
    }

    static func chars(_ text: String) -> Self {
        var mask = Self()
        for unit in text.utf16 {
            mask.add(unit)
        }
        return mask
    }

    static func range(_ first: Unicode.Scalar, _ last: Unicode.Scalar) -> Self {
        var mask = Self()
        for value in first.value...last.value {
            mask.add(UInt16(value))
        }
        return mask
    }

    /// Java's `match(char, lowMask, highMask)`: U+0000 and anything past ASCII never match.
    func matches(_ unit: UInt16) -> Bool {
        switch unit {
        case 0:
            false
        case 1..<Self.highStart:
            low & (1 << UInt64(unit)) != 0
        case Self.highStart..<Self.asciiEnd:
            high & (1 << UInt64(unit - Self.highStart)) != 0
        default:
            false
        }
    }

    private static let highStart: UInt16 = 64
    private static let asciiEnd: UInt16 = 128

    private mutating func add(_ unit: UInt16) {
        if unit < Self.highStart {
            low |= 1 << UInt64(unit)
        } else if unit < Self.asciiEnd {
            high |= 1 << UInt64(unit - Self.highStart)
        }
    }
}
