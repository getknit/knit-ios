import GRDB
public import KnitStore
public import KnitWire

// Which messages carry a blob, and under which names (ADR 2026-10.f3mv), apart from the class only to keep its file inside
// the lint's length.
extension SQLMessageStore {
    /// Who sent the earliest message carrying each of `hashes` (``MessageStore/attachmentSenders(among:)``).
    public func attachmentSenders(among hashes: Set<BlobHash>) -> [BlobHash: NodeId] {
        let sorted = hashes.sorted()
        var senders: [BlobHash: NodeId] = [:]
        for start in stride(from: 0, to: sorted.count, by: Self.hashBatchSize) {
            let batch = sorted[start..<min(start + Self.hashBatchSize, sorted.count)]
            let carriers = database.read(or: []) { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT attachmentHash, senderId FROM messages
                        WHERE attachmentHash IN (\(Array(repeating: "?", count: batch.count).joined(separator: ", ")))
                        ORDER BY sentAt, id
                        """,
                    arguments: StatementArguments(batch.map { StoredText.bytes($0.string) })
                )
                .map { (hash: try $0.blobHash("attachmentHash"), sender: try $0.nodeId("senderId")) }
            }
            // Earliest first, so the first row for each hash names its sender.
            for carrier in carriers where senders[carrier.hash] == nil {
                senders[carrier.hash] = carrier.sender
            }
        }
        return senders
    }

    /// The pictures held under a name `bytesHash` could be, best first (``MessageStore/identities(matching:)``).
    public func identities(matching bytesHash: BlobHash) -> [MessageAttachment] {
        // `MessageDao.identityFor` (knit-next 5f521cb9), less its join on the blobs, which the engine asks of its own
        // store. The three names are ORed over the whole table: it runs once a pick, never on the way in.
        database.read(or: []) { db in
            let named = StoredText.bytes(bytesHash.string)
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.attachmentColumns) FROM messages
                    WHERE attachmentHash IS NOT NULL AND attachmentMime IS NOT NULL
                        AND (attachmentKey IS NULL OR attachmentPlainHash IS NOT NULL)
                        AND (attachmentPlainHash = ? OR attachmentSourceHash = ? OR (attachmentKey IS NULL AND attachmentHash = ?))
                    ORDER BY attachmentAnimated IS NOT 1, attachmentKey IS NOT NULL, sentAt, id
                    LIMIT \(Self.identityLimit)
                    """,
                arguments: [named, named, named]
            ).compactMap(Self.attachment)
        }
    }

    /// The messages carrying a sealed copy of plaintext `plainHash` (``MessageStore/sealedCopies(of:)``).
    public func sealedCopies(of plainHash: BlobHash) -> [MessageRecord] {
        database.read(or: []) { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.columns) FROM messages
                    WHERE attachmentPlainHash = ? AND attachmentKey IS NOT NULL AND attachmentMime IS NOT NULL
                    ORDER BY sentAt, id
                    LIMIT \(Self.identityLimit)
                    """,
                arguments: [StoredText.bytes(plainHash.string)]
            ).map(Self.record)
        }
    }

    /// The key of a sealed message carrying `hash` with no plaintext name (``MessageStore/keyWantingPlainHash(_:)``).
    public func keyWantingPlainHash(_ hash: BlobHash) -> String? {
        database.read(or: nil) { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT attachmentKey FROM messages
                    WHERE attachmentHash = ? AND attachmentKey IS NOT NULL AND attachmentPlainHash IS NULL LIMIT 1
                    """,
                arguments: [StoredText.bytes(hash.string)]
            ).map { try $0.text("attachmentKey") }
        }
    }

    /// Names the plaintext of sealed blob `hash` (``MessageStore/setAttachmentPlainHash(_:to:)``).
    @discardableResult
    public func setAttachmentPlainHash(_ hash: BlobHash, to plainHash: BlobHash) -> Bool {
        database.write(or: false) { db in
            try db.execute(
                sql: """
                    UPDATE messages SET attachmentPlainHash = ?
                    WHERE attachmentHash = ? AND attachmentKey IS NOT NULL AND attachmentPlainHash IS NULL
                    """,
                arguments: [StoredText.bytes(plainHash.string), StoredText.bytes(hash.string)]
            )
            return db.changesCount > 0
        }
    }

    /// The most rows one look for a picture's names reads: they are tried in order until one's blob is held.
    private static let identityLimit = 16

    /// The columns ``attachment(_:)`` reads.
    static let attachmentColumns = """
        attachmentHash, attachmentMime, attachmentKey, attachmentName, attachmentSize, attachmentWidth, attachmentHeight, \
        attachmentAnimated, attachmentPlainHash, attachmentSourceHash
        """

    /// The size a row's photo was read at, and whether it moves. One sized before schema v11 reads as still until a
    /// launch reads it again (``unsizedAttachments(named:)``).
    private static func dimensions(_ row: Row) throws -> PhotoDimensions? {
        guard let width = try row.decode(Int?.self, forColumn: "attachmentWidth"),
            let height = try row.decode(Int?.self, forColumn: "attachmentHeight")
        else {
            return nil
        }
        return PhotoDimensions(width: width, height: height, animated: try row.decode(Int?.self, forColumn: "attachmentAnimated") == 1)
    }

    /// What the row carries, or `nil` for nothing.
    static func attachment(_ row: Row) throws -> MessageAttachment? {
        try row.optionalBlobHash("attachmentHash").map { hash in
            MessageAttachment(
                hash: hash,
                mime: try row.optionalText("attachmentMime"),
                key: try row.optionalText("attachmentKey"),
                name: try row.optionalText("attachmentName"),
                size: try row.decode(Int64?.self, forColumn: "attachmentSize"),
                dimensions: try dimensions(row),
                plainHash: try row.optionalBlobHash("attachmentPlainHash"),
                sourceHash: try row.optionalBlobHash("attachmentSourceHash")
            )
        }
    }

    /// How many hashes one `IN (…)` list binds, as `SQLBlobStore` binds them.
    private static let hashBatchSize = 500
}
