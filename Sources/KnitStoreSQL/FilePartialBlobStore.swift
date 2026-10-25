public import Foundation
public import KnitStore
import KnitSync
public import KnitWire

/// The ``PartialBlobStore`` on disk: one file per kept prefix, `<hash>.part`, in a directory beside the database's
/// (`PartialBlobs.kt` in knit-next, knit-ios #2). The rules are ``PartialBlobBook``'s, in memory, so ``length(_:)`` and
/// ``drop(_:)``'s answer never read the disk.
///
/// The prefixes are on disk, not in memory, because a photo cut at the edge of range is cut again and again: up to 32 MiB
/// held across a session would be memory a suspended app is killed for. They live no longer than the session (the mesh
/// purges them at every start and stop), and the directory takes the database's protection class and backup exclusion
/// (``StorageDirectory``), since a room photo or a peer's avatar crosses the link as plaintext.
///
/// A kept prefix is never written in place. A copy is written whole to a staging file in the same directory, then renamed
/// over the prefix it replaces, so a crash leaves at worst a staging file, which the next purge deletes. A read that does
/// not come back with exactly the bytes asked for retires the prefix and its epoch, where Kotlin retires only a file that
/// will not open: a prefix that read short once reads short at every resume. A file is no part of the database, so its error
/// is reported to the closure the app hands ``KnitDatabase`` and decides nothing more: a failed keep keeps nothing, and a
/// failed read resumes nothing, so the next ask is for the whole blob, as before this store.
///
/// Every call takes one lock, and a keep or an open moves up to 8 MiB under it. The link manager and the engine call it
/// from the one mesh actor, so nothing waits on it there.
public final class FilePartialBlobStore: PartialBlobStore {
    /// The directory's name beside the database.
    public static let directoryName = "Partials"
    private static let suffix = ".part"
    private static let stagingSuffix = ".staging"

    private let database: KnitDatabase
    private let directory: URL
    private let book: Lock<PartialBlobBook>
    private let log: (@Sendable (String) -> Void)?

    /// The prefixes in `directory`, which is made and protected if it is not there yet, reporting file errors through
    /// `database`, within `limits`, and handing its lines to `log`. Nothing on disk is read: the next purge deletes it.
    @preconcurrency
    public init(
        _ database: KnitDatabase, directory: URL, limits: PartialBlobBook.Limits = PartialBlobBook.Limits(),
        log: (@Sendable (String) -> Void)? = nil
    ) throws {
        try StorageDirectory.prepare(directory)
        self.database = database
        self.directory = directory
        book = Lock(PartialBlobBook(limits: limits))
        self.log = log
    }

    public func length(_ hash: BlobHash) -> Int {
        book.withLock { $0.length(hash) }
    }

    public func open(_ hash: BlobHash, offset: Int) -> KeptPrefix? {
        let (prefix, lines) = book.withLock { book in
            let prefix = book.open(hash, offset: offset) { readFile(hash, count: $0) }
            return (prefix, settle(&book))
        }
        emit(lines)
        return prefix
    }

    @discardableResult
    public func keep(_ hash: BlobHash, bytes: [UInt8], basedOn: Int?, now: Int64) -> Bool {
        let (kept, lines) = book.withLock { book in
            let kept = book.keep(hash, length: bytes.count, basedOn: basedOn, now: now) { install(bytes, as: hash) }
            return (kept, settle(&book))
        }
        emit(lines)
        return kept
    }

    @discardableResult
    public func drop(_ hash: BlobHash) -> Bool {
        let (removed, lines) = book.withLock { book in
            (book.drop(hash), settle(&book))
        }
        emit(lines)
        return removed
    }

    @discardableResult
    public func sweep(now: Int64, isHeld: (BlobHash) -> Bool) -> Int {
        let (expired, kept) = book.withLock { book in
            let expired = book.expire(now: now)
            _ = settle(&book)
            return (expired, book.hashes)
        }
        let held = kept.filter(isHeld)
        book.withLock { book in
            for hash in held {
                _ = book.retire(hash)
            }
            _ = settle(&book)
        }
        return expired + held.count
    }

    public func purge() {
        book.withLock { book in
            book.purge()
            do {
                for name in try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: directory.appending(path: name))
                }
            } catch {
                database.report(error)
            }
        }
    }

    /// Deletes the prefixes the book let go, and answers its lines. A file that will not go is the next purge's.
    private func settle(_ book: inout PartialBlobBook) -> [String] {
        let owed = book.takeOwed()
        for hash in owed.discarded {
            try? FileManager.default.removeItem(at: file(hash))
        }
        return owed.lines
    }

    private func emit(_ lines: [String]) {
        guard let log else {
            return
        }
        lines.forEach(log)
    }

    /// Writes `bytes` to a staging file, then renames it over `hash`'s prefix. Answers whether the prefix is the copy now;
    /// when it is not, the staging file is gone and the prefix kept before, if any, is as it was.
    private func install(_ bytes: [UInt8], as hash: BlobHash) -> Bool {
        let staging = directory.appending(path: hash.string + Self.stagingSuffix, directoryHint: .notDirectory)
        let destination = file(hash)
        do {
            try Data(bytes).write(to: staging)
            try StorageDirectory.protect(staging)
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: staging)
            database.report(error)
            return false
        }
    }

    /// The first `count` bytes of `hash`'s prefix, through a file handle as ``SQLBlobStore`` reads, or `nil` on an error.
    private func readFile(_ hash: BlobHash, count: Int) -> [UInt8]? {
        do {
            let handle = try FileHandle(forReadingFrom: file(hash))
            defer { try? handle.close() }
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        } catch {
            database.report(error)
            return nil
        }
    }

    private func file(_ hash: BlobHash) -> URL {
        directory.appending(path: hash.string + Self.suffix, directoryHint: .notDirectory)
    }
}
