import Foundation
import GRDB
import KnitStore
import KnitSync
import Testing

@testable import KnitStoreSQL

/// The two writers the database runs on: the file's pool, as the app opens it, and the queue in memory that the tests and
/// previews use.
enum WriterKind: CaseIterable, Sendable, CustomTestStringConvertible {
    case pool
    case queue

    var testDescription: String {
        switch self {
        case .pool:
            "pool"
        case .queue:
            "queue"
        }
    }

    /// A fresh database on this writer, which hands its errors to `failures`, for as long as `body` runs.
    func withDatabase(failures: @escaping @Sendable (any Error) -> Void, _ body: (KnitDatabase) throws -> Void) throws {
        switch self {
        case .pool:
            try withPool(failures: failures) { database, _ in try body(database) }
        case .queue:
            try body(try KnitDatabase.inMemory(failures: failures))
        }
    }
}

/// A database on a pool in a fresh directory, and its file, for as long as `body` runs.
private func withPool(failures: @escaping @Sendable (any Error) -> Void, _ body: (KnitDatabase, URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "knit-unit-\(ProcessInfo.processInfo.globallyUniqueString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try KnitDatabase.open(in: directory, failures: failures)
    try body(database, directory.appending(path: KnitDatabase.fileName))
}

/// Runs `sql` on the writer's connection, where every store writes, so a TEMP trigger there sees their writes.
private func onWriter(_ database: KnitDatabase, _ sql: String) throws {
    try database.writer.writeWithoutTransaction { db in
        try db.execute(sql: sql)
    }
}

/// A trigger that refuses one conversation id, as a full disk refuses a write: `action` is `ABORT` for that statement
/// alone, or `ROLLBACK` for the whole transaction, as SQLite does by itself on some I/O errors.
private func refuse(_ conversationId: String, with action: String = "ABORT", in database: KnitDatabase) throws {
    try onWriter(
        database,
        """
        CREATE TEMP TRIGGER "refuse \(conversationId)" BEFORE INSERT ON main.accepted_conversations
        WHEN NEW.conversationId = CAST('\(conversationId)' AS BLOB) BEGIN SELECT RAISE(\(action), 'disk full'); END
        """
    )
}

/// The store unit on each writer the database runs on (ADR 2026-10.5sk9): what the contract tests in `KnitStoreTests`
/// cannot see, which is other threads, a commit that fails, and how a failure is reported.
@Suite struct KnitDatabaseUnitTests {
    private static let kinds = WriterKind.allCases

    @Test(arguments: kinds)
    func aWriteFromAnotherThreadWaitsForTheUnitAndStandsOnItsOwn(kind: WriterKind) throws {
        let failures = Failures()
        try kind.withDatabase(failures: failures.record) { database in
            let conversations = SQLConversationStore(database)
            let started = DispatchSemaphore(value: 0)
            let landed = DispatchSemaphore(value: 0)
            let outcome = database.atomically { () -> Int? in
                conversations.accept("inside")
                DispatchQueue.global().async {
                    started.signal()
                    conversations.accept("outside")
                    landed.signal()
                }
                started.wait()
                #expect(landed.wait(timeout: .now()) == .timedOut, "nothing lands while the unit holds the writer")
                return nil
            }
            landed.wait()
            #expect(outcome == .abandoned)
            #expect(conversations.acceptedConversations() == ["outside"], "undoing the unit left the other write standing")
            #expect(failures.descriptions.isEmpty)
        }
    }

    @Test(arguments: kinds)
    func aWriteFromAnotherThreadThatFailsNeverFailsTheUnit(kind: WriterKind) throws {
        let failures = Failures()
        try kind.withDatabase(failures: failures.record) { database in
            let conversations = SQLConversationStore(database)
            try refuse("outside", in: database)
            let started = DispatchSemaphore(value: 0)
            let landed = DispatchSemaphore(value: 0)
            let outcome = database.atomically { () -> Int? in
                conversations.accept("inside")
                DispatchQueue.global().async {
                    started.signal()
                    conversations.accept("outside")
                    landed.signal()
                }
                started.wait()
                return 1
            }
            landed.wait()
            #expect(outcome == .committed(1))
            #expect(conversations.acceptedConversations() == ["inside"])
            #expect(failures.count == 1, "the other write's error, reported for it alone")
        }
    }

    @Test(arguments: kinds)
    func aReadInsideTheUnitSeesWhatItWrote(kind: WriterKind) throws {
        // The pool's readers would not see it, and the queue's read would trap on its own queue.
        try kind.withDatabase(failures: recordFailure) { database in
            let conversations = SQLConversationStore(database)
            let outcome = database.atomically { () -> Int? in
                conversations.accept("inside")
                #expect(conversations.acceptedConversations() == ["inside"])
                return nil
            }
            #expect(outcome == .abandoned)
            #expect(conversations.acceptedConversations().isEmpty)
        }
    }

    @Test(arguments: kinds)
    func aReadFromAnotherThreadSeesOnlyWhatIsCommitted(kind: WriterKind) throws {
        try kind.withDatabase(failures: recordFailure) { database in
            let conversations = SQLConversationStore(database)
            conversations.accept("before")
            let seen = Lock<Set<String>>([])
            let read = DispatchSemaphore(value: 0)
            let outcome = database.atomically { () -> Int? in
                conversations.accept("inside")
                DispatchQueue.global().async {
                    let accepted = conversations.acceptedConversations()
                    seen.withLock { $0 = accepted }
                    read.signal()
                }
                if kind == .pool {
                    // The pool's readers never wait on its writer, so this read ends while the unit is still open.
                    #expect(read.wait(timeout: .now() + .seconds(30)) == .success)
                }
                return 1
            }
            if kind == .queue {
                read.wait()
            }
            #expect(outcome == .committed(1))
            switch kind {
            case .pool:
                #expect(seen.withLock { $0 } == ["before"], "a snapshot holds nothing of a unit still open")
            case .queue:
                #expect(seen.withLock { $0 } == ["before", "inside"], "the queue's one connection waited for the commit")
            }
        }
    }

    @Test(arguments: kinds)
    func aWriteErrorInsideAUnitIsReportedOnceAndFailsIt(kind: WriterKind) throws {
        let failures = Failures()
        try kind.withDatabase(failures: failures.record) { database in
            let conversations = SQLConversationStore(database)
            try refuse("refused", in: database)
            let outcome = database.atomically { () -> Int? in
                conversations.accept("kept")
                conversations.accept("refused")
                #expect(failures.count == 1, "reported as the write failed")
                conversations.accept("after")
                #expect(conversations.acceptedConversations().isEmpty, "nothing more runs in a unit that failed")
                return 1
            }
            #expect(outcome == .failed)
            #expect(failures.count == 1, "and not again for the unit")
            #expect(failures.descriptions.first?.contains("disk full") == true)
            #expect(conversations.acceptedConversations().isEmpty)
        }
    }

    @Test(arguments: kinds, [1, nil] as [Int?])
    func aWriteThatSQLiteRollsBackFailsTheUnitOnce(kind: WriterKind, answer: Int?) throws {
        // A body that then answers nil fails too: with no transaction left, GRDB's rollback throws nothing to say so.
        let failures = Failures()
        try kind.withDatabase(failures: failures.record) { database in
            let conversations = SQLConversationStore(database)
            try refuse("rolls back", with: "ROLLBACK", in: database)
            var nested: Transacted<Int>?
            let outcome = database.atomically { () -> Int? in
                conversations.accept("kept")
                conversations.accept("rolls back")
                // Every statement would now throw SQLITE_ABORT: none runs, and none is reported.
                conversations.accept("after")
                #expect(conversations.acceptedConversations().isEmpty)
                nested = database.atomically { () -> Int? in 2 }
                return answer
            }
            #expect(outcome == .failed)
            #expect(nested == .failed)
            #expect(failures.count == 1)
            #expect(conversations.acceptedConversations().isEmpty)
            conversations.accept("next")
            #expect(conversations.acceptedConversations() == ["next"], "the database writes again once the unit is over")
        }
    }

    @Test(arguments: kinds, [1, nil] as [Int?])
    func aReadErrorInsideAUnitFailsIt(kind: WriterKind, answer: Int?) throws {
        // The body would go on as if nobody were pinned, and decide on that.
        let failures = Failures()
        try kind.withDatabase(failures: failures.record) { database in
            let conversations = SQLConversationStore(database)
            let peers = SQLPeerStore(database)
            try database.writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO peers (nodeId, name, status, publicKey, updatedAt, verified, openToChat)
                        VALUES (?, x'', x'', x'', 1, 0, 0)
                        """,
                    arguments: [Data("not a node id".utf8)]
                )
            }
            let outcome = database.atomically { () -> Int? in
                conversations.accept("kept")
                #expect(peers.allPeers().isEmpty)
                return answer
            }
            #expect(outcome == .failed, "whatever the body answered")
            #expect(failures.count == 1)
            #expect(conversations.acceptedConversations().isEmpty)
        }
    }

    @Test(arguments: kinds)
    func aCommitThatFailsAnswersFailedAndLeavesNothing(kind: WriterKind) throws {
        let failures = Failures()
        try kind.withDatabase(failures: failures.record) { database in
            let conversations = SQLConversationStore(database)
            // A row that points nowhere, which SQLite checks only at the commit: the commit fails, as one on a full disk
            // does.
            try onWriter(
                database,
                """
                CREATE TEMP TABLE parent (id INTEGER PRIMARY KEY);
                CREATE TEMP TABLE child (parent INTEGER REFERENCES parent (id) DEFERRABLE INITIALLY DEFERRED);
                CREATE TEMP TRIGGER dangle AFTER INSERT ON main.accepted_conversations BEGIN
                    INSERT INTO child (parent) VALUES (1);
                END;
                """
            )
            let outcome = database.atomically { () -> Int? in
                conversations.accept("lost")
                return 1
            }
            #expect(outcome == .failed)
            #expect(failures.count == 1)
            #expect(failures.descriptions.first?.contains("FOREIGN KEY") == true)
            #expect(conversations.acceptedConversations().isEmpty)
        }
    }

    @Test(arguments: kinds)
    func outsideAUnitAStoreWritesAndReadsAsItAlwaysHas(kind: WriterKind) throws {
        let failures = Failures()
        try kind.withDatabase(failures: failures.record) { database in
            let conversations = SQLConversationStore(database)
            conversations.accept("one")
            #expect(conversations.acceptedConversations() == ["one"], "each write commits on its own")
            try refuse("refused", in: database)
            conversations.accept("refused")
            #expect(failures.count == 1, "a refused write is reported, and keeps nothing")
            #expect(conversations.acceptedConversations() == ["one"])
            try database.writer.write { db in
                try db.execute(sql: "DROP TABLE accepted_conversations")
            }
            #expect(conversations.acceptedConversations().isEmpty, "a read that fails answers nothing")
            #expect(failures.count == 2)
            #expect(database.atomically { () -> Int? in 3 } == .committed(3), "no unit was failed by any of it")
        }
    }

    @Test func aUnitThatCannotBeginRunsNothing() throws {
        let failures = Failures()
        try withPool(failures: failures.record) { database, file in
            // Another connection holds the file's write lock, so the unit's BEGIN IMMEDIATE meets SQLITE_BUSY.
            var configuration = Configuration()
            configuration.allowsUnsafeTransactions = true
            let other = try DatabaseQueue(path: file.path(percentEncoded: false), configuration: configuration)
            try other.writeWithoutTransaction { db in
                try db.execute(sql: "BEGIN IMMEDIATE")
            }
            var ran = false
            let outcome = database.atomically { () -> Int? in
                ran = true
                return 1
            }
            #expect(outcome == .failed)
            #expect(!ran, "its body never ran")
            #expect(failures.count == 1)
            try other.writeWithoutTransaction { db in
                try db.execute(sql: "ROLLBACK")
            }
            #expect(database.atomically { () -> Int? in 2 } == .committed(2), "it begins once the lock is free")
        }
    }
}
