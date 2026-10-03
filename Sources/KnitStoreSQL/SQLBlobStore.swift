public import Foundation
import GRDB
public import KnitStore
public import KnitWire

/// The ``BlobStore`` on disk: one file per blob, named by its hash, in a directory beside the database, with an index
/// row per blob in `blobs` (ADR 2026-10.nh55, amending ADR 2026-09.nyya).
///
/// The bytes live in files and not in SQLite, which would keep the space a removed blob held: the file never
/// shrinks without a VACUUM, which cannot run inside a migration, so 128 MiB of photos carried once would stay
/// 128 MiB for good. A file also streams out in chunks without loading the whole blob.
///
/// The directory takes the database's protection class and backup exclusion (``StorageDirectory``). A blob's file is
/// written whole before its row, so a crash leaves at worst a file with no row. The sweep when the store opens
/// removes that file, and any row whose file is gone.
public final class SQLBlobStore: BlobStore {
    /// The directory's name beside the database.
    public static let directoryName = "Blobs"
    /// How many hashes one `IN (…)` list binds.
    private static let batchSize = 500

    private let database: KnitDatabase
    private let directory: URL

    /// The blobs indexed in `database`, with their bytes in `directory`, which is made and protected if it is not
    /// there yet. It sweeps away whatever a crash left half done before it answers anything.
    public init(_ database: KnitDatabase, directory: URL) throws {
        try StorageDirectory.prepare(directory)
        self.database = database
        self.directory = directory
        sweep()
    }

    public func contains(_ hash: BlobHash) -> Bool {
        database.read(or: false) { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM blobs WHERE hash = ?)", arguments: [StoredText.bytes(hash.string)])
                == true
        }
    }

    public func held(among hashes: Set<BlobHash>) -> Set<BlobHash> {
        var held: Set<BlobHash> = []
        for batch in Self.batches(of: hashes) {
            held.formUnion(
                database.read(or: []) { db in
                    try Row.fetchAll(
                        db,
                        sql: "SELECT hash FROM blobs WHERE hash IN (\(Self.placeholders(batch.count)))",
                        arguments: Self.arguments(batch)
                    )
                    .map { try $0.blobHash("hash") }
                })
        }
        return held
    }

    public func mime(of hash: BlobHash) -> String? {
        database.read(or: nil) { db in
            try Row.fetchOne(db, sql: "SELECT mime FROM blobs WHERE hash = ?", arguments: [StoredText.bytes(hash.string)])
                .map { try $0.text("mime") }
        }
    }

    public func size(of hash: BlobHash) -> Int? {
        database.read(or: nil) { db in
            try Int.fetchOne(db, sql: "SELECT size FROM blobs WHERE hash = ?", arguments: [StoredText.bytes(hash.string)])
        }
    }

    public func read(_ hash: BlobHash, offset: Int, count: Int) -> [UInt8]? {
        guard offset >= 0, count >= 0, contains(hash) else {
            return nil
        }
        return readFile(hash, offset: offset, count: count)
    }

    public func bytes(of hash: BlobHash) -> [UInt8]? {
        size(of: hash).flatMap { readFile(hash, offset: 0, count: $0) }
    }

    @discardableResult
    public func insert(_ bytes: [UInt8], hash: BlobHash, mime: String, storedAt: Int64) -> Bool {
        guard !contains(hash) else {
            return false
        }
        let url = file(hash)
        do {
            try Data(bytes).write(to: url, options: .atomic)
            try StorageDirectory.protect(url)
        } catch {
            // An atomic write leaves nothing behind at `url` when it fails.
            database.report(error)
            return false
        }
        // A row that does not go in leaves a file nothing names, which the next sweep removes.
        return database.write(or: false) { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO blobs (hash, mime, size, storedAt) VALUES (?, ?, ?, ?)",
                arguments: [StoredText.bytes(hash.string), StoredText.bytes(mime), bytes.count, storedAt]
            )
            return db.changesCount > 0
        }
    }

    public func remove(_ hash: BlobHash) {
        database.write(or: ()) { db in
            try db.execute(sql: "DELETE FROM blobs WHERE hash = ?", arguments: [StoredText.bytes(hash.string)])
        }
        // A file that will not go has no row now, so the next sweep removes it.
        try? FileManager.default.removeItem(at: file(hash))
    }

    public func allHashes() -> [BlobHash] {
        // BLOB order is byte order, which is how the hashes compare.
        database.read(or: []) { db in
            try Row.fetchAll(db, sql: "SELECT hash FROM blobs ORDER BY hash").map { try $0.blobHash("hash") }
        }
    }

    public func totalBytes(among hashes: Set<BlobHash>) -> Int {
        Self.batches(of: hashes).reduce(0) { total, batch in
            total
                + database.read(or: 0) { db in
                    try Int.fetchAll(
                        db,
                        sql: "SELECT size FROM blobs WHERE hash IN (\(Self.placeholders(batch.count)))",
                        arguments: Self.arguments(batch)
                    )
                    .reduce(0, +)
                }
        }
    }

    /// Removes every file with no row, an interrupted write's included, and every row whose file is gone, a damaged
    /// row's included. It reads the index as raw keys, so one damaged row cannot fail the read, and it sweeps nothing
    /// when the directory or the index cannot be read: an empty index would take every file with it.
    private func sweep() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)),
            let indexed = database.read(or: Set<Data>?.none, { db in try Data.fetchSet(db, sql: "SELECT hash FROM blobs") })
        else {
            return
        }
        reconcile(indexed, with: names)
    }

    private func reconcile(_ indexed: Set<Data>, with names: [String]) {
        var present: Set<Data> = []
        for name in names {
            let key = StoredText.bytes(name)
            if BlobHash(name) != nil, indexed.contains(key) {
                present.insert(key)
            } else {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
        let missing = indexed.subtracting(present)
        guard !missing.isEmpty else {
            return
        }
        database.write(or: ()) { db in
            for key in missing {
                try db.execute(sql: "DELETE FROM blobs WHERE hash = ?", arguments: [key])
            }
        }
    }

    /// Up to `count` bytes of `hash`'s file from `offset`, through a file handle, for a whole blob too:
    /// `Data(contentsOf:)` on Linux leaks its 4 KiB buffer when it reads an empty file, and an empty blob is a blob.
    private func readFile(_ hash: BlobHash, offset: Int, count: Int) -> [UInt8]? {
        do {
            let handle = try FileHandle(forReadingFrom: file(hash))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        } catch {
            database.report(error)
            return nil
        }
    }

    private func file(_ hash: BlobHash) -> URL {
        directory.appending(path: hash.string, directoryHint: .notDirectory)
    }

    private static func batches(of hashes: Set<BlobHash>) -> [[BlobHash]] {
        let sorted = hashes.sorted()
        return stride(from: 0, to: sorted.count, by: batchSize).map { Array(sorted[$0..<min($0 + batchSize, sorted.count)]) }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private static func arguments(_ hashes: [BlobHash]) -> StatementArguments {
        StatementArguments(hashes.map { StoredText.bytes($0.string) })
    }
}
