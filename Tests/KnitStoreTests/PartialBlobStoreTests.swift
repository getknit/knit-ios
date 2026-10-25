import Foundation
import KnitStore
import KnitStoreSQL
import KnitSync
import KnitWire
import Testing

/// Every ``PartialBlobStore``: the memory store, and the file store with each prefix a file. Each runs the whole
/// ``PartialBlobStoreTests`` suite in a directory of its own.
enum PartialBlobStoreKind: CaseIterable, Sendable, CustomTestStringConvertible {
    case memory
    case file

    /// A store, the lines it logged, the errors it reported, and its directory on disk, `nil` in memory.
    struct Rig {
        var store: any PartialBlobStore
        var lines: Lock<[String]>
        var errors: Lock<[String]>
        var directory: URL?

        /// The names on disk, sorted; none in memory.
        var names: [String] {
            directory.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path(percentEncoded: false)) }?.sorted() ?? []
        }
    }

    var testDescription: String {
        switch self {
        case .memory:
            "memory"
        case .file:
            "file"
        }
    }

    /// Runs `body` on a fresh store within `limits`, then removes whatever it left on disk.
    func withStore(_ limits: PartialBlobBook.Limits = PartialBlobBook.Limits(minBytes: 1), _ body: (Rig) throws -> Void) throws {
        let lines = Lock<[String]>([])
        let errors = Lock<[String]>([])
        let log: @Sendable (String) -> Void = { line in lines.withLock { $0.append(line) } }
        switch self {
        case .memory:
            try body(Rig(store: MemoryPartialBlobStore(limits: limits, log: log), lines: lines, errors: errors))
        case .file:
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "knit-partials-\(ProcessInfo.processInfo.globallyUniqueString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let database = try KnitDatabase.inMemory { error in errors.withLock { $0.append("\(error)") } }
            let store = try FilePartialBlobStore(database, directory: directory, limits: limits, log: log)
            try body(Rig(store: store, lines: lines, errors: errors, directory: directory))
        }
    }
}

/// The kept prefixes of cut attachments (knit-ios #2): twins of knit-next's `PartialBlobsTest`, against both stores, which
/// apply one ``PartialBlobBook``.
@Suite struct PartialBlobStoreTests {
    private let keyA = BlobHash(computedDigest: [UInt8](repeating: 0xAA, count: 32))
    private let keyB = BlobHash(computedDigest: [UInt8](repeating: 0xBB, count: 32))
    private let keyC = BlobHash(computedDigest: [UInt8](repeating: 0xCC, count: 32))

