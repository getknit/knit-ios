import Foundation
import GRDB
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

/// Fails the test that met a database error it did not expect.
@Sendable func recordFailure(_ error: any Error) {
    Issue.record("the database failed: \(error)")
}

/// The errors a database reported, for the tests that expect some.
final class Failures: Sendable {
    private let errors = Lock<[any Error]>([])

    var count: Int { errors.withLock(\.count) }

    @Sendable func record(_ error: any Error) {
        errors.withLock { $0.append(error) }
    }
}

/// A fresh directory under the system's temporary one, removed by `body`'s end.
private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "knit-store-\(ProcessInfo.processInfo.globallyUniqueString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory.appending(path: "Knit", directoryHint: .isDirectory))
}

/// A frame for custody, unsigned.
private func carried(_ id: String, sentAt: Int64 = 1) -> CarriedFrame {
    let envelope = RelayEnvelope(type: .chat, id: id, senderId: "peer", sentAt: sentAt, recipientId: "bob", payload: [])
    return CarriedFrame(envelope: envelope, sig: [1, 2, 3], signed: envelope.encoded)
}

/// What the SQL stores do that the contract tests in `KnitStoreTests` cannot see: the file, its reopening, and
/// what happens when the database fails.
@Suite struct KnitDatabaseTests {
    @Test func aDatabaseOpensInItsOwnDirectoryInWALMode() throws {
        try withTemporaryDirectory { directory in
            let database = try KnitDatabase.open(in: directory, failures: recordFailure)
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: KnitDatabase.fileName).path(percentEncoded: false)))
            let mode = try database.writer.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
            #expect(mode == "wal")
        }
    }

    @Test func whatWasStoredIsThereAfterAReopen() throws {
        try withTemporaryDirectory { directory in
            let alice = fixtureNodeId(1)
            do {
                let database = try KnitDatabase.open(in: directory, failures: recordFailure)
                SQLCustodyStore(database).store(carried("f1"), origin: .own, now: 0)
                SQLOwnProfileStore(database).save(OwnProfile(name: "Alice", version: 3, publishedAt: 4))
                SQLConversationStore(database).accept(alice.string)
            }
            let reopened = try KnitDatabase.open(in: directory, failures: recordFailure)
            #expect(SQLCustodyStore(reopened).liveIds(now: 0) == ["f1"])
            #expect(SQLOwnProfileStore(reopened).load() == OwnProfile(name: "Alice", version: 3, publishedAt: 4))
            #expect(SQLConversationStore(reopened).acceptedConversations() == [alice.string])
            let applied = try reopened.writer.read { try Schema.migrator.appliedMigrations($0) }
            #expect(applied == Schema.migrations.map(\.identifier), "a reopen runs nothing twice")
        }
    }

    @Test func theDirectoryIsExcludedFromBackups() throws {
        try withTemporaryDirectory { directory in
            _ = try KnitDatabase.open(in: directory, failures: recordFailure)
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false), isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
            #if canImport(Darwin)
                let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
                #expect(values.isExcludedFromBackup == true)
            #endif
        }
    }

    @Test func aDatabaseErrorIsReportedAndAnsweredAsNothingThere() throws {
        let failures = Failures()
        let queue = try DatabaseQueue()
        let database = try KnitDatabase(writer: queue, failures: failures.record)
        let custody = SQLCustodyStore(database)
        let messages = SQLMessageStore(database)
        try queue.write { db in
            try db.execute(sql: "DROP TABLE forward_store")
            try db.execute(sql: "DROP TABLE messages")
        }
        #expect(!custody.store(carried("f1"), origin: .relayed, now: 0), "a frame that cannot be kept was not kept")
        #expect(custody.liveIds(now: 0).isEmpty)
        #expect(!custody.contains("f1"))
        #expect(custody.sweepExpired(now: 0) == 0)
        custody.remove("f1")
        #expect(
            !messages.insertIfAbsent(
                MessageRecord(
                    id: "m1", senderId: fixtureNodeId(1), recipientId: nil, conversationId: Conversations.nearby, body: "", sentAt: 1
                )))
        #expect(messages.messages(in: Conversations.nearby).isEmpty)
        #expect(failures.count == 7)
    }

    @Test func aRowThatNoLongerReadsBackIsReportedRatherThanInvented() throws {
        let failures = Failures()
        let queue = try DatabaseQueue()
        let database = try KnitDatabase(writer: queue, failures: failures.record)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO peers (nodeId, name, status, publicKey, updatedAt, verified, openToChat)
                    VALUES (?, x'', x'', x'', 1, 1, 0)
                    """,
                arguments: [Data("not a node id".utf8)]
            )
            try db.execute(
                sql: """
                    INSERT INTO messages (id, senderId, recipientId, conversationId, body, sentAt, delivered, pendingKey)
                    VALUES (x'6D31', ?, x'00', ?, x'', 1, 0, 0)
                    """,
                arguments: [Data(fixtureNodeId(1).string.utf8), Data(fixtureNodeId(1).string.utf8)]
            )
        }
        #expect(SQLPeerStore(database).allPeers().isEmpty)
        #expect(SQLPeerStore(database).verifiedNodeIds().isEmpty)
        #expect(SQLMessageStore(database).messages(in: fixtureNodeId(1).string).isEmpty, "a recipient that is no node id")
        #expect(failures.count == 3)
    }

    @Test func aCarriedFrameWhoseBytesNoLongerDecodeIsSkipped() throws {
        let database = try KnitDatabase.inMemory(failures: recordFailure)
        let custody = SQLCustodyStore(database)
        custody.store(carried("good"), origin: .relayed, now: 0)
        custody.store(carried("bad"), origin: .relayed, now: 0)
        try database.writer.write { db in
            try db.execute(sql: "UPDATE forward_store SET signed = x'FF' WHERE id = ?", arguments: [Data("bad".utf8)])
        }
        #expect(custody.liveFrames(now: 0).map(\.envelope.id) == ["good"])
        #expect(custody.frame("bad", now: 0) == nil)
        #expect(custody.liveIds(now: 0) == ["good", "bad"], "its id still counts: the digest lists it until it expires")
    }

    @Test func custodyRowsKeepTheirOriginTypeAndArrival() throws {
        let database = try KnitDatabase.inMemory(failures: recordFailure)
        let custody = SQLCustodyStore(database)
        custody.store(carried("mine"), origin: .own, now: 5)
        custody.store(carried("theirs"), origin: .relayed, now: 6)
        let rows = try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, origin, type, receivedAt, sig FROM forward_store ORDER BY seq")
        }
        #expect(try rows.map { try $0.text("id") } == ["mine", "theirs"])
        #expect(rows.map { $0["origin"] as Int } == [1, 0], "knit-next's ORIGIN_SELF and ORIGIN_RELAY")
        #expect(try rows.map { try $0.text("type") } == ["chat", "chat"])
        #expect(rows.map { $0["receivedAt"] as Int64 } == [5, 6])
        #expect(try rows.map { try $0.bytes("sig") } == [[1, 2, 3], [1, 2, 3]])
    }
}
