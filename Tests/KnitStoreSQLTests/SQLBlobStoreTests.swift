import Foundation
import GRDB
import KnitStore
import KnitWire
import Testing

@testable import KnitStoreSQL

/// What the SQL blob store adds to the contract in `BlobStoreTests`: its bytes are files beside the database, named
/// by hash, and kept across a reopen, and the sweep at open clears what a crash left (ADR 2026-10.nh55).
@Suite struct SQLBlobStoreTests {
    private let first = BlobHash.empty
    private let second = BlobHash(String(repeating: "2", count: 64)) ?? .empty
    private let third = BlobHash(String(repeating: "3", count: 64)) ?? .empty

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "knit-blobstore-\(ProcessInfo.processInfo.globallyUniqueString)")
    }

    private func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
    }

    @Test func eachBlobIsOneFileNamedByItsHash() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = directory.appending(path: SQLBlobStore.directoryName)
        let store = try SQLBlobStore(try KnitDatabase.open(in: directory, failures: recordFailure), directory: blobs)
        store.insert([9, 8, 7], hash: first, mime: "image/jpeg", storedAt: 1)
        #expect(try names(in: blobs) == [first.string])
        #expect(FileManager.default.contents(atPath: blobs.appending(path: first.string).path(percentEncoded: false)) == Data([9, 8, 7]))
        store.remove(first)
        #expect(try names(in: blobs).isEmpty)
    }

    @Test func blobsSurviveAReopen() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = directory.appending(path: SQLBlobStore.directoryName)
        do {
            let store = try SQLBlobStore(try KnitDatabase.open(in: directory, failures: recordFailure), directory: blobs)
            store.insert([1, 2], hash: first, mime: "image/png", storedAt: 5)
        }
        let reopened = try SQLBlobStore(try KnitDatabase.open(in: directory, failures: recordFailure), directory: blobs)
        #expect(reopened.bytes(of: first) == [1, 2])
        #expect(reopened.mime(of: first) == "image/png")
    }

    @Test func theSweepAtOpenClearsWhatACrashLeft() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = directory.appending(path: SQLBlobStore.directoryName)
        do {
            let store = try SQLBlobStore(try KnitDatabase.open(in: directory, failures: recordFailure), directory: blobs)
            store.insert([1], hash: first, mime: "image/jpeg", storedAt: 1)
            store.insert([2], hash: second, mime: "image/jpeg", storedAt: 1)
        }
        // A row whose file is gone, a file no row names, and an interrupted write's leftovers.
        try FileManager.default.removeItem(at: blobs.appending(path: second.string))
        try Data([3]).write(to: blobs.appending(path: third.string))
        try Data([4]).write(to: blobs.appending(path: "\(first.string).partial"))
        let reopened = try SQLBlobStore(try KnitDatabase.open(in: directory, failures: recordFailure), directory: blobs)
        #expect(reopened.allHashes() == [first])
        #expect(!reopened.contains(second) && !reopened.contains(third))
        #expect(try names(in: blobs) == [first.string])
    }

    @Test func aBlobWhoseFileVanishedReadsAsNothingAndIsReported() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = directory.appending(path: SQLBlobStore.directoryName)
        let failures = Failures()
        let store = try SQLBlobStore(try KnitDatabase.open(in: directory, failures: failures.record), directory: blobs)
        store.insert([1, 2], hash: first, mime: "image/jpeg", storedAt: 1)
        try FileManager.default.removeItem(at: blobs.appending(path: first.string))
        #expect(store.bytes(of: first) == nil)
        #expect(store.read(first, offset: 0, count: 1) == nil)
        #expect(failures.count == 2)
    }

    @Test func aBlobThatCannotBeWrittenIsReportedAndNotKept() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = directory.appending(path: SQLBlobStore.directoryName)
        let failures = Failures()
        let store = try SQLBlobStore(try KnitDatabase.open(in: directory, failures: failures.record), directory: blobs)
        // A directory where the file should go: the atomic write cannot replace it, for root as for anyone.
        try FileManager.default.createDirectory(at: blobs.appending(path: first.string), withIntermediateDirectories: true)
        #expect(!store.insert([1, 2], hash: first, mime: "image/jpeg", storedAt: 1))
        #expect(!store.contains(first))
        #expect(failures.count == 1)
    }

    @Test func anIndexThatCannotBeReadSweepsNothing() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = directory.appending(path: SQLBlobStore.directoryName)
        let failures = Failures()
        let database = try KnitDatabase.open(in: directory, failures: failures.record)
        try SQLBlobStore(database, directory: blobs).insert([1, 2], hash: first, mime: "image/jpeg", storedAt: 1)
        try database.writer.write { db in try db.execute(sql: "DROP TABLE blobs") }
        _ = try SQLBlobStore(database, directory: blobs)
        #expect(try names(in: blobs) == [first.string])
        #expect(failures.count == 1)
    }

    /// Only a damaged file holds such a row. Reading every hash fails whole and says so, and the sweep at the next open
    /// clears the row and keeps every blob beside it.
    @Test func aDamagedRowIsReportedThenSweptWithoutTakingTheBlobsBesideIt() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = directory.appending(path: SQLBlobStore.directoryName)
        let failures = Failures()
        let database = try KnitDatabase.open(in: directory, failures: failures.record)
        let store = try SQLBlobStore(database, directory: blobs)
        store.insert([1, 2], hash: first, mime: "image/jpeg", storedAt: 1)
        try database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO blobs (hash, mime, size, storedAt) VALUES (?, ?, 1, 1)",
                arguments: [StoredText.bytes("not a hash"), StoredText.bytes("image/jpeg")]
            )
        }
        #expect(store.allHashes().isEmpty)
        #expect(failures.count == 1)
        let reopened = try SQLBlobStore(database, directory: blobs)
        #expect(reopened.allHashes() == [first])
        #expect(reopened.bytes(of: first) == [1, 2])
        #expect(failures.count == 1)
    }
}