    private func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8($0 % 251) }
    }

    @Test(arguments: PartialBlobStoreKind.allCases)
    func theLongestPrefixIsKeptAndAShorterOneIsNot(_ kind: PartialBlobStoreKind) throws {
        try kind.withStore { rig in
            #expect(rig.store.keep(keyA, bytes: bytes(100), basedOn: nil, now: 0))
            #expect(rig.store.length(keyA) == 100)
            #expect(!rig.store.keep(keyA, bytes: bytes(50), basedOn: nil, now: 0), "a shorter cut never replaces a longer prefix")
            #expect(!rig.store.keep(keyA, bytes: bytes(100), basedOn: nil, now: 0), "nor one as long")
            #expect(rig.store.length(keyA) == 100)
            #expect(rig.store.keep(keyA, bytes: bytes(200), basedOn: nil, now: 0))
            #expect(rig.store.length(keyA) == 200)
            #expect(rig.store.open(keyA, offset: 200)?.bytes == bytes(200))
            #expect(rig.lines.withLock { $0 } == ["partial aaaaaaaaaaaa kept 100B", "partial aaaaaaaaaaaa kept 200B"])
            if kind == .file {
                #expect(rig.names == ["\(keyA).part"], "replaced by rename, no staging file left")
            }
        }
    }

    @Test(arguments: PartialBlobStoreKind.allCases)
    func aPrefixBelowTheMinimumIsNotWorthAFile(_ kind: PartialBlobStoreKind) throws {
        try kind.withStore(PartialBlobBook.Limits(minBytes: 64)) { rig in
            #expect(!rig.store.keep(keyA, bytes: bytes(63), basedOn: nil, now: 0))
            #expect(rig.store.length(keyA) == 0)
            #expect(rig.names.isEmpty)
            #expect(rig.store.keep(keyA, bytes: bytes(64), basedOn: nil, now: 0))
        }
        #expect(
            PartialBlobBook.Limits()
                == PartialBlobBook.Limits(minBytes: 16_384, maxCount: 8, maxBytes: 33_554_432, ttlMilliseconds: 3_600_000))
        #expect(PartialBlobBook.maxEpochs == 64)
    }

    @Test(arguments: PartialBlobStoreKind.allCases)
    func anOpenPrefixReadsTheKeptBytesFromTheStart(_ kind: PartialBlobStoreKind) throws {
        try kind.withStore { rig in
            rig.store.keep(keyA, bytes: bytes(1000), basedOn: nil, now: 0)
            #expect(rig.store.open(keyA, offset: 600)?.bytes == Array(bytes(1000).prefix(600)))
            #expect(
                rig.store.open(keyA, offset: 1000)?.bytes == bytes(1000),
                "the whole prefix is an offset too: a complete file gets an empty tail")
            #expect(rig.store.open(keyA, offset: 1001) == nil, "more than is kept")
            #expect(rig.store.open(keyA, offset: 0) == nil, "an offset below one is no resume")
            #expect(rig.store.open(keyA, offset: -1) == nil)
            #expect(rig.store.open(keyB, offset: 1) == nil, "nothing kept")
            #expect(rig.store.length(keyA) == 1000, "a refused open retires nothing")
        }
    }

    @Test(arguments: PartialBlobStoreKind.allCases)
    func aPrefixDroppedWhileACopyWasBuiltOnItIsNeverKeptAgain(_ kind: PartialBlobStoreKind) throws {
        // Two links resumed from one prefix; one spliced file failed its hash and dropped it. The other, cut later, must
        // not bring the bad prefix back, but a stream from byte 0 owes it nothing.
        try kind.withStore { rig in
            rig.store.keep(keyA, bytes: bytes(100), basedOn: nil, now: 0)
            let epoch = try #require(rig.store.open(keyA, offset: 100)).epoch
            #expect(rig.store.drop(keyA))
            #expect(!rig.store.keep(keyA, bytes: bytes(300), basedOn: epoch, now: 0))
            #expect(rig.store.length(keyA) == 0)
            #expect(rig.names.isEmpty)
            #expect(rig.store.keep(keyA, bytes: bytes(150), basedOn: nil, now: 0), "a whole-file stream is eligible")
            #expect(rig.lines.withLock { $0 }.contains("partial aaaaaaaaaaaa dropped"))
            #expect(rig.lines.withLock { $0 }.contains("partial aaaaaaaaaaaa stale, not kept"))
        }
    }

    @Test(arguments: PartialBlobStoreKind.allCases)
    func aCopyOnTheCurrentPrefixIsKeptWhenItGotFurther(_ kind: PartialBlobStoreKind) throws {
        try kind.withStore { rig in
            rig.store.keep(keyA, bytes: bytes(100), basedOn: nil, now: 0)
            let epoch = try #require(rig.store.open(keyA, offset: 100)).epoch
            #expect(rig.store.keep(keyA, bytes: bytes(400), basedOn: epoch, now: 0))
            #expect(rig.store.length(keyA) == 400)
        }
        // An eviction is no verdict on the bytes: a copy built before it may still be kept.
        try kind.withStore(PartialBlobBook.Limits(minBytes: 1, maxCount: 1)) { rig in
            rig.store.keep(keyA, bytes: bytes(100), basedOn: nil, now: 0)
            let held = try #require(rig.store.open(keyA, offset: 100)).epoch
            rig.store.keep(keyB, bytes: bytes(100), basedOn: nil, now: 0)
            #expect(rig.store.length(keyA) == 0, "a was evicted for b")
            #expect(rig.lines.withLock { $0 }.contains("partial aaaaaaaaaaaa evicted"))
            #expect(rig.store.keep(keyA, bytes: bytes(300), basedOn: held, now: 0))
        }
    }

    @Test(arguments: PartialBlobStoreKind.allCases)
    func aKeptPrefixIsNeverWrittenToSoAnOpenedOneKeepsItsBytes(_ kind: PartialBlobStoreKind) throws {
        try kind.withStore { rig in
            rig.store.keep(keyA, bytes: bytes(100), basedOn: nil, now: 0)
            let opened = try #require(rig.store.open(keyA, offset: 100))
            rig.store.keep(keyA, bytes: [UInt8](repeating: 7, count: 500), basedOn: nil, now: 0)
            #expect(opened.bytes == bytes(100), "the reader has the bytes it opened")
            #expect(rig.store.open(keyA, offset: 500)?.bytes == [UInt8](repeating: 7, count: 500))
            #expect(rig.store.open(keyA, offset: 500)?.epoch == opened.epoch, "a longer copy is the same lineage")
        }
    }

    @Test(arguments: PartialBlobStoreKind.allCases)
    func onlyAContentHashNamesAPrefix(_ kind: PartialBlobStoreKind) throws {
        // Kotlin checks the key at `keep`; here no key reaches a store but a well-formed hash, and the file is named by it.
        #expect(BlobHash("../../escape") == nil)
        #expect(BlobHash(String(repeating: "A", count: 64)) == nil)
        try kind.withStore { rig in
            rig.store.keep(keyA, bytes: bytes(10), basedOn: nil, now: 0)
            #expect(rig.names == (kind == .file ? ["\(keyA).part"] : []))
        }
    }

    @Test(arguments: PartialBlobStoreKind.allCases)
    func theOldestGoesFirstPastTheCountAndTheBytes(_ kind: PartialBlobStoreKind) throws {
        try kind.withStore(PartialBlobBook.Limits(minBytes: 1, maxCount: 2)) { rig in
            for hash in [keyA, keyB, keyC] {
                rig.store.keep(hash, bytes: bytes(10), basedOn: nil, now: 0)
            }
            #expect([keyA, keyB, keyC].map { rig.store.length($0) } == [0, 10, 10])
        }
        try kind.withStore(PartialBlobBook.Limits(minBytes: 1, maxBytes: 250)) { rig in
            for hash in [keyA, keyB, keyC] {
                rig.store.keep(hash, bytes: bytes(100), basedOn: nil, now: 0)
            }
            #expect([keyA, keyB, keyC].map { rig.store.length($0) } == [0, 100, 100])
            #expect(rig.names == (kind == .file ? ["\(keyB).part", "\(keyC).part"] : []), "the evicted file went with it")
        }
        try kind.withStore(PartialBlobBook.Limits(minBytes: 1, maxCount: 2)) { rig in
            rig.store.keep(keyA, bytes: bytes(10), basedOn: nil, now: 0)
            rig.store.keep(keyB, bytes: bytes(10), basedOn: nil, now: 0)
            rig.store.keep(keyA, bytes: bytes(20), basedOn: nil, now: 0)
            rig.store.keep(keyC, bytes: bytes(10), basedOn: nil, now: 0)
            #expect([keyA, keyB, keyC].map { rig.store.length($0) } == [20, 0, 10], "a longer copy is kept anew, so b is now the oldest")
        }
    }

    @Test(arguments: PartialBlobStoreKind.allCases)
    func aSweepDropsWhatAgedPastTheHourAndWhatArrivedSomeOtherWay(_ kind: PartialBlobStoreKind) throws {
        try kind.withStore { rig in
            let hour = PartialBlobBook.Limits().ttlMilliseconds
            var now: Int64 = 1000
            rig.store.keep(keyA, bytes: bytes(10), basedOn: nil, now: now)
            now += hour / 2
            rig.store.keep(keyB, bytes: bytes(10), basedOn: nil, now: now)
            rig.store.keep(keyC, bytes: bytes(10), basedOn: nil, now: now)
            now += hour / 2
            let none = rig.store.sweep(now: now) { _ in false }
            #expect(none == 0, "an hour to the millisecond is not past it")
            now += 1
            let held = keyC
            let swept = rig.store.sweep(now: now) { $0 == held }
            #expect(swept == 2)
            #expect(rig.store.length(keyA) == 0, "past its hour")
            #expect(rig.store.length(keyB) == 10, "still young, still wanted")
            #expect(rig.store.length(keyC) == 0, "held now: nothing to resume")
            #expect(rig.names == (kind == .file ? ["\(keyB).part"] : []))
        }
    }

    @Test(arguments: PartialBlobStoreKind.allCases)
    func aPurgeDeletesEveryPrefixAndADeadSessionsLeftovers(_ kind: PartialBlobStoreKind) throws {
        try kind.withStore { rig in
            rig.store.keep(keyA, bytes: bytes(100), basedOn: nil, now: 0)
            let epoch = try #require(rig.store.open(keyA, offset: 100)).epoch
            if let directory = rig.directory {
                // A crashed process's prefix, and a keep it never finished.
                try Data(bytes(10)).write(to: directory.appending(path: "\(keyB).part"))
                try Data(bytes(10)).write(to: directory.appending(path: "\(keyC).staging"))
            }
            rig.store.purge()
            #expect(rig.names.isEmpty)
            #expect(rig.store.length(keyA) == 0)
            #expect(!rig.store.keep(keyA, bytes: bytes(200), basedOn: epoch, now: 0), "a resume begun before the purge keeps nothing")
            #expect(rig.store.keep(keyA, bytes: bytes(200), basedOn: nil, now: 0))
            #expect(rig.store.open(keyA, offset: 200)?.epoch != epoch, "an epoch is never minted twice")
        }
    }

    @Test(arguments: PartialBlobStoreKind.allCases)
    func aDropSaysWhetherAPrefixWentAndAMissingOrShortFileIsForgotten(_ kind: PartialBlobStoreKind) throws {
        try kind.withStore { rig in
            #expect(!rig.store.drop(keyA))
            rig.store.keep(keyA, bytes: bytes(100), basedOn: nil, now: 0)
            let epoch = try #require(rig.store.open(keyA, offset: 100)).epoch
            #expect(rig.store.drop(keyA))
            #expect(!rig.store.drop(keyA), "once")
            guard let directory = rig.directory else {
                return
            }
            // The file went from under us, or came up short: forget it, and anything built on it.
            rig.store.keep(keyA, bytes: bytes(100), basedOn: nil, now: 0)
            try FileManager.default.removeItem(at: directory.appending(path: "\(keyA).part"))
            #expect(rig.store.open(keyA, offset: 50) == nil)
            #expect(rig.store.length(keyA) == 0)
            #expect(rig.errors.withLock { !$0.isEmpty }, "the read's error is reported")
            rig.store.keep(keyB, bytes: bytes(100), basedOn: nil, now: 0)
            let opened = try #require(rig.store.open(keyB, offset: 100)).epoch
            try Data(bytes(40)).write(to: directory.appending(path: "\(keyB).part"))
            #expect(
                rig.store.open(keyB, offset: 100) == nil, "a short read retires it, where Kotlin retires only a file that will not open")
            #expect(rig.store.length(keyB) == 0)
            #expect(!rig.store.keep(keyB, bytes: bytes(200), basedOn: opened, now: 0))
            #expect(rig.names.isEmpty)
            #expect(!rig.store.keep(keyA, bytes: bytes(300), basedOn: epoch, now: 0), "the first lineage is long retired")
        }
    }

    @Test func aKeepThatCannotWriteInstallsNothingAndIsReported() throws {
        try PartialBlobStoreKind.file.withStore { rig in
            let directory = try #require(rig.directory)
            rig.store.keep(keyA, bytes: bytes(100), basedOn: nil, now: 0)
            try FileManager.default.removeItem(at: directory)
            #expect(!rig.store.keep(keyB, bytes: bytes(100), basedOn: nil, now: 0))
            #expect(rig.store.length(keyB) == 0)
            #expect(rig.store.length(keyA) == 100, "what was kept is as it was in the book")
            #expect(rig.errors.withLock { !$0.isEmpty })
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(keyB).staging").path(percentEncoded: false)))
        }
    }

    @Test func theEpochsRememberedAreTheSixtyFourUsedLast() throws {
        var book = PartialBlobBook(limits: PartialBlobBook.Limits(minBytes: 1, maxCount: 100))
        let hashes = (0..<65).map { BlobHash(computedDigest: [UInt8](repeating: UInt8($0), count: 32)) }
        var epochs: [Int] = []
        for hash in hashes {
            _ = book.keep(hash, length: 10, basedOn: nil, now: 0) { true }
            let opened = book.open(hash, offset: 10) { [UInt8](repeating: 0, count: $0) }
            epochs.append(try #require(opened).epoch)
        }
        #expect(Set(epochs).count == 65)
        // The first hash's epoch was the least recently used, and is forgotten: a copy built on it is refused.
        let forgotten = book.keep(hashes[0], length: 20, basedOn: epochs[0], now: 0) { true }
        let remembered = book.keep(hashes[1], length: 20, basedOn: epochs[1], now: 0) { true }
        #expect(!forgotten && remembered)
        #expect(book.takeOwed().lines.last == "partial \(hashes[1].string.prefix(12)) kept 20B")
    }
}
