import Foundation
import KnitStore
import KnitStoreSQL
import KnitWire
import Testing

/// Every ``BlobStore``: the memory store, and the SQL store with its bytes in files. Each runs the whole
/// ``BlobStoreTests`` suite against a directory of its own.
enum BlobStoreKind: CaseIterable, Sendable, CustomTestStringConvertible {
    case memory
    case sql

    var testDescription: String {
        switch self {
        case .memory:
            "memory"
        case .sql:
            "sql"
        }
    }

    /// Runs `body` on a fresh store, then removes whatever the store left on disk.
    func withStore(_ body: (any BlobStore) throws -> Void) throws {
        switch self {
        case .memory:
            try body(MemoryBlobStore())
        case .sql:
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "knit-blobs-\(ProcessInfo.processInfo.globallyUniqueString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = try KnitDatabase.inMemory(failures: recordFailure)
            try body(try SQLBlobStore(database, directory: directory))
        }
    }
}

/// The blob store's contract (`BlobDao`, `MeshBlobStore` in knit-next): blobs keyed by hash, kept once, read whole or
/// in ranges, and weighed for a budget.
@Suite struct BlobStoreTests {
    private static let kinds = BlobStoreKind.allCases

    private let first = BlobHash.empty
    private let second = BlobHash(String(repeating: "1", count: 64)) ?? .empty
    private let third = BlobHash(String(repeating: "f", count: 64)) ?? .empty

    @Test(arguments: kinds)
    func aBlobIsKeptAndReadBack(kind: BlobStoreKind) throws {
        try kind.withStore { store in
            #expect(!store.contains(second))
            #expect(store.bytes(of: second) == nil)
            #expect(store.insert([1, 2, 3, 4, 5], hash: second, mime: "image/jpeg", storedAt: 7))
            #expect(store.contains(second))
            #expect(store.mime(of: second) == "image/jpeg")
            #expect(store.size(of: second) == 5)
            #expect(store.bytes(of: second) == [1, 2, 3, 4, 5])
            #expect(store.allHashes() == [second])
        }
    }

    @Test(arguments: kinds)
    func aBlobReadsInRanges(kind: BlobStoreKind) throws {
        try kind.withStore { store in
            store.insert(Array(0..<10), hash: second, mime: "image/png", storedAt: 1)
            #expect(store.read(second, offset: 0, count: 4) == [0, 1, 2, 3])
            #expect(store.read(second, offset: 8, count: 4) == [8, 9], "fewer at the end")
            #expect(store.read(second, offset: 10, count: 4)?.isEmpty == true, "nothing past the end")
            #expect(store.read(second, offset: 3, count: .max) == Array(3..<10))
            #expect(store.read(second, offset: -1, count: 1) == nil)
            #expect(store.read(second, offset: 0, count: -1) == nil)
            #expect(store.read(first, offset: 0, count: 1) == nil, "not held")
        }
    }

    @Test(arguments: kinds)
    func aBlobAlreadyHeldIsLeftAsItIs(kind: BlobStoreKind) throws {
        try kind.withStore { store in
            #expect(store.insert([1], hash: second, mime: "image/jpeg", storedAt: 1))
            #expect(!store.insert([1], hash: second, mime: "image/png", storedAt: 2))
            #expect(store.mime(of: second) == "image/jpeg")
        }
    }

    @Test(arguments: kinds)
    func anEmptyBlobIsABlob(kind: BlobStoreKind) throws {
        try kind.withStore { store in
            #expect(store.insert([], hash: first, mime: "image/gif", storedAt: 1))
            #expect(store.contains(first))
            #expect(store.bytes(of: first)?.isEmpty == true)
            #expect(store.size(of: first) == 0)
        }
    }

    @Test(arguments: kinds)
    func aBlobIsRemovedAndRemovingNothingIsHarmless(kind: BlobStoreKind) throws {
        try kind.withStore { store in
            store.insert([1, 2], hash: second, mime: "image/jpeg", storedAt: 1)
            store.remove(second)
            store.remove(second)
            store.remove(first)
            #expect(!store.contains(second))
            #expect(store.bytes(of: second) == nil)
            #expect(store.allHashes().isEmpty)
        }
    }

    @Test(arguments: kinds)
    func manyHashesAreCheckedAndWeighedAtOnce(kind: BlobStoreKind) throws {
        try kind.withStore { store in
            store.insert([1, 2, 3], hash: third, mime: "image/jpeg", storedAt: 1)
            store.insert([4], hash: second, mime: "image/jpeg", storedAt: 2)
            #expect(store.held(among: [first, second, third]) == [second, third])
            #expect(store.held(among: []).isEmpty)
            #expect(store.totalBytes(among: [first, second, third]) == 4)
            #expect(store.totalBytes(among: [third]) == 3)
            #expect(store.totalBytes(among: []) == 0)
            #expect(store.allHashes() == [second, third], "in byte order")
        }
    }
}
