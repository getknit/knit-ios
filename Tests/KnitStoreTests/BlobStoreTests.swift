import Foundation
import KnitStore
import KnitStoreSQL
import KnitTestSupport
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

/// Every ``BlobStore`` with the store unit it commits in (ADR 2026-10.5sk9): the memory store, and the SQL store on each
/// writer the database runs on, the file's pool as the app opens it and the queue in memory.
enum BlobUnitKind: CaseIterable, Sendable, CustomTestStringConvertible {
    case memory
    case pool
    case queue

    /// A blob store, the unit over it, and a store write that fails that unit as a full disk fails one.
    struct Rig {
        var blobs: any BlobStore
        var transactor: any StoreTransactor
        var failingWrite: () -> Void
    }

    var testDescription: String {
        switch self {
        case .memory:
            "memory"
        case .pool:
            "pool"
        case .queue:
            "queue"
        }
    }

    /// Runs `body` on a fresh rig whose database, where there is one, hands its errors to `failures`, then removes
    /// whatever the store left on disk.
    func withRig(failures: @escaping @Sendable (any Error) -> Void, _ body: (Rig) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "knit-blob-unit-\(ProcessInfo.processInfo.globallyUniqueString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database: KnitDatabase
        switch self {
        case .memory:
            let blobs = MemoryBlobStore()
            let unit = MemoryTransactor(stores: [blobs])
            // Memory never fails by itself, so the write that fails the unit is a failing store double's.
            try body(Rig(blobs: blobs, transactor: unit, failingWrite: unit.failCurrentUnit))
            return
        case .pool:
            database = try KnitDatabase.open(in: directory, failures: failures)
        case .queue:
            database = try KnitDatabase.inMemory(failures: failures)
        }
        let groups = SQLGroupStore(database)
        let blobs = try SQLBlobStore(database, directory: directory.appending(path: SQLBlobStore.directoryName))
        try body(Rig(blobs: blobs, transactor: database) { groups.save(Self.twice) })
    }

    /// A roster naming a member twice, which `group_members`' primary key refuses.
    private static var twice: GroupRecord {
        let member = GroupMember(nodeId: fixtureNodeId(1).string)
        return GroupRecord(id: "g-0123456789abcdef01234567", createdBy: member.nodeId, createdAt: 1, roster: [member, member])
    }
}

/// How a unit that removes a blob comes undone: its body abandons it, a store write after the removal fails it, or the
/// removal runs in a unit a store write has already failed.
enum BlobRemovalUndone: CaseIterable, Sendable, CustomTestStringConvertible {
    case abandoned
    case failedAfter
    case failedBefore

    var testDescription: String {
        switch self {
        case .abandoned:
            "abandoned"
        case .failedAfter:
            "failed after the removal"
        case .failedBefore:
            "failed before the removal"
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

    @Test(arguments: BlobUnitKind.allCases, BlobRemovalUndone.allCases)
    func aRemovalInAUnitThatComesUndoneLeavesTheBlobWhole(kind: BlobUnitKind, undone: BlobRemovalUndone) throws {
        // A row back without its file would read as held: the photo never fetched again, and every holder query
        // answered HAVE for bytes nobody can serve.
        let failures = FailureCount()
        try kind.withRig(failures: failures.record) { rig in
            rig.blobs.insert([1, 2, 3], hash: second, mime: "image/jpeg", storedAt: 1)
            let outcome = rig.transactor.atomically { () -> Int? in
                switch undone {
                case .abandoned:
                    rig.blobs.remove(second)
                    return nil
                case .failedAfter:
                    rig.blobs.remove(second)
                    rig.failingWrite()
                case .failedBefore:
                    rig.failingWrite()
                    rig.blobs.remove(second)
                }
                return 1
            }
            #expect(outcome == (undone == .abandoned ? .abandoned : .failed))
            #expect(rig.blobs.contains(second) == (rig.blobs.bytes(of: second) != nil))
            #expect(rig.blobs.bytes(of: second) == [1, 2, 3])
            #expect(failures.value == (undone == .abandoned || kind == .memory ? 0 : 1), "the failing write alone is reported")
        }
    }

    @Test(arguments: BlobUnitKind.allCases)
    func aRemovalInANestedUnitThatAbandonsLeavesTheBlobWholeWhenTheOuterCommits(kind: BlobUnitKind) throws {
        let failures = FailureCount()
        try kind.withRig(failures: failures.record) { rig in
            rig.blobs.insert([1, 2, 3], hash: second, mime: "image/jpeg", storedAt: 1)
            var inner: Transacted<Int>?
            let outcome = rig.transactor.atomically { () -> Int? in
                inner = rig.transactor.atomically { () -> Int? in
                    rig.blobs.remove(second)
                    return nil
                }
                return 1
            }
            #expect(inner == .abandoned)
            #expect(outcome == .committed(1))
            #expect(rig.blobs.contains(second) == (rig.blobs.bytes(of: second) != nil))
            #expect(rig.blobs.bytes(of: second) == [1, 2, 3], "the commit found the row back, and left its file")
            #expect(failures.value == 0)
        }
    }

    @Test(arguments: BlobUnitKind.allCases)
    func aRemovalInAUnitThatCommitsForgetsTheBlob(kind: BlobUnitKind) throws {
        let failures = FailureCount()
        try kind.withRig(failures: failures.record) { rig in
            rig.blobs.insert([1, 2, 3], hash: second, mime: "image/jpeg", storedAt: 1)
            rig.blobs.insert([4], hash: third, mime: "image/png", storedAt: 1)
            let outcome = rig.transactor.atomically { () -> Int? in
                rig.blobs.remove(second)
                #expect(!rig.blobs.contains(second), "the unit reads its own removal")
                return 1
            }
            #expect(outcome == .committed(1))
            #expect(!rig.blobs.contains(second))
            #expect(rig.blobs.bytes(of: second) == nil)
            #expect(rig.blobs.allHashes() == [third])
            #expect(rig.blobs.bytes(of: third) == [4])
            #expect(failures.value == 0)
        }
    }
}
