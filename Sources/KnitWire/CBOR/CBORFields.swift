/// The text-keyed map a kotlinx `@Serializable` class encodes to, read one field at a time.
///
/// kotlinx-cbor 1.12.0's rules, under knit-next's `ignoreUnknownKeys` and with no tags declared anywhere, which these
/// accessors mirror (`Decoder.kt` in its sources, knit-ios #14):
///
/// - An unknown key is ignored.
/// - A field with no default must be present, and a non-nullable field may not be `null`.
/// - A nullable field is null only when its value's first byte is `F6` or `A0` (`isNull`, `:193`). An empty map written
///   any other way (``CBOR/longFormEmptyMap``), and a tagged `F6` or `A0`, go to the field's decoder.
/// - Tags are skipped before every value, every list element, every key and the map itself (`processTags`, `:304-334`).
/// - An integer key is skipped as an unknown one: the class has no `@CborLabel`s to find it among (`:62-67`,
///   `:102-108`). Any other key that is not text fails, as `readNumber` throws on it (`:406-415`).
/// - Every occurrence of a duplicated key is decoded through the field's decoder, in wire order, and the last one wins.
///   A field with no default is present when any occurrence is.
/// - Keys compare by their UTF-8 bytes, as kotlinx's name lookup compares Kotlin strings, never by Swift's canonical
///   equivalence: `"attachment\u{212A}ey"`, with a Kelvin sign, is an unknown key, not `attachmentKey` (ADR
///   2026-09.jc2x).
internal struct CBORFields {
    private let typeName: String
    private let values: [ExactKey: [CBOR]]

    init(_ item: CBOR, type typeName: String) throws(WireDecodingError) {
        var collected: [ExactKey: [CBOR]] = [:]
        for entry in try item.fieldEntries(type: typeName) {
            switch entry.key.untagged {
            case .text(let key):
                collected[ExactKey(key), default: []].append(entry.value)
            case .unsigned, .negative:
                continue
            default:
                throw .nonTextKey(type: typeName)
            }
        }
        self.typeName = typeName
        values = collected
    }

    /// A field with no default: it must be present and not `null`.
    func required<Value>(_ key: String, _ kind: FieldKind<Value>) throws(WireDecodingError) -> Value {
        guard let value = try optional(key, kind) else {
            throw .missingField(type: typeName, field: key)
        }
        return value
    }

    /// A non-nullable field with a default: `nil` when absent, an error when `null`.
    func optional<Value>(_ key: String, _ kind: FieldKind<Value>) throws(WireDecodingError) -> Value? {
        try FieldReading.optional(values[ExactKey(key)], kind, type: typeName, field: key)
    }

    /// A nullable field: `nil` when absent, `null` or `A0`.
    func nullable<Value>(_ key: String, _ kind: FieldKind<Value>) throws(WireDecodingError) -> Value? {
        try FieldReading.nullable(values[ExactKey(key)], kind, type: typeName, field: key)
    }
}

extension CBOR {
    /// The entries of the map a class decodes from, under every leading tag (`startMap`, `Decoder.kt:220-251`). An empty
    /// map in any form has none.
    func fieldEntries(type typeName: String) throws(WireDecodingError) -> [Entry] {
        switch untagged {
        case .map(let entries):
            entries
        case .longFormEmptyMap:
            []
        default:
            throw .notAMap(type: typeName)
        }
    }
}

/// kotlinx's reading of one field over every occurrence of its key, in wire order: each goes through the field's
/// decoder, and the last one wins (`decodeElementIndex`, `Decoder.kt:57-87`). Shared by ``CBORFields`` and
/// ``CBORLabeledFields``.
internal enum FieldReading {
    /// A non-nullable field: `nil` when absent, an error when any occurrence is `null` or the wrong kind.
    static func optional<Value>(
        _ items: [CBOR]?, _ kind: FieldKind<Value>, type typeName: String, field: String
    ) throws(WireDecodingError) -> Value? {
        var value: Value?
        for item in items ?? [] {
            guard item != .null else {
                throw .unexpectedNull(type: typeName, field: field)
            }
            value = try extract(item, kind, type: typeName, field: field)
        }
        return value
    }

    /// A nullable field. An occurrence is null when it is exactly `F6` or `A0`, which is the first byte kotlinx's
    /// `decodeNotNullMark` reads (`Decoder.kt:125`, `:193`), before any tag is skipped: a tagged `F6` or `A0`, and an empty
    /// map in a longer form, go to the field's kind like any other value.
    static func nullable<Value>(
        _ items: [CBOR]?, _ kind: FieldKind<Value>, type typeName: String, field: String
    ) throws(WireDecodingError) -> Value? {
        var value: Value?
        for item in items ?? [] {
            value = item == .null || item == .map([]) ? nil : try extract(item, kind, type: typeName, field: field)
        }
        return value
    }

    private static func extract<Value>(
        _ item: CBOR, _ kind: FieldKind<Value>, type typeName: String, field: String
    ) throws(WireDecodingError) -> Value {
        guard let value = try kind.extract(item) else {
            throw .invalidValue(type: typeName, field: field)
        }
        return value
    }
}

/// How to read one field's value out of its CBOR item. `extract` returns `nil` for the wrong kind of item.
internal struct FieldKind<Value> {
    /// Reads one occurrence, as received.
    let extract: (CBOR) throws(WireDecodingError) -> Value?

