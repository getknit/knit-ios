import Foundation
import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

/// What the SQL ratchet store adds to the contract `RatchetStoreTests` runs over every kind: an open's rows are one
/// write, so the database takes all of them or none, inside a store unit and outside one, and a write it refuses fails
/// the unit it ran in (ADR 2026-10.5sk9). A TEMP trigger on the writer's connection refuses the write, as
/// `KnitDatabaseUnitTests` does, since the memory and SQL transactors once disagreed. And what it deletes leaves the
/// database's files: zeroed in the file at once, and gone from the write-ahead log once the sweep commits (ADR
/// 2026-09.nyya, amended 2026-10-15).
@Suite struct SQLRatchetStoreTests {
    private let peer = fixtureNodeId(1)
    private static let tag: Int64 = 0x7EA2_D2A5
    private static let oldTag: Int64 = -0x1051_E503
    /// A sweep's clock: past the 48 h a skipped key lives, and an acked epoch after its mint.
    private static let now = RatchetRetention.skippedKeyMilliseconds + 1000
    /// The key an open spends, the keys the sweep expires and the private key of the epoch it retires: bytes nothing else
    /// in the database's files holds.
    private static let spent = fixtureBytes(32, seed: 0xA1)
    private static let expired = fixtureBytes(32, seed: 0xA2)
    private static let retired = fixtureBytes(32, seed: 0xA3)

    /// What the ratchet deletes leaves the files, the sweep run alone or inside a unit. The file zeroes each key as it
    /// goes (`secure_delete`), and the write-ahead log, which still holds the frames that wrote them, is truncated once
    /// the sweep commits. Linux's SQLite zeroes freed pages by default, so here this catches the log; on the Mac, whose
    /// SQLite leaves freed pages as they were, the expired keys' pages catch the file too.
    @Test(arguments: [false, true])
    func whatTheRatchetDeletesLeavesTheFileAndItsLog(inAUnit: Bool) throws {
        try withDatabaseFile(failures: recordFailure) { database, directory throws in
            let ratchet = SQLRatchetStore(database)
            let session = storeKeysThatWillDie(in: ratchet)
            for key in [Self.spent, Self.expired, Self.retired] {
                #expect(try occurs(key, in: directory), "the files hold every key once it is written")
            }

            // The open that spends the key deletes it by its full key and tag; the log keeps the frame that wrote it.
            ratchet.applyOpen(RatchetOpenDelta(session: session, recvEpoch: nil, consumedSkippedTag: Self.tag), from: peer, se: 1, n: 0)
            #expect(try occurs(Self.spent, in: directory), "until the sweep, the log still holds a spent key's insert")

            if inAUnit {
                let unit = database.atomically { () -> Int? in
                    ratchet.sweep(now: Self.now)
                    return 1
                }
                #expect(unit == .committed(1))
            } else {
                ratchet.sweep(now: Self.now)
            }
            let left = ratchet.records(of: peer)
            #expect(left.skippedKeys.isEmpty && left.localEpochs.map(\.epoch) == [4, 3, 2])
            for key in [Self.spent, Self.expired, Self.retired] {
                #expect(try !occurs(key, in: directory), "neither the file nor its log holds a deleted key")
            }
            #expect(try logSize(in: directory) == 0)
        }
    }

    /// Our four epochs, the first minted first and acked, so it retires once 48 h old; a key an open will spend; and
    /// enough expired keys to fill pages the sweep frees whole. Answers the session the rows belong to.
    private func storeKeysThatWillDie(in ratchet: SQLRatchetStore) -> RatchetSessionRecord {
        let session = RatchetSessionRecord(
            peerId: peer, confirmed: true, weAreInitiator: true, root: [1], establishedAt: 1, sendEpoch: 4, highestPeAcked: 4)
        for epoch in 1...4 {
            let key = epoch == 1 ? Self.retired : fixtureBytes(32, seed: 0xB0 + epoch)
            ratchet.commitSend(
                session,
                newLocalEpoch: RatchetLocalEpochRecord(epoch: epoch, privateKey: key, publicKey: [UInt8(epoch)], createdAt: Int64(epoch)))
        }
        let banked =
            [RatchetSkippedKeyRecord(epoch: 1, rootTag: Self.tag, index: 0, messageKey: Self.spent, createdAt: Self.now)]
            + (1...400).map { RatchetSkippedKeyRecord(epoch: 2, rootTag: Self.tag, index: $0, messageKey: Self.expired, createdAt: 1) }
        ratchet.applyOpen(RatchetOpenDelta(session: session, recvEpoch: nil, skippedInserts: banked), from: peer, se: 2, n: 0)
        return session
    }

