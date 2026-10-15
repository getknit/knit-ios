/// The text-keyed map a kotlinx `@Serializable` class encodes to, read one field at a time.
///
/// kotlinx's rules, which these accessors mirror:
///
/// - An unknown key is ignored.
/// - A field with no default must be present, and a non-nullable field may not be `null`.
/// - A duplicated key takes its last value, because the decoder assigns fields as it meets them.
internal struct CBORFields {
    private let typeName: String
    private let values: [String: CBOR]

    init(_ item: CBOR, type typeName: String) throws(WireDecodingError) {
        guard case .map(let entries) = item else {
            throw .notAMap(type: typeName)
        }
        var collected: [String: CBOR] = [:]
        for entry in entries {
            guard case .text(let key) = entry.key else {
                throw .nonTextKey(type: typeName)
            }
            collected[key] = entry.value
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
        guard let item = values[key] else {
            return nil
        }
        guard item != .null else {
            throw .unexpectedNull(type: typeName, field: key)
        }
        return try extract(key, item, kind)
    }

    /// A nullable field: `nil` when absent or `null`.
    func nullable<Value>(_ key: String, _ kind: FieldKind<Value>) throws(WireDecodingError) -> Value? {
        guard let item = values[key], item != .null else {
            return nil
        }
        return try extract(key, item, kind)
    }

    private func extract<Value>(_ key: String, _ item: CBOR, _ kind: FieldKind<Value>) throws(WireDecodingError) -> Value {
        guard let value = try kind.extract(item) else {
            throw .invalidValue(type: typeName, field: key)
        }
        return value
    }
}

/// How to read one field's value out of its CBOR item. `extract` returns `nil` for the wrong kind of item.
internal struct FieldKind<Value> {
    let extract: (CBOR) throws(WireDecodingError) -> Value?
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

extension FieldKind where Value == Int {
    /// A Kotlin `Int`: an integer that fits in 32 bits.
    static var int32: Self {
        Self { item in
            guard let value = item.int64, let narrowed = Int32(exactly: value) else {
                return nil
            }
            return Int(narrowed)
        }
    }
}

extension FieldKind where Value == Int64 {
    /// A Kotlin `Long`.
    static var int64: Self {
        Self { item in item.int64 }
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
    /// A list of text strings.
    static var texts: Self {
        Self { item in
            guard case .array(let items) = item else {
                return nil
            }
            var strings: [String] = []
            strings.reserveCapacity(items.count)
            for element in items {
                guard case .text(let text) = element else {
                    return nil
                }
                strings.append(text)
            }
            return strings
        }
    }
}

extension FieldKind where Value == CBOR {
    /// Any item, kept undecoded: for nested types this build carries but does not read.
    static var raw: Self {
        Self { item in item }
    }

    /// An item kept undecoded once it reads as `Shape`: a field this build carries but never acts on, refused where
    /// kotlinx's typed decoder would refuse it, so a payload Android drops is one we drop too.
    static func checked<Shape: CBORRepresentable>(as _: Shape.Type) -> Self {
        Self { item throws(WireDecodingError) in
            _ = try Shape(cbor: item)
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
