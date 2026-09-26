import Foundation
import GRDB
import KnitWire

/// A string as the store keeps it: its UTF-8 bytes, in a `BLOB` column.
///
/// GRDB binds a Swift `String` with `sqlite3_bind_text(…, -1, …)` and reads one back through a C string, so an
/// embedded NUL ends it: `"a\u{0}b"` would be stored as `"a"`, the same row as a frame whose id really is `"a"`.
/// Frame ids come off the wire and key rows by their exact bytes (ADR 2026-09.jc2x). A BLOB keeps every byte,
/// and SQLite compares and orders BLOBs with `memcmp`, exactly as the BINARY collation orders text, so custody's
/// `ORDER BY sentAt, id` means what it means on Android.
internal enum StoredText {
    /// The value to bind for `text`.
    static func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }

    /// The value to bind for `text`, or `NULL`.
    static func bytes(_ text: String?) -> Data? {
        text.map(bytes)
    }
}

extension Row {
    /// The string in `column`, stored by ``StoredText``. Throws on anything but UTF-8 in a BLOB, which only a
    /// damaged file holds.
    func text(_ column: String) throws -> String {
        let data = try decode(Data.self, forColumn: column)
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw StoredValueError(column: column)
        }
        return text
    }

    /// The string in `column`, or `nil` for `NULL`.
    func optionalText(_ column: String) throws -> String? {
        try decode(Data?.self, forColumn: column) == nil ? nil : try text(column)
    }

    /// The bytes in `column`.
    func bytes(_ column: String) throws -> [UInt8] {
        try [UInt8](decode(Data.self, forColumn: column))
    }

    /// The node id in `column`. It throws when the bytes are not one, rather than inventing a peer.
    func nodeId(_ column: String) throws -> NodeId {
        guard let nodeId = NodeId(try text(column)) else {
            throw StoredValueError(column: column)
        }
        return nodeId
    }

    /// The node id in `column`, or `nil` for `NULL`.
    func optionalNodeId(_ column: String) throws -> NodeId? {
        try decode(Data?.self, forColumn: column) == nil ? nil : try nodeId(column)
    }
}

/// A stored value that does not read back as what its column holds: a damaged file, since every write goes
/// through the stores.
internal struct StoredValueError: Error, Equatable {
    /// The column it was read from.
    let column: String
}
