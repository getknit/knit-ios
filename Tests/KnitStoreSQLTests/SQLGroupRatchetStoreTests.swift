import Foundation
import GRDB
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitStoreSQL

/// What the SQL group store adds to the contract `GroupRatchetStoreTests` runs over every kind (ADR 2026-10.5sk9): an
/// open's rows are one write, so the database takes all of them or none, inside a store unit and outside one, and a write
/// it refuses fails the unit it ran in, a TEMP trigger on the writer's connection refusing it, as `SQLRatchetStoreTests`
/// does; a retired chain's empty keys are empty blobs, as Room stores a `ByteArray(0)`, never `NULL`; and what the sweep
/// deletes leaves the database's files once it commits (ADR 2026-09.nyya, amended 2026-10-15).
@Suite struct SQLGroupRatchetStoreTests {
    private static let group = "g-0123456789abcdef01234567"
    private let sender = fixtureNodeId(1)
    /// Past the 48 h a skipped key, a receive chain and a superseded seed live.
    private static let now = GroupRatchetRetention.skippedKeyMilliseconds + 10_000
    /// The key an open spends, the keys and the chain the sweep expires, and the seed the sweep retires: bytes nothing
    /// else in the database's files holds.
    private static let spent = fixtureBytes(32, seed: 0xC1)
    private static let expired = fixtureBytes(32, seed: 0xC2)
    private static let staleChain = fixtureBytes(32, seed: 0xC3)
    private static let supersededSeed = fixtureBytes(32, seed: 0xC4)

    @Test func aGroupWriteTheDatabaseRefusesFailsItsUnitAndUndoesTheOpen() throws {
        let failures = Failures()
        let database = try KnitDatabase.inMemory(failures: failures.record)
        let store = SQLGroupRatchetStore(database)
        held(in: store)
        let before = store.holdings(of: Self.group)
        try refuseSkippedKeys(in: database)
        let outcome = database.atomically { () -> String? in
            store.applyOpen(opened, in: Self.group, from: sender, se: 1, n: 0)
            return "deliver"
        }
        #expect(outcome == .failed, "the refused key fails the unit the open ran in")
        #expect(store.holdings(of: Self.group) == before, "the chain and the spent key went with it")
        #expect(failures.count == 1, "the database reports its error once")
    }

    @Test func outsideAUnitAnOpenStandsWholeOrNotAtAll() throws {
        let failures = Failures()
        let database = try KnitDatabase.inMemory(failures: failures.record)
        let store = SQLGroupRatchetStore(database)
        held(in: store)
        let before = store.holdings(of: Self.group)
        try refuseSkippedKeys(in: database)
        store.applyOpen(opened, in: Self.group, from: sender, se: 1, n: 0)
        #expect(store.holdings(of: Self.group) == before)
        #expect(failures.count == 1)
        try database.writer.writeWithoutTransaction { db in try db.execute(sql: "DROP TRIGGER refuseKeys") }
        store.applyOpen(opened, in: Self.group, from: sender, se: 1, n: 0)
        let after = store.holdings(of: Self.group)
        #expect(after.recvChains[sender]?.map(\.next) == [5])
        #expect(after.skippedKeys[sender]?.map(\.index) == [4], "the spent key went and the banked one stands")
    }

