public import Foundation
import GRDB
import KnitSync

/// The app's database: one SQLite file, migrated to this build's schema, behind every SQL store
/// (ADR 2026-09.nyya).
///
/// The store protocols are synchronous and cannot throw, because the mesh engine calls them from its actor
/// (ADR 2026-09.gq84). So a store that hits a database error answers as if nothing were there, and reports the
/// error through ``failures``: the mesh keeps running on what it holds in memory, and the app can say that
/// storage is failing. A disk that is full, or a file Data Protection has locked, is the realistic cause.
///
/// It is also the store unit its stores commit in (``atomically(_:)``, in `KnitDatabase+Units.swift`): inside a unit a
/// store's error still answers the fallback and is still reported, and it fails the whole unit too, except a blob's file
/// error, which is reported and fails nothing (``report(_:)``).
public final class KnitDatabase: Sendable {
    /// The database file's name inside its directory.
    public static let fileName = "knit.sqlite"

    /// How many migrations this build knows: the schema version it writes.
    public static var schemaVersion: Int { Schema.migrations.count }

    let writer: any DatabaseWriter
    private let failures: @Sendable (any Error) -> Void
    /// The store unit open on ``writer``'s connection, if one is.
    let unit = Lock(OpenUnit())

    /// A database on `writer`, migrated up to this build's schema.
    init(writer: any DatabaseWriter, failures: @escaping @Sendable (any Error) -> Void) throws {
        try Schema.migrator.migrate(writer)
        self.writer = writer
        self.failures = failures
    }

    /// Opens the database in `directory`, creating both if needed, and migrates it.
    ///
    /// The directory holds the database and SQLite's journal files together, so its protection covers all of
    /// them: on iOS it is `completeUntilFirstUserAuthentication`, which lets the mesh read and write while the
    /// phone is locked after its first unlock, and on every Apple platform it is excluded from backups
    /// (``StorageDirectory``). The file runs in WAL mode, so the interface reads while the mesh writes.
    ///
    /// `failures` hears about every error a store meets after the open. An error inside a store unit, or one met as a
    /// write commits, reaches it on the writer's queue while that queue holds the database, so it must never block on the
    /// main actor, which may be waiting for the database, nor touch the database itself. The app's only logs.
    @preconcurrency
    public static func open(in directory: URL, failures: @escaping @Sendable (any Error) -> Void) throws -> KnitDatabase {
        try StorageDirectory.prepare(directory)
        let file = directory.appending(path: fileName)
        let pool = try DatabasePool(path: file.path(percentEncoded: false), configuration: configuration)
        try StorageDirectory.protect(file)
        return try KnitDatabase(writer: pool, failures: failures)
    }

    /// A private database in memory, gone with the value: for tests and previews. `failures` keeps the rules
    /// ``open(in:failures:)`` gives it.
    @preconcurrency
    public static func inMemory(failures: @escaping @Sendable (any Error) -> Void) throws -> KnitDatabase {
        try KnitDatabase(writer: DatabaseQueue(configuration: configuration), failures: failures)
    }

    /// Every connection, the writer's and each reader's, erases what it deletes (ADR 2026-09.nyya, amended 2026-10-15).
    /// `secure_delete` ON overwrites a deleted row with zeros, and every page a deletion frees. Apple's SQLite defaults to
    /// FAST, measured as 2 on the Mac's 3.54.0, which zeroes a row only where that costs no extra write and leaves freed
    /// pages on the freelist as they were. What the ratchet spends and its sweep deletes is what a later compromise of the
    /// phone must no longer open (`RatchetRetention`), so it has to leave the file, not only the tables. Linux's system
    /// SQLite is built with it on, and Android's SQLCipher turns it on itself. Over FAST it costs one more page write for
    /// each page a deletion frees that was not being written anyway: an overflow page, or the pages a bulk delete empties,
    /// as custody's sweep and the ratchet's do. The zeros reach the file only at a checkpoint, and the write-ahead log
    /// keeps what it wrote until it is reset; the ratchet's sweep forces both (`SQLRatchetStore.sweep`).
    private static var configuration: Configuration {
        var settings = Configuration()
        settings.label = "knit"
        settings.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        return settings
    }

    /// Runs `updates` in one write transaction. On an error the transaction rolls back, the error goes to
    /// ``failures``, and the answer is `fallback`. Inside a store unit the write joins the unit instead, in a savepoint of
    /// its own, and an error fails the unit as well.
    func write<T>(or fallback: T, _ updates: (Database) throws -> T) -> T {
        var failure: (any Error)?
        let answer = writer.unsafeReentrantWrite { db -> T in
            // Decided on the writer's queue, which an open unit holds until it ends: a write that finds a unit open here
            // is inside it, and a write from anywhere else waited for the queue, so it runs after the unit, on its own.
            if unit.withLock({ $0.depth > 0 }) {
                return writeInUnit(db, or: fallback, updates)
            }
            var value = fallback
            do {
                try db.inTransaction {
                    value = try updates(db)
                    return .commit
                }
            } catch {
                failure = error
                return fallback
            }
            return value
        }
        if let failure {
            failures(failure)
        }
        return answer
    }

    /// Hands `error` to ``failures``, for a store whose work outside SQLite failed: a blob's file, for one. It fails no
    /// store unit, even inside one, since the file is no part of the transaction (ADR 2026-10.5sk9).
    func report(_ error: any Error) {
        failures(error)
    }

    /// Runs `value` against a consistent snapshot, or reports the error and answers `fallback`. Inside a store unit it
    /// reads on the unit's own connection instead, so it sees the unit's writes, and an error fails the unit as well.
    func read<T>(or fallback: T, _ value: (Database) throws -> T) -> T {
        if unitRunsOnThisThread {
            return readInUnit(or: fallback, value)
        }
        do {
            return try writer.read(value)
        } catch {
            failures(error)
            return fallback
        }
    }
}
