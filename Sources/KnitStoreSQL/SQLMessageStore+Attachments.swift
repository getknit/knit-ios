import GRDB
import KnitStore
public import KnitWire

// Which message first carried a blob, apart from the class only to keep its file inside the lint's length.
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

    /// How many hashes one `IN (…)` list binds, as `SQLBlobStore` binds them.
    private static let hashBatchSize = 500
}
