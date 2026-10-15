/// The text forms the wire gives bytes, and their exact inverses, for a layout that carries the bytes instead: the v3
/// compact plaintext (``MessageContentV2``). Each `…Bytes` is a round trip, as knit-next's `CanonicalText`,
/// `FrameId.toBytesOrNull` and `NodeId.toBytesOrNull` are (`mesh/protocol/CanonicalText.kt:7-12`): text is taken only
/// when its bytes re-encode to exactly it, so a decoder that drops stray padding bits can never turn one string into
/// another. Each `…Text` takes only bytes of the exact width.
internal enum CanonicalText {
    /// A 22-character frame id's 16 bytes (`FrameId.toBytesOrNull`, `FrameId.kt:39-43`).
    static func frameIdBytes(_ id: String) throws(NonCanonical) -> [UInt8] {
        guard let bytes = FrameId.bytes(of: id) else {
            throw NonCanonical()
        }
        return bytes
    }

    /// The frame id for 16 bytes (`FrameId.fromBytes`, `FrameId.kt:46-49`).
    static func frameIdText(_ bytes: [UInt8]) throws(NonCanonical) -> String {
        guard bytes.count == FrameId.byteCount else {
            throw NonCanonical()
        }
        return FrameId.text(for: bytes)
    }

    /// A 26-character node id's 16 bytes (`NodeId.toBytesOrNull`).
    static func nodeIdBytes(_ id: String) throws(NonCanonical) -> [UInt8] {
        guard let nodeId = NodeId(id) else {
            throw NonCanonical()
        }
        return nodeId.bytes
    }

    /// The node id for 16 bytes (`MessageContentV2.nodeIdText`, `MessageContentV2.kt:152-155`).
    static func nodeIdText(_ bytes: [UInt8]) throws(NonCanonical) -> String {
        guard let nodeId = NodeId(bytes: bytes) else {
            throw NonCanonical()
        }
        return nodeId.string
    }

    /// A content hash's 32 bytes: exactly 64 lowercase hex digits, the only text ``Hex`` reads
    /// (`hashBytesOrNull`, `CanonicalText.kt:37-38`).
    static func hashBytes(_ hex: String) throws(NonCanonical) -> [UInt8] {
        guard hex.utf8.count == BlobHash.length, let bytes = Hex.decode(hex) else {
            throw NonCanonical()
        }
        return bytes
    }

    /// The content hash for 32 bytes (`hashText`, `CanonicalText.kt:40-43`).
    static func hashText(_ bytes: [UInt8]) throws(NonCanonical) -> String {
        guard let hash = BlobHash(digest: bytes) else {
            throw NonCanonical()
        }
        return hash.string
    }

    /// A key's bytes, of any length, from padded standard base64 (`base64BytesOrNull`, `CanonicalText.kt:62-67`).
    static func keyBytes(_ text: String) throws(NonCanonical) -> [UInt8] {
        guard let bytes = Base64.decode(text), Base64.encode(bytes).utf8.elementsEqual(text.utf8) else {
            throw NonCanonical()
        }
        return bytes
    }

    /// The padded standard base64 of a key (`base64Text`, `CanonicalText.kt:69`).
    static func keyText(_ bytes: [UInt8]) -> String {
        Base64.encode(bytes)
    }
}

/// Text with no canonical raw form, or raw bytes of the wrong width for one: compact content then takes the named
/// layout, or decodes to nothing.
internal struct NonCanonical: Error {}
