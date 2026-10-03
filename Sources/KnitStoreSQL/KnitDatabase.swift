public import Foundation
import GRDB

/// The app's database: one SQLite file, migrated to this build's schema, behind every SQL store
/// (ADR 2026-09.nyya).
///
/// The store protocols are synchronous and cannot throw, because the mesh engine calls them from its actor
/// (ADR 2026-09.gq84). So a store that hits a database error answers as if nothing were there, and reports the
/// error through ``failures``: the mesh keeps running on what it holds in memory, and the app can say that
/// storage is failing. A disk that is full, or a file Data Protection has locked, is the realistic cause.
public final class KnitDatabase: Sendable {
    /// The database file's name inside its directory.
    public static let fileName = "knit.sqlite"

    /// How many migrations this build knows: the schema version it writes.
    public static var schemaVersion: Int { Schema.migrations.count }

    let writer: any DatabaseWriter
    private let failures: @Sendable (any Error) -> Void

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
    /// `failures` hears about every error a store meets after the open.
    @preconcurrency
    public static func open(in directory: URL, failures: @escaping @Sendable (any Error) -> Void) throws -> KnitDatabase {
        try StorageDirectory.prepare(directory)
        let file = directory.appending(path: fileName)
        let pool = try DatabasePool(path: file.path(percentEncoded: false), configuration: configuration)
        try StorageDirectory.protect(file)
        return try KnitDatabase(writer: pool, failures: failures)
    }

    /// A private database in memory, gone with the value: for tests and previews.
    @preconcurrency
    public static func inMemory(failures: @escaping @Sendable (any Error) -> Void) throws -> KnitDatabase {
        try KnitDatabase(writer: DatabaseQueue(configuration: configuration), failures: failures)
    }

    private static var configuration: Configuration {
        var settings = Configuration()
        settings.label = "knit"
        return settings
    }

    /// Runs `updates` in one write transaction. On an error the transaction rolls back, the error goes to
    /// ``failures``, and the answer is `fallback`.
    func write<T>(or fallback: T, _ updates: (Database) throws -> T) -> T {
        do {
            return try writer.write(updates)
        } catch {
            failures(error)
            return fallback
        }
    }

    /// Hands `error` to ``failures``, for a store whose work outside SQLite failed: a blob's file, for one.
    func report(_ error: any Error) {
        failures(error)
    }

    /// Runs `value` against a consistent snapshot, or reports the error and answers `fallback`.
    func read<T>(or fallback: T, _ value: (Database) throws -> T) -> T {
        do {
            return try writer.read(value)
        } catch {
            failures(error)
            return fallback
        }
    }
}