    /// A kind that reads its item under every leading tag, as each of kotlinx's readers calls `processTags` first
    /// (`Decoder.kt:304-334`).
    init(_ read: @escaping (CBOR) throws(WireDecodingError) -> Value?) {
        self.init(skippingTags: true, read)
    }

    private init(skippingTags: Bool, _ read: @escaping (CBOR) throws(WireDecodingError) -> Value?) {
        extract = skippingTags ? { item throws(WireDecodingError) in try read(item.untagged) } : read
    }

    /// A kind that reads its item as received, its tags included: ``checked(as:)`` and ``checked(asListOf:)``, which keep
    /// the item exactly as it came and whose shape skips the tags itself.
    static func asReceived(_ read: @escaping (CBOR) throws(WireDecodingError) -> Value?) -> Self {
        Self(skippingTags: false, read)
    }
}

extension FieldKind where Value == String {
    /// A text string.
    static var text: Self {
        Self { item in
            guard case .text(let text) = item else {
                return nil
            }
            return text
        }
    }
}

/// An integer as kotlinx-cbor 1.12.0's `readNumber` reads it (`Decoder.kt:406-424`): the argument read into a `Long` by
/// `readExact`, which wraps past `Int64.max`, and a negative integer read as `-(u + 1)`, which wraps too. So `1B FF…FF`
/// reads as −1, `3B FF…FF` as 0 and `3B FF…FE` as 1.
private func wrappedInteger(_ item: CBOR) -> Int64? {
    switch item {
    case .unsigned(let value):
        Int64(truncatingIfNeeded: value)
    case .negative(let magnitude):
        0 &- (Int64(truncatingIfNeeded: magnitude) &+ 1)
    default:
        nil
    }
}

extension FieldKind where Value == Int {
    /// A Kotlin `Int`, as `decodeInt` reads it (`Decoder.kt:145-147`, `nextNumberWithinRange` at `:361-378`): the wrapped
    /// 64-bit reading, held to `Int.MIN_VALUE` through `UInt.MAX_VALUE`, then truncated to 32 bits by `toInt()`. So
    /// `1A FFFFFFFF` reads as −1, while 2³² and `1B 8000000000000000` are refused.
    static var int32: Self {
        Self { item in
            guard let wide = wrappedInteger(item), (Int64(Int32.min)...Int64(UInt32.max)).contains(wide) else {
                return nil
            }
            return Int(Int32(truncatingIfNeeded: wide))
        }
    }
}

extension FieldKind where Value == Int64 {
    /// A Kotlin `Long`, as `decodeLong` reads it (`Decoder.kt:149`): any integer, wrapped into 64 bits with no range
    /// check, so a value past `Int64.max` comes back negative instead of refused.
    static var int64: Self {
        Self { item in wrappedInteger(item) }
    }
}

extension FieldKind where Value == Bool {
    /// `true` or `false`.
    static var bool: Self {
        Self { item in
            guard case .bool(let value) = item else {
                return nil
            }
            return value
        }
    }
}

extension FieldKind where Value == [UInt8] {
    /// A `@ByteString` byte array.
    static var bytes: Self {
        Self { item in
            guard case .bytes(let bytes) = item else {
                return nil
            }
            return bytes
        }
    }
}

extension FieldKind where Value == [String] {
    /// A list of text strings, each read under its own tags.
    static var texts: Self {
        Self { item in
            guard case .array(let items) = item else {
                return nil
            }
            var strings: [String] = []
            strings.reserveCapacity(items.count)
            for element in items {
                guard case .text(let text) = element.untagged else {
                    return nil
                }
                strings.append(text)
            }
            return strings
        }
    }
}

/// A kotlinx class this build checks and never keeps: it reads one only so that a value Android's decode refuses is
/// refused here too. Decode-only, since nothing in this build writes one.
internal protocol CBORShape {
    /// Reads the shape, throwing where kotlinx's decoder throws.
    init(cbor: CBOR) throws(WireDecodingError)
}

extension FieldKind where Value == CBOR {
    /// An item kept as received once it reads as `Shape`: a field this build carries or drops but never acts on, refused
    /// where kotlinx's typed decoder would refuse it, so a payload Android drops is one we drop too.
    static func checked<Shape: CBORShape>(as _: Shape.Type) -> Self {
        asReceived { item throws(WireDecodingError) in
            _ = try Shape(cbor: item)
            return item
        }
    }

    /// An item kept as received once it reads as a list of `Shape`, each element under its own tags.
    static func checked<Shape: CBORShape>(asListOf _: Shape.Type) -> Self {
        asReceived { item throws(WireDecodingError) in
            guard case .array(let elements) = item.untagged else {
                return nil
            }
            for element in elements {
                _ = try Shape(cbor: element)
            }
            return item
        }
    }
}

extension FieldKind where Value: CBORRepresentable {
    /// A nested wire type.
    static func object(_: Value.Type) -> Self {
        Self { item throws(WireDecodingError) in try Value(cbor: item) }
    }
}

extension FieldKind {
    /// A list of a nested wire type.
    static func list<Element: CBORRepresentable>(of _: Element.Type) -> Self where Value == [Element] {
        Self { item throws(WireDecodingError) in
            guard case .array(let items) = item else {
                return nil
            }
            var elements: [Element] = []
            elements.reserveCapacity(items.count)
            for element in items {
                elements.append(try Element(cbor: element))
            }
            return elements
        }
    }
}
