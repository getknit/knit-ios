import Foundation
import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

// v23, voice notes, tests here, so `SchemaTests+V22` stays small.

extension SchemaTests {
    @Test func v23StartsEveryHeldVoiceNoteUndescribed() throws {
        // Nothing described a voice note before v23 (knit-next ADR 034): one held reads with no description, and is listed
        // for a launch to read.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v22")
        let bob = fixtureNodeId(2)
        let blob = BlobHash(String(repeating: "1", count: 64)) ?? .empty
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (id, senderId, conversationId, body, sentAt, arrivedAt, delivered, pendingKey, kind, moderation,
                        attachmentHash, attachmentMime, attachmentKey)
                    VALUES (?, ?, ?, ?, 3, 3, 0, 0, 0, 0, ?, ?, ?)
                    """,
                arguments: [
                    StoredText.bytes("m1"), StoredText.bytes(bob.string), StoredText.bytes(bob.string), StoredText.bytes(""),
                    StoredText.bytes(blob.string), StoredText.bytes("audio/aac"), StoredText.bytes("aw=="),
                ]
            )
        }
        try Schema.migrator.migrate(queue)
        let messages = SQLMessageStore(try KnitDatabase(writer: queue, failures: recordFailure))
        #expect(messages.message("m1")?.attachment?.voice == nil)
        #expect(messages.undescribedVoiceNotes(named: nil).map(\.hash) == [blob])
        let description = VoiceDescription(durationMs: 10_031, peaks: Array(repeating: 7, count: 64))
        #expect(messages.setVoiceDescription(description, named: blob))
        #expect(messages.message("m1")?.attachment?.voice == description)
        #expect(messages.undescribedVoiceNotes(named: nil).isEmpty)
    }

    @Test func aWaveformThatIsNotOneReadsAsMissingAndTheThreadStillReads() throws {
        let database = try KnitDatabase.inMemory(failures: recordFailure)
        let messages = SQLMessageStore(database)
        let bob = fixtureNodeId(2)
        let blob = BlobHash(String(repeating: "2", count: 64)) ?? .empty
        messages.save(
            MessageRecord(
                id: "m1",
                senderId: bob,
                recipientId: nil,
                conversationId: bob.string,
                body: "",
                sentAt: 1,
                attachment: MessageAttachment(hash: blob, mime: "audio/aac", key: "aw==")
            )
        )
        // An empty waveform, written past the store.
        try database.writer.write { db in
            try db.execute(sql: "UPDATE messages SET voiceDurationMs = 5, voicePeaks = x''")
        }
        #expect(messages.messages(in: bob.string).map(\.attachment?.voice) == [VoiceDescription(durationMs: 5)])
        try database.writer.write { db in
            try db.execute(sql: "UPDATE messages SET voiceDurationMs = NULL")
        }
        #expect(messages.message("m1")?.attachment?.voice == nil)
        #expect(messages.messages(in: bob.string).count == 1)
        #expect(messages.threadHeads(excludingSenders: []).count == 1)
        // The table is STRICT, so no other type can be written there; a damaged file could hold one all the same.
        for value in ["'text'", "1", "1.5"] {
            #expect(throws: (any Error).self) {
                try database.writer.write { db in try db.execute(sql: "UPDATE messages SET voicePeaks = \(value)") }
            }
        }
        // So the read is checked on rows of every other type: each reads as missing, and none throws.
        let rows = try database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT 'text' AS voiceDurationMs, 'text' AS voicePeaks UNION ALL SELECT 1.5, 7 UNION ALL SELECT x'01', 2.5
                    UNION ALL SELECT NULL, NULL UNION ALL SELECT 9, x'0102'
                    """
            )
        }
        #expect(rows.map(SQLMessageStore.voice) == [nil, nil, nil, nil, VoiceDescription(durationMs: 9, peaks: [1, 2])])
    }
}