    /// The log is truncated only as the sweep's outermost unit commits: never when the unit is undone, by its body or by
    /// a store that failed, and not when a nested unit has only joined another.
    @Test func theLogIsTruncatedOnlyAsTheOutermostUnitCommits() throws {
        let failures = Failures()
        try withDatabaseFile(failures: failures.record) { database, directory in
            let ratchet = SQLRatchetStore(database)
            held(in: ratchet)
            // Each unit's outcome is bound before `#expect`: a closure inside its expansion trips Swift 6.4's SIL checker.
            let abandoned = database.atomically { () -> Int? in
                ratchet.sweep(now: Self.now)
                return nil
            }
            #expect(abandoned == .abandoned)
            #expect(try logSize(in: directory) > 0, "an abandoned sweep truncates nothing")

            try refuseSkippedKeys(in: database)
            let failed = database.atomically { () -> Int? in
                ratchet.sweep(now: Self.now)
                ratchet.applyOpen(replacement, from: peer, se: 1, n: 0)
                return 1
            }
            #expect(failed == .failed && failures.count == 1)
            #expect(try logSize(in: directory) > 0, "nor does one a store failed")
            try database.writer.writeWithoutTransaction { db in try db.execute(sql: "DROP TRIGGER refuseKeys") }

            var whileJoined: Int?
            let outer = database.atomically { () -> Int? in
                let nested = database.atomically { () -> Int? in
                    ratchet.sweep(now: Self.now)
                    return 1
                }
                whileJoined = try? logSize(in: directory)
                return nested == .joined(1) ? 1 : nil
            }
            #expect(outer == .committed(1))
            #expect(whileJoined.map { $0 > 0 } == true, "a nested unit has only joined the outer one")
            #expect(try logSize(in: directory) == 0)
        }
    }

