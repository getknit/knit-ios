/// Bounds on a decode, so hostile input costs no more than its own length.
public struct CBORDecodingLimits: Sendable {
    /// The default: deep enough for every knit-next type, shallow enough that recursion cannot exhaust the stack.
    public static let standard = Self(maxDepth: defaultMaxDepth)

    /// Deep enough for every knit-next type, with room to spare.
    public static let defaultMaxDepth = 32

    /// How many containers (arrays, maps, tags) may nest inside one another.
    public var maxDepth: Int

    /// Makes limits with the given nesting depth.
    public init(maxDepth: Int) {
        self.maxDepth = maxDepth
    }
}

extension CBOR {
    /// Decodes exactly one CBOR item from `bytes`.
    ///
    /// It accepts definite and indefinite lengths and any integer width, because a receiver must read what a
    /// conforming encoder may write. Declared lengths are checked against the bytes that remain before
    /// anything is allocated, so a forged length cannot make it allocate more than the input.
    public static func decode(_ bytes: [UInt8], limits: CBORDecodingLimits = .standard) throws(CBORError) -> Self {
        var reader = CBORReader(bytes: bytes, maxDepth: limits.maxDepth)
        let item = try reader.readItem(depth: 0)
        guard reader.isAtEnd else {
            throw .trailingBytes
        }
        return item
    }
}

/// The initial-byte layout of RFC 8949 §3.
private enum Header {
    static let majorShift: UInt8 = 5
    static let infoMask: UInt8 = 0x1F
    static let oneByteArgument: UInt8 = 24
    static let twoByteArgument: UInt8 = 25
    static let fourByteArgument: UInt8 = 26
    static let eightByteArgument: UInt8 = 27
    static let indefinite: UInt8 = 31
    static let breakByte: UInt8 = 0xFF
}

private enum Major: UInt8 {
    case unsigned = 0
    case negative = 1
    case bytes = 2
    case text = 3
    case array = 4
    case map = 5
    case tag = 6
    case simple = 7
}

private enum Simple {
    static let falseValue: UInt8 = 20
    static let trueValue: UInt8 = 21
    static let nullValue: UInt8 = 22
    static let undefinedValue: UInt8 = 23
    static let firstExtended: UInt8 = 32
}

private struct CBORReader {
    /// A map entry is a key and a value, one byte each at the least.
    private static let minimumEntryBytes = 2

    let bytes: [UInt8]
    let maxDepth: Int
    var index = 0