    /// A retired chain keeps its empty seed and chain key as empty blobs, which read back as no key, whether or not the
    /// Foundation's empty `Data` hands GRDB a pointer: SQLite binds a nil one as `NULL`, which Kotlin's columns refuse.
    @Test func aRetiredChainKeepsItsEmptyKeysAsEmptyBlobs() throws {
        let database = try KnitDatabase.inMemory(failures: recordFailure)
        let store = SQLGroupRatchetStore(database)
        store.commitSend(GroupSendChainRecord(epoch: 3, seed: [1], chainKey: [2], count: 4, mintedAt: 5), in: Self.group)
        store.retireSendChains(Self.group)
        let columns = try database.writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT typeof(seed) AS seedType, length(seed) AS seedLength, typeof(chainKey) AS keyType FROM group_send_chains")
        }
        #expect(columns?["seedType"] as String? == "blob" && columns?["keyType"] as String? == "blob")
        #expect(columns?["seedLength"] as Int? == 0)
        #expect(
            store.sendChain(Self.group)
                == GroupSendChainRecord(
                    epoch: 3, seed: [], chainKey: [], count: GroupRatchetRetention.retiredCount, mintedAt: 5))
    }

    /// What the group form deletes leaves the files once the sweep commits, the sweep run alone or inside a unit: each key
    /// is zeroed in the next write of its page (`secure_delete`), which goes to the log, and the truncating checkpoint
    /// copies those pages over the file and empties the log, which still held the frames that wrote them. Linux's SQLite
    /// zeroes freed pages by default, so here this catches the log; on the Mac the expired keys' pages catch the file too.
    @Test(arguments: [false, true])
    func whatTheGroupFormDeletesLeavesTheFileAndItsLog(inAUnit: Bool) throws {
        try withDatabaseFile(failures: recordFailure) { database, directory throws in
            let store = SQLGroupRatchetStore(database)
            storeKeysThatWillDie(in: store)
            for key in [Self.spent, Self.expired, Self.staleChain, Self.supersededSeed] {
                #expect(try occurs(key, in: directory), "the files hold every key once it is written")
            }

            // The open that spends the key deletes it; the log keeps the frame that wrote it.
            store.applyOpen(GroupOpenDelta(recvChain: nil, consumedSkippedMintedAt: 1), in: Self.group, from: sender, se: 1, n: 0)
            #expect(try occurs(Self.spent, in: directory), "until the sweep, the log still holds a spent key's insert")

            if inAUnit {
                let unit = database.atomically { () -> Int? in
                    store.sweep(now: Self.now)
                    return 1
                }
                #expect(unit == .committed(1))
            } else {
                store.sweep(now: Self.now)
            }
            let left = store.holdings(of: Self.group)
            #expect(left.skippedKeys.isEmpty && left.recvChains.isEmpty && left.sendChains.map(\.epoch) == [3])
            for key in [Self.spent, Self.expired, Self.staleChain, Self.supersededSeed] {
                #expect(try !occurs(key, in: directory), "neither the file nor its log holds a deleted key")
            }
            #expect(try logSize(in: directory) == 0)
        }
    }

    /// Our three epochs, the first two superseded long since; a key an open will spend; a chain unused for two days; and
    /// enough expired keys to fill pages the sweep frees whole.
    private func storeKeysThatWillDie(in store: SQLGroupRatchetStore) {
        store.commitSend(
            GroupSendChainRecord(epoch: 1, seed: Self.supersededSeed, chainKey: fixtureBytes(32, seed: 0xD1), count: 9, mintedAt: 1),
            in: Self.group)
        let draining = GroupSendChainRecord(
            epoch: 2, seed: fixtureBytes(32, seed: 0xD2), chainKey: fixtureBytes(32, seed: 0xD3), count: 9, mintedAt: 2)
        store.commitSend(draining, in: Self.group)
        let current = GroupSendChainRecord(
            epoch: 3, seed: fixtureBytes(32, seed: 0xD4), chainKey: fixtureBytes(32, seed: 0xD5), count: 1, mintedAt: 3)
        store.commitSend(current, in: Self.group)
        store.insertRecvChain(
            GroupRecvChainRecord(epoch: 1, mintedAt: 1, chainKey: Self.staleChain, next: 1, lastUsedAt: 1), in: Self.group, from: sender)
        let banked =
            [GroupSkippedKeyRecord(epoch: 1, mintedAt: 1, index: 0, messageKey: Self.spent, createdAt: Self.now)]
            + (1...400).map { GroupSkippedKeyRecord(epoch: 2, mintedAt: 1, index: $0, messageKey: Self.expired, createdAt: 1) }
        store.applyOpen(GroupOpenDelta(recvChain: nil, skippedInserts: banked), in: Self.group, from: sender, se: 2, n: 0)
    }

    /// What the sender's rows hold before the open: a chain at 2 and a key banked at index 0.
    private func held(in store: SQLGroupRatchetStore) {
        store.insertRecvChain(
            GroupRecvChainRecord(epoch: 1, mintedAt: 1, chainKey: [4], next: 2, lastUsedAt: 1), in: Self.group, from: sender)
        store.applyOpen(
            GroupOpenDelta(
                recvChain: nil, skippedInserts: [GroupSkippedKeyRecord(epoch: 1, mintedAt: 1, index: 0, messageKey: [5], createdAt: 1)]),
            in: Self.group,
            from: sender,
            se: 1,
            n: 2
        )
    }

    /// An open that advances the chain, banks a key and spends the one at index 0.
    private var opened: GroupOpenDelta {
        GroupOpenDelta(
            recvChain: GroupRecvChainRecord(epoch: 1, mintedAt: 1, chainKey: [7], next: 5, lastUsedAt: 2),
            skippedInserts: [GroupSkippedKeyRecord(epoch: 1, mintedAt: 1, index: 4, messageKey: [8], createdAt: 2)],
            consumedSkippedMintedAt: 1
        )
    }

    /// A trigger that refuses every group skipped key, as a full disk refuses a write.
    private func refuseSkippedKeys(in database: KnitDatabase) throws {
        try database.writer.writeWithoutTransaction { db in
            try db.execute(
                sql: "CREATE TEMP TRIGGER refuseKeys BEFORE INSERT ON main.group_skipped_keys BEGIN SELECT RAISE(ABORT, 'disk full'); END"
            )
        }
    }
}
