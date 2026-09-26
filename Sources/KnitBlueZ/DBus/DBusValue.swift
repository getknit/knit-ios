/// One D-Bus value, typed the way it travels. Arrays and dictionaries carry their element types, so an empty one
/// still has a signature.
internal indirect enum DBusValue: Equatable, Sendable {
    case byte(UInt8)
    case boolean(Bool)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case objectPath(String)
    case signature(String)
    /// An array of bytes, `ay`: service data, a GATT value.
    case bytes([UInt8])
    /// Any other array. Every element has the given type.
    case array(DBusType, [Self])
    /// An array of dictionary entries, `a{kv}`, in the order they travel.
    case dictionary(key: DBusType, value: DBusType, [DBusEntry])
    case variant(Self)
    case structure([Self])

    /// The value's type.
    var type: DBusType {
        switch self {
        case .byte:
            .byte
        case .boolean:
            .boolean
        case .int16:
            .int16
        case .uint16:
            .uint16
        case .int32:
            .int32
        case .uint32:
            .uint32
        case .int64:
            .int64
        case .uint64:
            .uint64
        case .double:
            .double
        case .string:
            .string
        case .objectPath:
            .objectPath
        case .signature:
            .signature
        case .bytes:
            .array(.byte)
        case .array(let element, _):
            .array(element)
        case .dictionary(let key, let value, _):
            .dictionary(key: key, value: value)
        case .variant:
            .variant
        case .structure(let fields):
            .structure(fields.map(\.type))
        }
    }

    /// Whether every element matches its declared type, every key is basic, and nothing nests past the limit: the
    /// checks libdbus would otherwise make by aborting the process.
    var isWellFormed: Bool {
        isWellFormed(depth: 0)
    }

    private func isWellFormed(depth: Int) -> Bool {
        guard depth < DBusType.maximumDepth else {
            return false
        }
        switch self {
        case .array(let element, let items):
            return element != .byte && items.allSatisfy { $0.type == element && $0.isWellFormed(depth: depth + 1) }
        case .dictionary(let key, let value, let entries):
            return key.isBasic
                && entries.allSatisfy { entry in
                    entry.key.type == key && entry.value.type == value && entry.key.isWellFormed(depth: depth + 1)
                        && entry.value.isWellFormed(depth: depth + 1)
                }
        case .variant(let inner):
            return inner.isWellFormed(depth: depth + 1)
        case .structure(let fields):
            return !fields.isEmpty && fields.allSatisfy { $0.isWellFormed(depth: depth + 1) }
        case .string(let text):
            // A C string ends at its first NUL, so one inside would silently cut the text short.
            return !text.utf8.contains(0)
        case .objectPath(let path):
            return DBusNames.isObjectPath(path)
        case .signature(let text):
            return DBusNames.isSignature(text)
        default:
            return true
        }
    }

    // MARK: Building

    /// An `a{sv}` dictionary, the shape of every BlueZ property set and options argument.
    static func properties(_ pairs: [(String, Self)]) -> Self {
        .dictionary(key: .string, value: .variant, pairs.map { DBusEntry(key: .string($0.0), value: .variant($0.1)) })
    }

    /// An `as` array.
    static func strings(_ values: [String]) -> Self {
        .array(.string, values.map(Self.string))
    }

    // MARK: Reading

    /// The value inside any variants.
    var unwrapped: Self {
        if case .variant(let inner) = self {
            return inner.unwrapped
        }
        return self
    }

    /// A string, object path or signature's text.
    var text: String? {
        switch unwrapped {
        case .string(let text), .objectPath(let text), .signature(let text):
            text
        default:
            nil
        }
    }

    /// A boolean, or `nil` when the value is not one: BlueZ leaves a property out as often as it sets it false.
    var bool: Bool? { // swiftlint:disable:this discouraged_optional_boolean
        if case .boolean(let value) = unwrapped {
            return value
        }
        return nil
    }

    /// Any integer type, widened.
    var integer: Int64? {
        switch unwrapped {
        case .byte(let value):
            Int64(value)
        case .int16(let value):
            Int64(value)
        case .uint16(let value):
            Int64(value)
        case .int32(let value):
            Int64(value)
        case .uint32(let value):
            Int64(value)
        case .int64(let value):
            value
        case .uint64(let value):
            Int64(exactly: value)
        default:
            nil
        }
    }

    /// An `ay`'s bytes.
    var byteArray: [UInt8]? {
        if case .bytes(let bytes) = unwrapped {
            return bytes
        }
        return nil
    }

    /// An array of strings or object paths.
    var textArray: [String]? {
        guard case .array(_, let items) = unwrapped else {
            return nil
        }
        let texts = items.compactMap(\.text)
        return texts.count == items.count ? texts : nil
    }

    /// A dictionary keyed by strings or object paths, as ordered pairs; the values are left as they travel.
    var textKeyed: [(key: String, value: Self)]? {
        guard case .dictionary(_, _, let entries) = unwrapped else {
            return nil
        }
        let pairs = entries.compactMap { entry in entry.key.text.map { (key: $0, value: entry.value) } }
        return pairs.count == entries.count ? pairs : nil
    }

    /// The value under `key` in a text-keyed dictionary, unwrapped.
    subscript(key: String) -> Self? {
        textKeyed?.first { $0.key == key }?.value.unwrapped
    }
}

/// One entry of a D-Bus dictionary.
internal struct DBusEntry: Equatable, Sendable {
    /// The key, always of a basic type.
    var key: DBusValue
    /// The value.
    var value: DBusValue
}
