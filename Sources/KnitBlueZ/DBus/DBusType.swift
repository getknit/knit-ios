/// A D-Bus type, as its signature spells it (the D-Bus specification's "Type system").
///
/// Only the types BlueZ uses are here: no Unix file descriptors, which BlueZ passes only for the GATT acquire
/// calls this peer never makes.
internal indirect enum DBusType: Hashable, Sendable {
    case byte
    case boolean
    case int16
    case uint16
    case int32
    case uint32
    case int64
    case uint64
    case double
    case string
    case objectPath
    case signature
    case array(Self)
    case dictionary(key: Self, value: Self)
    case variant
    case structure([Self])

    /// The deepest nesting the specification allows: 32 arrays and 32 structures.
    static let maximumDepth = 64

    /// Parses exactly one complete type, or `nil` when `signature` is empty, malformed, or holds more than one.
    init?(signature: String) {
        var rest = Substring(signature)
        guard let parsed = Self.parse(&rest, depth: 0), rest.isEmpty else {
            return nil
        }
        self = parsed
    }

    /// Parses the complete type at the start of `text`, and answers it with what follows.
    static func parseLeading(_ text: Substring) -> (Self, Substring)? {
        var rest = text
        return parse(&rest, depth: 0).map { ($0, rest) }
    }

    /// The type's signature.
    var signature: String {
        switch self {
        case .array(let element):
            "a" + element.signature
        case .dictionary(let key, let value):
            "a{" + key.signature + value.signature + "}"
        case .structure(let fields):
            "(" + fields.map(\.signature).joined() + ")"
        default:
            String(Character(Unicode.Scalar(code)))
        }
    }

    /// libdbus's type code: the signature's first character.
    var code: UInt8 {
        switch self {
        case .byte:
            TypeCode.byte
        case .boolean:
            TypeCode.boolean
        case .int16:
            TypeCode.int16
        case .uint16:
            TypeCode.uint16
        case .int32:
            TypeCode.int32
        case .uint32:
            TypeCode.uint32
        case .int64:
            TypeCode.int64
        case .uint64:
            TypeCode.uint64
        case .double:
            TypeCode.double
        case .string:
            TypeCode.string
        case .objectPath:
            TypeCode.objectPath
        case .signature:
            TypeCode.signature
        case .array, .dictionary:
            TypeCode.array
        case .variant:
            TypeCode.variant
        case .structure:
            TypeCode.structure
        }
    }

    /// Whether this is a basic type, the only kind a dictionary key may be.
    var isBasic: Bool {
        switch self {
        case .array, .dictionary, .variant, .structure:
            false
        default:
            true
        }
    }

    private static func parse(_ rest: inout Substring, depth: Int) -> Self? {
        guard depth < maximumDepth, let first = rest.first?.asciiValue else {
            return nil
        }
        rest.removeFirst()
        if let basic = basic(first) {
            return basic
        }
        switch first {
        case TypeCode.array:
            return parseArray(&rest, depth: depth + 1)
        case TypeCode.structureOpen:
            var fields: [Self] = []
            while let next = rest.first, next.asciiValue != TypeCode.structureClose {
                guard let field = parse(&rest, depth: depth + 1) else {
                    return nil
                }
                fields.append(field)
            }
            guard !fields.isEmpty, rest.first?.asciiValue == TypeCode.structureClose else {
                return nil
            }
            rest.removeFirst()
            return .structure(fields)
        default:
            return nil
        }
    }

    private static func parseArray(_ rest: inout Substring, depth: Int) -> Self? {
        guard rest.first?.asciiValue == TypeCode.dictionaryOpen else {
            return parse(&rest, depth: depth).map(Self.array)
        }
        rest.removeFirst()
        guard let key = parse(&rest, depth: depth + 1), key.isBasic, let value = parse(&rest, depth: depth + 1),
            rest.first?.asciiValue == TypeCode.dictionaryClose
        else {
            return nil
        }
        rest.removeFirst()
        return .dictionary(key: key, value: value)
    }

    private static func basic(_ code: UInt8) -> Self? {
        switch code {
        case TypeCode.byte:
            .byte
        case TypeCode.boolean:
            .boolean
        case TypeCode.int16:
            .int16
        case TypeCode.uint16:
            .uint16
        case TypeCode.int32:
            .int32
        case TypeCode.uint32:
            .uint32
        case TypeCode.int64:
            .int64
        case TypeCode.uint64:
            .uint64
        case TypeCode.double:
            .double
        case TypeCode.string:
            .string
        case TypeCode.objectPath:
            .objectPath
        case TypeCode.signature:
            .signature
        case TypeCode.variant:
            .variant
        default:
            nil
        }
    }
}

/// libdbus's type codes. Its headers spell them as `((int) 'y')`, which Swift cannot import.
internal enum TypeCode {
    static let invalid: UInt8 = 0
    static let byte = UInt8(ascii: "y")
    static let boolean = UInt8(ascii: "b")
    static let int16 = UInt8(ascii: "n")
    static let uint16 = UInt8(ascii: "q")
    static let int32 = UInt8(ascii: "i")
    static let uint32 = UInt8(ascii: "u")
    static let int64 = UInt8(ascii: "x")
    static let uint64 = UInt8(ascii: "t")
    static let double = UInt8(ascii: "d")
    static let string = UInt8(ascii: "s")
    static let objectPath = UInt8(ascii: "o")
    static let signature = UInt8(ascii: "g")
    static let array = UInt8(ascii: "a")
    static let variant = UInt8(ascii: "v")
    /// What libdbus reports for a structure's container, and what opens one in a signature.
    static let structure = UInt8(ascii: "r")
    static let structureOpen = UInt8(ascii: "(")
    static let structureClose = UInt8(ascii: ")")
    /// What libdbus reports for a dictionary entry's container.
    static let dictionaryEntry = UInt8(ascii: "e")
    static let dictionaryOpen = UInt8(ascii: "{")
    static let dictionaryClose = UInt8(ascii: "}")
}