    /// A reader holding a snapshot of the log as the sweep commits keeps the log from being truncated. That is expected,
    /// so nothing is reported, and the next sweep truncates it.
    @Test func aReaderOnTheLogPutsTheTruncationOffToTheNextSweep() throws {
        try withDatabaseFile(failures: recordFailure) { database, directory throws in
            let ratchet = SQLRatchetStore(database)
            held(in: ratchet)
            let reading = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                // A read keeps its snapshot of the log from its first statement to its end.
                _ = try? database.writer.read { db -> Int? in
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ratchet_skipped_keys")
                    reading.signal()
                    release.wait()
                    return count
                }
                finished.signal()
            }
            #expect(reading.wait(timeout: .now() + .seconds(30)) == .success)
            ratchet.sweep(now: Self.now)
            let kept = try? logSize(in: directory)
            release.signal()
            #expect(finished.wait(timeout: .now() + .seconds(30)) == .success)
            #expect(kept.map { $0 > 0 } == true, "the reader kept the log, and nothing was reported")
            ratchet.sweep(now: Self.now)
            #expect(try logSize(in: directory) == 0, "the next sweep truncates it")
        }
    }

    /// Any other checkpoint error is reported and fails nothing, even inside a unit: here one asked for inside the unit's
    /// own transaction, which SQLite refuses as locked.
    @Test func anyOtherCheckpointErrorIsReportedAndFailsNothing() throws {
        let failures = Failures()
        try withDatabaseFile(failures: failures.record) { database, _ in
            let ratchet = SQLRatchetStore(database)
            let session = RatchetSessionRecord(peerId: peer, confirmed: true, weAreInitiator: true, root: [1], establishedAt: 1)
            let outcome = database.atomically { () -> Int? in
                database.write(or: ()) { db in SQLRatchetStore.truncateLog(db, reporting: database) }
                ratchet.upsertSession(session)
                return 1
            }
            #expect(outcome == .committed(1))
            #expect(failures.count == 1)
            #expect(ratchet.session(peer) == session)
        }
    }

    @Test func aRatchetWriteTheDatabaseRefusesFailsItsUnitAndUndoesTheOpen() throws {
        let failures = Failures()
        let database = try KnitDatabase.inMemory(failures: failures.record)
        let ratchet = SQLRatchetStore(database)
        held(in: ratchet)
        let before = ratchet.records(of: peer)
        try refuseSkippedKeys(in: database)
        let outcome = database.atomically { () -> String? in
            ratchet.applyOpen(replacement, from: peer, se: 1, n: 0)
            return "deliver"
        }
        #expect(outcome == .failed, "the refused key fails the unit the open ran in")
        #expect(ratchet.records(of: peer) == before, "the purge, the session and the chain went with it")
        #expect(failures.count == 1, "the database reports its error once")
    }

    @Test func outsideAUnitAnOpenStandsWholeOrNotAtAll() throws {
        let failures = Failures()
        let database = try KnitDatabase.inMemory(failures: failures.record)
        let ratchet = SQLRatchetStore(database)
        held(in: ratchet)
        let before = ratchet.records(of: peer)
        try refuseSkippedKeys(in: database)
        ratchet.applyOpen(replacement, from: peer, se: 1, n: 0)
        #expect(ratchet.records(of: peer) == before)
        #expect(failures.count == 1)
        try database.writer.writeWithoutTransaction { db in try db.execute(sql: "DROP TRIGGER refuseKeys") }
        ratchet.applyOpen(replacement, from: peer, se: 1, n: 0)
        let after = ratchet.records(of: peer)
        #expect(after.session?.sendEpoch == 2)
        #expect(after.recvEpochs.map(\.rootTag) == [Self.tag], "the old era's chain went with the purge")
        #expect(after.skippedKeys.map(\.index) == [1])
    }

    /// What the peer's rows hold before the open: an old era's chain and skipped key, and our epoch.
    private func held(in ratchet: SQLRatchetStore) {
        let session = RatchetSessionRecord(peerId: peer, confirmed: true, weAreInitiator: true, root: [1], establishedAt: 1, sendEpoch: 1)
        ratchet.commitSend(session, newLocalEpoch: RatchetLocalEpochRecord(epoch: 1, privateKey: [2], publicKey: [3], createdAt: 1))
        ratchet.applyOpen(
            RatchetOpenDelta(
                session: session,
                recvEpoch: RatchetRecvEpochRecord(epoch: 1, rootTag: Self.oldTag, chainKey: [4], next: 2, lastUsedAt: 1),
                skippedInserts: [RatchetSkippedKeyRecord(epoch: 1, rootTag: Self.oldTag, index: 0, messageKey: [5], createdAt: 1)]
            ),
            from: peer,
            se: 1,
            n: 1
        )
    }

    /// A replacement adopted: the purge, a new session, a new era's chain, a key banked and the old era's spent.
    private var replacement: RatchetOpenDelta {
        RatchetOpenDelta(
            session: RatchetSessionRecord(peerId: peer, confirmed: true, weAreInitiator: false, root: [6], establishedAt: 2, sendEpoch: 2),
            recvEpoch: RatchetRecvEpochRecord(epoch: 1, rootTag: Self.tag, chainKey: [7], next: 2, lastUsedAt: 2),
            skippedInserts: [RatchetSkippedKeyRecord(epoch: 1, rootTag: Self.tag, index: 1, messageKey: [8], createdAt: 2)],
            consumedSkippedTag: Self.oldTag,
            purgePeerRecvState: true
        )
    }

    /// A trigger that refuses every skipped key, as a full disk refuses a write.
    private func refuseSkippedKeys(in database: KnitDatabase) throws {
        try database.writer.writeWithoutTransaction { db in
            try db.execute(
                sql: "CREATE TEMP TRIGGER refuseKeys BEFORE INSERT ON main.ratchet_skipped_keys BEGIN SELECT RAISE(ABORT, 'disk full'); END"
            )
        }
    }
}

/// A database on a pool in a fresh directory, as the app opens it, and that directory, for as long as `body` runs.
private func withDatabaseFile(
    failures: @escaping @Sendable (any Error) -> Void,
    _ body: (KnitDatabase, URL) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "knit-ratchet-\(ProcessInfo.processInfo.globallyUniqueString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(try KnitDatabase.open(in: directory, failures: failures), directory)
}

/// Whether `pattern` occurs in any file in `directory`: the database, its write-ahead log and the log's index. An empty
/// file holds nothing, and is not read, since `Data(contentsOf:)` on Linux leaks its buffer reading one.
private func occurs(_ pattern: [UInt8], in directory: URL) throws -> Bool {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).contains { file in
        let size = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? Int ?? 0
        return try size > 0 && Data(contentsOf: file).contains(Data(pattern))
    }
}

/// The size of the database's write-ahead log in `directory`, in bytes.
private func logSize(in directory: URL) throws -> Int {
    let log = directory.appending(path: KnitDatabase.fileName + "-wal").path(percentEncoded: false)
    return try FileManager.default.attributesOfItem(atPath: log)[.size] as? Int ?? 0
}