    init(bytes: [UInt8], maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    var isAtEnd: Bool { index == bytes.count }

    private var remaining: Int { bytes.count - index }

    mutating func readItem(depth: Int) throws(CBORError) -> CBOR {
        let initial = try readByte()
        if initial == Header.breakByte {
            throw .unexpectedBreak
        }
        guard let major = Major(rawValue: initial >> Header.majorShift) else {
            throw .malformedHeader(initial)
        }
        let info = initial & Header.infoMask
        switch major {
        case .unsigned:
            return .unsigned(try readArgument(info, initial: initial))
        case .negative:
            return .negative(try readArgument(info, initial: initial))
        case .bytes:
            return .bytes(try readString(info, initial: initial, major: .bytes))
        case .text:
            let raw = try readString(info, initial: initial, major: .text)
            guard let text = String(validating: raw, as: UTF8.self) else {
                throw .invalidUTF8
            }
            return .text(text)
        case .array:
            return .array(try readArray(info, initial: initial, depth: depth))
        case .map:
            return .map(try readMap(info, initial: initial, depth: depth))
        case .tag:
            let tag = try readArgument(info, initial: initial)
            return .tagged(tag, try readNested(depth: depth))
        case .simple:
            return try readSimple(info, initial: initial)
        }
    }

    private mutating func readNested(depth: Int) throws(CBORError) -> CBOR {
        guard depth < maxDepth else {
            throw .nestingTooDeep
        }
        return try readItem(depth: depth + 1)
    }

    private mutating func readByte() throws(CBORError) -> UInt8 {
        guard index < bytes.count else {
            throw .truncated
        }
        defer { index += 1 }
        return bytes[index]
    }

    private mutating func readBigEndian(byteCount: Int) throws(CBORError) -> UInt64 {
        guard remaining >= byteCount else {
            throw .truncated
        }
        var value: UInt64 = 0
        for _ in 0..<byteCount {
            value = value << UInt64(UInt8.bitWidth) | UInt64(bytes[index])
            index += 1
        }
        return value
    }

    /// The argument of a definite item: the length, count, integer value or tag number.
    private mutating func readArgument(_ info: UInt8, initial: UInt8) throws(CBORError) -> UInt64 {
        switch info {
        case 0..<Header.oneByteArgument:
            UInt64(info)
        case Header.oneByteArgument:
            try readBigEndian(byteCount: MemoryLayout<UInt8>.size)
        case Header.twoByteArgument:
            try readBigEndian(byteCount: MemoryLayout<UInt16>.size)
        case Header.fourByteArgument:
            try readBigEndian(byteCount: MemoryLayout<UInt32>.size)
        case Header.eightByteArgument:
            try readBigEndian(byteCount: MemoryLayout<UInt64>.size)
        default:
            throw .malformedHeader(initial)
        }
    }

    /// A declared length or count, refused before allocation unless the input could hold that many
    /// `unitSize`-byte units.
    private mutating func readCount(_ info: UInt8, initial: UInt8, unitSize: Int) throws(CBORError) -> Int {
        let declared = try readArgument(info, initial: initial)
        guard declared <= UInt64(remaining / unitSize) else {
            throw .lengthExceedsInput
        }
        return Int(declared)
    }

    private mutating func readString(_ info: UInt8, initial: UInt8, major: Major) throws(CBORError) -> [UInt8] {
        guard info == Header.indefinite else {
            let length = try readCount(info, initial: initial, unitSize: 1)
            defer { index += length }
            return Array(bytes[index..<index + length])
        }
        // Indefinite: definite chunks of the same major type until a break.
        var joined: [UInt8] = []
        while true {
            let chunkInitial = try readByte()
            if chunkInitial == Header.breakByte {
                return joined
            }
            let chunkInfo = chunkInitial & Header.infoMask
            guard chunkInitial >> Header.majorShift == major.rawValue, chunkInfo != Header.indefinite else {
                throw .invalidChunk
            }
            let length = try readCount(chunkInfo, initial: chunkInitial, unitSize: 1)
            let chunk = Array(bytes[index..<index + length])
            index += length
            if major == .text, String(validating: chunk, as: UTF8.self) == nil {
                throw .invalidUTF8
            }
            joined += chunk
        }
    }

    private mutating func readArray(_ info: UInt8, initial: UInt8, depth: Int) throws(CBORError) -> [CBOR] {
        var items: [CBOR] = []
        guard info == Header.indefinite else {
            let count = try readCount(info, initial: initial, unitSize: 1)
            items.reserveCapacity(count)
            for _ in 0..<count {
                items.append(try readNested(depth: depth))
            }
            return items
        }
        while try !consumeBreak() {
            items.append(try readNested(depth: depth))
        }
        return items
    }

    private mutating func readMap(_ info: UInt8, initial: UInt8, depth: Int) throws(CBORError) -> [CBOR.Entry] {
        var entries: [CBOR.Entry] = []
        guard info == Header.indefinite else {
            // Every entry is a key and a value, so at least two bytes.
            let count = try readCount(info, initial: initial, unitSize: Self.minimumEntryBytes)
            entries.reserveCapacity(count)
            for _ in 0..<count {
                let key = try readNested(depth: depth)
                entries.append(CBOR.Entry(key: key, value: try readNested(depth: depth)))
            }
            return entries
        }
        while try !consumeBreak() {
            let key = try readNested(depth: depth)
            entries.append(CBOR.Entry(key: key, value: try readNested(depth: depth)))
        }
        return entries
    }

    /// Consumes a break byte if one is next; used inside indefinite-length containers.
    private mutating func consumeBreak() throws(CBORError) -> Bool {
        guard index < bytes.count else {
            throw .truncated
        }
        guard bytes[index] == Header.breakByte else {
            return false
        }
        index += 1
        return true
    }

    private mutating func readSimple(_ info: UInt8, initial: UInt8) throws(CBORError) -> CBOR {
        switch info {
        case Simple.falseValue:
            return .bool(false)
        case Simple.trueValue:
            return .bool(true)
        case Simple.nullValue:
            return .null
        case Simple.undefinedValue:
            return .undefined
        case 0..<Simple.falseValue:
            return .simple(info)
        case Header.oneByteArgument:
            let value = try readByte()
            // RFC 8949 §3.3: the two-byte form may not encode a value the one-byte form can.
            guard value >= Simple.firstExtended else {
                throw .malformedHeader(initial)
            }
            return .simple(value)
        case Header.twoByteArgument:
            let bits = try readBigEndian(byteCount: MemoryLayout<UInt16>.size)
            return .float(Self.double(halfPrecisionBits: UInt16(truncatingIfNeeded: bits)))
        case Header.fourByteArgument:
            let bits = try readBigEndian(byteCount: MemoryLayout<UInt32>.size)
            return .float(Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits))))
        case Header.eightByteArgument:
            return .float(Double(bitPattern: try readBigEndian(byteCount: MemoryLayout<UInt64>.size)))
        default:
            throw .malformedHeader(initial)
        }
    }
    /// An IEEE 754 half-precision value, widened (RFC 8949 Appendix D).
    private static func double(halfPrecisionBits bits: UInt16) -> Double {
        let exponentBits: UInt16 = 5
        let mantissaBits: UInt16 = 10
        let exponentMask: UInt16 = 0x1F
        let mantissaMask: UInt16 = 0x3FF
        let exponentBias = 15
        let sign: Double = bits >> (exponentBits + mantissaBits) == 0 ? 1 : -1
        let exponent = Int((bits >> mantissaBits) & exponentMask)
        let mantissa = Double(bits & mantissaMask)
        let fraction = mantissa / Double(1 << mantissaBits)
        switch exponent {
        case 0:
            return sign * fraction * Double(sign: .plus, exponent: 1 - exponentBias, significand: 1)
        case Int(exponentMask):
            return mantissa == 0 ? sign * .infinity : .nan
        default:
            return sign * (1 + fraction) * Double(sign: .plus, exponent: exponent - exponentBias, significand: 1)
        }
    }
}
