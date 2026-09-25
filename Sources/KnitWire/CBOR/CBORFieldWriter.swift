/// Builds a named-layout map the way kotlinx writes one: fields in declaration order, and a field equal to
/// its default left out (`encodeDefaults = false`).
///
/// Call the methods in the Kotlin class's declaration order. Each `optional` variant skips `nil`; the
/// `defaulted` variants skip a value equal to the field's default.
internal struct CBORFieldWriter {
    private var entries: [CBOR.Entry] = []

    var cbor: CBOR { .map(entries) }

    mutating func item(_ key: String, _ value: CBOR) {
        entries.append(CBOR.Entry(key: .text(key), value: value))
    }

    mutating func text(_ key: String, _ value: String) {
        item(key, .text(value))
    }

    mutating func text(_ key: String, optional value: String?) {
        if let value {
            text(key, value)
        }
    }

    mutating func text(_ key: String, _ value: String, default defaultValue: String) {
        if value != defaultValue {
            text(key, value)
        }
    }

    mutating func int(_ key: String, _ value: Int) {
        item(key, CBOR(Int64(value)))
    }

    mutating func int(_ key: String, optional value: Int?) {
        if let value {
            int(key, value)
        }
    }

    mutating func int(_ key: String, _ value: Int, default defaultValue: Int) {
        if value != defaultValue {
            int(key, value)
        }
    }

    mutating func long(_ key: String, _ value: Int64) {
        item(key, CBOR(value))
    }

    mutating func long(_ key: String, optional value: Int64?) {
        if let value {
            long(key, value)
        }
    }

    mutating func long(_ key: String, _ value: Int64, default defaultValue: Int64) {
        if value != defaultValue {
            long(key, value)
        }
    }

    mutating func bool(_ key: String, _ value: Bool, default defaultValue: Bool) {
        if value != defaultValue {
            item(key, .bool(value))
        }
    }

    mutating func bytes(_ key: String, _ value: [UInt8]) {
        item(key, .bytes(value))
    }

    mutating func texts(_ key: String, _ value: [String]) {
        item(key, .array(value.map(CBOR.text)))
    }

    mutating func texts(_ key: String, optional value: [String]?) {
        if let value {
            texts(key, value)
        }
    }

    mutating func object(_ key: String, _ value: some CBORRepresentable) {
        item(key, value.cbor)
    }

    mutating func object(_ key: String, optional value: (some CBORRepresentable)?) {
        if let value {
            object(key, value)
        }
    }

    mutating func raw(_ key: String, optional value: CBOR?) {
        if let value {
            item(key, value)
        }
    }

    mutating func list(_ key: String, _ value: [some CBORRepresentable]) {
        item(key, .array(value.map(\.cbor)))
    }

    /// A list whose default is empty: written only when it has elements.
    mutating func list(_ key: String, omittingEmpty value: [some CBORRepresentable]) {
        if !value.isEmpty {
            list(key, value)
        }
    }
}
