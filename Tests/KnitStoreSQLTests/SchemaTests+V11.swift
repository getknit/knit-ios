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

    @Test func v12NamesNoPictureUntilItsPlaintextIsLearned() throws {
        // A sealed photo stored under v11 knows no plaintext name (ADR 2026-10.f3mv): it is no identity a pick finds,
        // until its bytes are opened (a save), and a room post's is one by its own hash from the start.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v11")
        let bob = fixtureNodeId(2)
        let sealed = BlobHash(String(repeating: "6", count: 64)) ?? .empty
        let plain = BlobHash(String(repeating: "7", count: 64)) ?? .empty
        try queue.write { db in
            for (id, hash, key, conversation) in [("m1", sealed, "a2V5", bob.string), ("m2", plain, nil, "nearby")] {
                try db.execute(
                    sql: """
                        INSERT INTO messages (id, senderId, conversationId, body, sentAt, delivered, pendingKey, kind, moderation,
                            attachmentHash, attachmentMime, attachmentKey)
                        VALUES (?, ?, ?, ?, 3, 0, 0, 0, 0, ?, ?, ?)
                        """,
                    arguments: [
                        StoredText.bytes(id), StoredText.bytes(bob.string), StoredText.bytes(conversation), StoredText.bytes(""),
                        StoredText.bytes(hash.string), StoredText.bytes("image/jpeg"), StoredText.bytes(key),
                    ]
                )
            }
        }
        let database = try KnitDatabase(writer: queue, failures: recordFailure)
        let messages = SQLMessageStore(database)
        #expect(messages.message("m1")?.attachment?.plainHash == nil)
        #expect(messages.identities(matching: plain).map(\.hash) == [plain])
        #expect(messages.keyWantingPlainHash(sealed) == "a2V5")
        #expect(messages.setAttachmentPlainHash(sealed, to: plain))
        #expect(messages.identities(matching: plain).map(\.hash) == [plain, sealed], "the room's public name first")
        #expect(messages.keyWantingPlainHash(sealed) == nil)
    }
}
