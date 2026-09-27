import Foundation

/// A JSON value, for the control lines a node writes. Objects are written with their keys sorted, so a line is the
/// same every time and a script can compare lines.
public enum JSONValue: Equatable, Sendable, Encodable {
    case string(String)
    case int(Int64)
    case bool(Bool)
    case array([Self])
    case object([String: Self])
    case null

    /// A string, or `null` when there is none.
    public static func text(_ value: String?) -> Self {
        value.map(Self.string) ?? .null
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let values):
            try container.encode(values)
        case .null:
            try container.encodeNil()
        }
    }

    /// The value as one line of JSON.
    public var line: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Every case encodes, so the fallback is for a Foundation that someday refuses one.
        // swiftlint:disable:next optional_data_string_conversion
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"error":"unencodable"}"#
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) {
        self = .int(value)
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Self...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, Self)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}
