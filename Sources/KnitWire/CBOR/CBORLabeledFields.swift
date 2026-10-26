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
/// kotlinx-cbor 1.12.0's lenient key lookup (`decodeElementNameWithTagsLenient`, `Decoder.kt:102-108`), which this
/// mirrors, with the value rules ``CBORFields`` lists (tags skipped, every occurrence decoded, the null mark):
///
/// - An unsigned integer key is a label, and a label the class does not have is skipped (`ignoreUnknownKeys`).
/// - A text key is a property name, so `"body"` reads as label 1, and an unknown name is skipped. Names compare by
///   their UTF-8 bytes, as Kotlin compares strings, never by Swift's canonical equivalence (ADR 2026-09.jc2x).
/// - Tags before a key are skipped (`nextTaggedStringOrNumber`, `:346-358`).
/// - A key of any other major type is refused, as `readNumber` throws on it (`:406-415`).
///
/// A negative key is refused here too, while kotlinx reads it as a label and skips it unless it wraps to a real one
/// (`3B FFFFFFFFFFFFFFEF` reads as 16). No encoder writes one; knit-ios #13 owes the port.
internal struct CBORLabeledFields<Label: CBORLabel> {
    private let typeName: String
    private let values: [UInt64: [CBOR]]

    init(_ item: CBOR, type typeName: String) throws(WireDecodingError) {
        var collected: [UInt64: [CBOR]] = [:]
        for entry in try item.fieldEntries(type: typeName) {
            switch entry.key.untagged {
            case .unsigned(let label):
                collected[label, default: []].append(entry.value)
            case .text(let name):
                if let label = Label.allCases.first(where: { $0.name.utf8.elementsEqual(name.utf8) }) {
                    collected[label.rawValue, default: []].append(entry.value)
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
        try FieldReading.optional(values[label.rawValue], kind, type: typeName, field: label.name)
    }

    /// A nullable field: `nil` when absent, `null` or `A0`.
    func nullable<Value>(_ label: Label, _ kind: FieldKind<Value>) throws(WireDecodingError) -> Value? {
        try FieldReading.nullable(values[label.rawValue], kind, type: typeName, field: label.name)
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
    /// A list of byte strings, each read under its own tags: `compactCbor` writes every `ByteArray`, list elements
    /// included, as one (`alwaysUseByteString`).
    static var byteStrings: Self {
        Self { item in
            guard case .array(let items) = item else {
                return nil
            }
            var strings: [[UInt8]] = []
            strings.reserveCapacity(items.count)
            for element in items {
                guard case .bytes(let bytes) = element.untagged else {
                    return nil
                }
                strings.append(bytes)
            }
            return strings
        }
    }
}
