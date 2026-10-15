/// The `@CborLabel`s of one kotlinx class: each case's raw value is its label, and its name is the Kotlin property's.
///
/// kotlinx writes a labelled class with integer keys under `preferCborLabelsOverNames` (`compactCbor`, knit-next's
/// `Crypto.kt:111-119`), which only the v3 sealed plaintext uses (``MessageContentV2``).
internal protocol CBORLabel: CaseIterable, RawRepresentable, Sendable where RawValue == UInt64 {}

extension CBORLabel {
    /// The Kotlin property's name, which kotlinx also reads as this field's key.
    var name: String { "\(self)" }
}

/// The integer-keyed map a kotlinx class with `@CborLabel`s encodes to, read one field at a time.
///
/// kotlinx 1.11.0's lenient key lookup (`CborReader.decodeElementNameWithTagsLenient`), which this mirrors:
///
/// - An unsigned integer key is a label, and a label the class does not have is skipped (`ignoreUnknownKeys`).
/// - A text key is a property name, so `"body"` reads as label 1, and an unknown name is skipped. Names compare by
///   their UTF-8 bytes, as Kotlin compares strings, never by Swift's canonical equivalence (ADR 2026-09.jc2x).
/// - A duplicated key takes its last value.
///
/// A key of any other kind is refused. kotlinx reads one as a label taken from its header's argument, whatever its
/// major type, which no encoder writes; refusing it costs only bytes no honest peer sends.
internal struct CBORLabeledFields<Label: CBORLabel> {
    private let typeName: String
    private let values: [UInt64: CBOR]

    init(_ item: CBOR, type typeName: String) throws(WireDecodingError) {
        guard case .map(let entries) = item else {
            throw .notAMap(type: typeName)
        }
        var collected: [UInt64: CBOR] = [:]
        for entry in entries {
            switch entry.key {
            case .unsigned(let label):
                collected[label] = entry.value
            case .text(let name):
                if let label = Label.allCases.first(where: { $0.name.utf8.elementsEqual(name.utf8) }) {
                    collected[label.rawValue] = entry.value
                }
            default:
                throw .nonTextKey(type: typeName)
            }
        }
        self.typeName = typeName
        values = collected
    }

    /// A field with no default: it must be present and not `null`.
    func required<Value>(_ label: Label, _ kind: FieldKind<Value>) throws(WireDecodingError) -> Value {
        guard let value = try optional(label, kind) else {
            throw .missingField(type: typeName, field: label.name)
        }
        return value
    }

    /// A non-nullable field with a default: `nil` when absent, an error when `null`.
    func optional<Value>(_ label: Label, _ kind: FieldKind<Value>) throws(WireDecodingError) -> Value? {
        guard let item = values[label.rawValue] else {
            return nil
        }
        guard item != .null else {
            throw .unexpectedNull(type: typeName, field: label.name)
        }
        return try extract(label, item, kind)
    }

    /// A nullable field: `nil` when absent or `null`.
    func nullable<Value>(_ label: Label, _ kind: FieldKind<Value>) throws(WireDecodingError) -> Value? {
        guard let item = values[label.rawValue], item != .null else {
            return nil
        }
        return try extract(label, item, kind)
    }

    private func extract<Value>(_ label: Label, _ item: CBOR, _ kind: FieldKind<Value>) throws(WireDecodingError) -> Value {
        guard let value = try kind.extract(item) else {
            throw .invalidValue(type: typeName, field: label.name)
        }
        return value
    }
}

/// Builds the integer-keyed map kotlinx's `compactCbor` writes: fields in declaration order, each under its label,
/// and a field equal to its default left out (`encodeDefaults = false`). The caller leaves defaults out.
internal struct CBORLabeledWriter<Label: CBORLabel> {
    private var entries: [CBOR.Entry] = []

    var cbor: CBOR { .map(entries) }

    mutating func item(_ label: Label, _ value: CBOR) {
        entries.append(CBOR.Entry(key: .unsigned(label.rawValue), value: value))
    }

    mutating func item(_ label: Label, optional value: CBOR?) {
        if let value {
            item(label, value)
        }
    }
}

extension FieldKind where Value == [[UInt8]] {
    /// A list of byte strings: `compactCbor` writes every `ByteArray`, list elements included, as one
    /// (`alwaysUseByteString`).
    static var byteStrings: Self {
        Self { item in
            guard case .array(let items) = item else {
                return nil
            }
            var strings: [[UInt8]] = []
            strings.reserveCapacity(items.count)
            for element in items {
                guard case .bytes(let bytes) = element else {
                    return nil
                }
                strings.append(bytes)
            }
            return strings
        }
    }
}
