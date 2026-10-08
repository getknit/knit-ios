import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

// Migrations from v11 on test here, so `SchemaTests` stays inside the lint's file length.

extension SchemaTests {
    @Test func v11ReadsAPhotoSizedBeforeItAgain() throws {
        // Whether a photo moves was not kept before v11 (ADR 2026-10.6cas): a photo sized under v10 keeps its size, reads
        // as still, and waits for a launch to read it again, which then keeps both.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v10")
        let bob = fixtureNodeId(2)
        let hash = BlobHash(String(repeating: "5", count: 64)) ?? .empty
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (id, senderId, conversationId, body, sentAt, delivered, pendingKey, kind, moderation,
                        attachmentHash, attachmentMime, attachmentWidth, attachmentHeight)
                    VALUES (?, ?, ?, ?, 3, 0, 0, 0, 0, ?, ?, 480, 270)
                    """,
                arguments: [
                    StoredText.bytes("m1"), StoredText.bytes(bob.string), StoredText.bytes("nearby"), StoredText.bytes(""),
                    StoredText.bytes(hash.string), StoredText.bytes("image/webp"),
                ]
            )
        }
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        let messages = SQLMessageStore(database)
        let still = try #require(PhotoDimensions(width: 480, height: 270))
        #expect(messages.message("m1")?.attachment?.dimensions == still)
        #expect(messages.unsizedAttachments(named: nil).map(\.hash) == [hash])
        let moving = try #require(PhotoDimensions(width: 480, height: 270, animated: true))
        #expect(messages.setAttachmentDimensions(hash, to: moving))
        #expect(messages.message("m1")?.attachment?.dimensions == moving)
        #expect(messages.unsizedAttachments(named: nil).isEmpty)
        #expect(!messages.setAttachmentDimensions(hash, to: moving), "the same reading changes nothing")
    }
}
