extension CBOR {
    /// The item's bytes in the profile knit-next encodes with: definite lengths, the shortest argument that
    /// holds each value, and map entries in the order they are stored.
    ///
    /// Knit never emits floats, tags or simple values; they are encoded here only so that anything decoded
    /// can be written back.
    public var encoded: [UInt8] {
        var output: [UInt8] = []
        append(to: &output)
        return output
    }

    private func append(to output: inout [UInt8]) {
        switch self {
        case .unsigned(let value):
            appendHeader(major: MajorType.unsigned, argument: value, to: &output)
        case .negative(let magnitude):
            appendHeader(major: MajorType.negative, argument: magnitude, to: &output)
        case .bytes(let bytes):
            appendHeader(major: MajorType.bytes, argument: UInt64(bytes.count), to: &output)
            output += bytes
        case .text(let text):
            let utf8 = Array(text.utf8)
            appendHeader(major: MajorType.text, argument: UInt64(utf8.count), to: &output)
            output += utf8
        case .array(let items):
            appendHeader(major: MajorType.array, argument: UInt64(items.count), to: &output)
            for item in items {
                item.append(to: &output)
            }
        case .map(let entries):
            appendHeader(major: MajorType.map, argument: UInt64(entries.count), to: &output)
            for entry in entries {
                entry.key.append(to: &output)
                entry.value.append(to: &output)
            }
        case .tagged(let tag, let item):
            appendHeader(major: MajorType.tag, argument: tag, to: &output)
            item.append(to: &output)
        case .simple(let value):
            appendHeader(major: MajorType.simple, argument: UInt64(value), to: &output)
        case .bool(let value):
            output.append(value ? SimpleByte.trueByte : SimpleByte.falseByte)
        case .null:
            output.append(SimpleByte.nullByte)
        case .undefined:
            output.append(SimpleByte.undefinedByte)
        case .float(let value):
            output.append(SimpleByte.doubleByte)
            appendBigEndian(value.bitPattern, byteCount: MemoryLayout<UInt64>.size, to: &output)
        }
    }
}

private enum MajorType {
    static let unsigned: UInt8 = 0
    static let negative: UInt8 = 1
    static let bytes: UInt8 = 2
    static let text: UInt8 = 3
    static let array: UInt8 = 4
    static let map: UInt8 = 5
    static let tag: UInt8 = 6
    static let simple: UInt8 = 7
    static let shift: UInt8 = 5
}

private enum SimpleByte {
    static let falseByte: UInt8 = 0xF4
    static let trueByte: UInt8 = 0xF5
    static let nullByte: UInt8 = 0xF6
    static let undefinedByte: UInt8 = 0xF7
    static let doubleByte: UInt8 = 0xFB
}

private enum ArgumentForm {
    static let immediateLimit: UInt64 = 24
    static let oneByte: UInt8 = 24
    static let twoBytes: UInt8 = 25
    static let fourBytes: UInt8 = 26
    static let eightBytes: UInt8 = 27
}

/// The initial byte and argument, using the shortest form that holds `argument` (RFC 8949 §4.2.1).
private func appendHeader(major: UInt8, argument: UInt64, to output: inout [UInt8]) {
    let prefix = major << MajorType.shift
    switch argument {
    case 0..<ArgumentForm.immediateLimit:
        output.append(prefix | UInt8(argument))
    case ...UInt64(UInt8.max):
        output.append(prefix | ArgumentForm.oneByte)
        appendBigEndian(argument, byteCount: MemoryLayout<UInt8>.size, to: &output)
    case ...UInt64(UInt16.max):
        output.append(prefix | ArgumentForm.twoBytes)
        appendBigEndian(argument, byteCount: MemoryLayout<UInt16>.size, to: &output)
    case ...UInt64(UInt32.max):
        output.append(prefix | ArgumentForm.fourBytes)
        appendBigEndian(argument, byteCount: MemoryLayout<UInt32>.size, to: &output)
    default:
        output.append(prefix | ArgumentForm.eightBytes)
        appendBigEndian(argument, byteCount: MemoryLayout<UInt64>.size, to: &output)
    }
}

private func appendBigEndian(_ value: UInt64, byteCount: Int, to output: inout [UInt8]) {
    for shift in stride(from: (byteCount - 1) * UInt8.bitWidth, through: 0, by: -UInt8.bitWidth) {
        output.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
    }
}
