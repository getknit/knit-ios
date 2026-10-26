import KnitWire
import Testing

/// Edits a decoded fixture one key at a time, so a test can swap one value for a wrong type or a hostile form and leave
/// the rest as Android wrote it.
extension CBOR {
    /// A text key.
    static func key(_ name: String) -> Self { .text(name) }

    /// The value of the last entry under `key`, when this is a map.
    subscript(key: Self) -> Self? {
        guard case .map(let entries) = self else {
            return nil
        }
        return entries.last { $0.key == key }?.value
    }

    /// This map with every entry under `key` given `value`, or one appended when there is none.
    func setting(_ key: Self, _ value: Self) -> Self {
        guard case .map(let entries) = self else {
            return self
        }
        guard entries.contains(where: { $0.key == key }) else {
            return .map(entries + [Entry(key: key, value: value)])
        }
        return .map(entries.map { $0.key == key ? Entry(key: key, value: value) : $0 })
    }

    /// This map without `key`.
    func removing(_ key: Self) -> Self {
        guard case .map(let entries) = self else {
            return self
        }
        return .map(entries.filter { $0.key != key })
    }

    /// This map with one more entry, a duplicate key included, placed first or last.
    func adding(_ key: Self, _ value: Self, first: Bool = false) -> Self {
        guard case .map(let entries) = self else {
            return self
        }
        let entry = Entry(key: key, value: value)
        return .map(first ? [entry] + entries : entries + [entry])
    }

    /// This map with the map under `key` edited by `edit`.
    func editing(_ key: Self, _ edit: (Self) -> Self) -> Self {
        guard let inner = self[key] else {
            return self
        }
        return setting(key, edit(inner))
    }

    /// `item` under `count` tags, numbered so the run is not one tag repeated.
    static func underTags(_ item: Self, count: Int) -> Self {
        (0..<count).reduce(item) { inner, number in .tagged(UInt64(number), inner) }
    }
}

/// An item the encoder cannot write, such as an empty map in a longer form than `A0`, put in place of a sentinel.
enum Splice {
    /// The sentinel text, which no fixture holds. Computed, not stored: a static `CBOR` keeps an indirect enum's box,
    /// whose tagged pointer LeakSanitizer cannot see, so `check.sh asan` reports it as a leak.
    static var sentinel: CBOR { .text("@@splice@@") }

    /// `item`'s bytes with its one ``sentinel`` replaced by `raw`.
    static func bytes(_ item: CBOR, _ raw: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) -> [UInt8] {
        let encoded = item.encoded
        let mark = sentinel.encoded
        let starts = encoded.indices.filter { encoded[$0...].starts(with: mark) }
        #expect(starts.count == 1, "one sentinel in the item", sourceLocation: sourceLocation)
        guard let start = starts.first else {
            return encoded
        }
        return Array(encoded[..<start]) + raw + Array(encoded[(start + mark.count)...])
    }
}
