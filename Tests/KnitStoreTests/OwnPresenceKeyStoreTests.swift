import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// Our own presence keys in the store (ADR 2026-11.prsp), against every implementation: `PresenceKeyRepository`'s own half
/// (`applyOwn` and `markStore`, `data/presencekey/PresenceKeyRepository.kt:45-68`, `:184-251` at knit-next `cad69c77b`), and
/// `PresenceKeyRepositoryTest`'s mark cases.
@Suite struct OwnPresenceKeyStoreTests {
    private static let kinds = RepositoryKind.allCases

    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)
    private let now: Int64 = 1_756_200_000_000

    private func own(_ generation: Int64, activatedAt: Int64?, _ audience: Set<NodeId>) throws -> OwnPresenceKeyRecord {
        OwnPresenceKeyRecord(
            generation: generation,
            key: try #require(PresenceKey(bytes: fixtureBytes(32, seed: Int(generation % 100)))),
            mintedAt: now,
            activatedAt: activatedAt,
            audience: audience
        )
    }

    /// Previous, current and next, as a fresh pair over an old key leaves them.
    private func threeRows(_ store: any PresenceKeyStore) throws -> [OwnPresenceKeyRecord] {
        let rows = [
            try own(now, activatedAt: now - 9, [alice]), try own(now + 1, activatedAt: now, [alice, bob]),
            try own(now + 2, activatedAt: nil, [alice, bob]),
        ]
        store.applyOwn(inserted: rows, updated: [], keep: Set(rows.map(\.generation)))
        return rows
    }

    @Test(arguments: kinds)
    func ownKeysAreInsertedMovedAndKeptAsARotationSays(kind: RepositoryKind) throws {
        let store = try kind.make().presenceKeys
        #expect(store.ownKeys().isEmpty)
        let rows = try threeRows(store)
        #expect(store.ownKeys() == rows.reversed(), "newest first, every field back")
        var promoted = rows[2]
        promoted.activatedAt = now + 7
        let next = try own(now + 3, activatedAt: nil, [alice])
        store.applyOwn(inserted: [next], updated: [promoted], keep: [rows[1].generation, promoted.generation, next.generation])
        #expect(store.ownKeys().map(\.generation) == [now + 3, now + 2, now + 1], "the oldest went")
        #expect(store.ownKeys().first { $0.generation == now + 2 }?.activatedAt == now + 7)
        store.applyOwn(inserted: [], updated: [], keep: [])
        #expect(store.ownKeys().isEmpty, "an empty keep holds nothing")
    }

    /// A mark lands only under the current key (`setCurrentMark`, `PresenceKeyDao.kt:45-60`), and a rotation's update moves
    /// the activation and the audience alone: a replace would zero the mark, and the advertiser could air a slot again.
    @Test(arguments: kinds)
    func aMarkLandsOnlyUnderTheCurrentKeyAndAnUpdateKeepsIt(kind: RepositoryKind) throws {
        let store = try kind.make().presenceKeys
        let rows = try threeRows(store)
        let mark = PresenceMark(slot: 77, restart: 2)
        #expect(store.writeMark(mark, of: rows[1].generation) == .durable)
        #expect(store.mark(of: rows[1].generation) == mark)
        #expect(store.writeMark(mark, of: rows[0].generation) == .refused, "the previous key airs no more")
        #expect(store.writeMark(mark, of: rows[2].generation) == .refused, "the next key has not aired")
        #expect(store.writeMark(mark, of: now + 50) == .refused, "no such key")
        #expect(store.mark(of: rows[0].generation) == nil && store.mark(of: rows[2].generation) == nil)

        var grown = rows[1]
        grown.audience.insert(fixtureNodeId(3))
        store.applyOwn(inserted: [], updated: [grown], keep: Set(rows.map(\.generation)))
        #expect(store.mark(of: rows[1].generation) == mark, "a grow keeps the mark")
        #expect(store.ownKeys().first { $0.generation == rows[1].generation }?.audience.count == 3)

        // A fresh pair demotes the marked key: a mark under it now is refused, and its own mark stays where it was.
        let fresh = [try own(now + 10, activatedAt: now + 10, [alice]), try own(now + 11, activatedAt: nil, [alice])]
        store.applyOwn(inserted: fresh, updated: [], keep: [rows[1].generation, now + 10, now + 11])
        #expect(store.writeMark(PresenceMark(slot: 78, restart: 0), of: rows[1].generation) == .refused)
        #expect(store.mark(of: rows[1].generation) == mark)
        #expect(store.writeMark(PresenceMark(slot: 78, restart: 0), of: now + 10) == .durable)
    }

    /// An update for a generation no longer held moves nothing, as SQL's `UPDATE` finds no row.
    @Test(arguments: kinds)
    func anUpdateForAGenerationNoLongerHeldMovesNothing(kind: RepositoryKind) throws {
        let store = try kind.make().presenceKeys
        let rows = try threeRows(store)
        var gone = try own(now + 40, activatedAt: now, [alice])
        gone.audience = [bob]
        store.applyOwn(inserted: [], updated: [gone], keep: Set(rows.map(\.generation)))
        #expect(store.ownKeys() == rows.reversed())
    }

    /// The memory store answers a commit that would not run at FULL as the SQL store does, when made to.
    @Test func aMarkThatWouldNotCommitAtFullIsRefused() throws {
        let store = MemoryPresenceKeyStore(durableMarks: false)
        let rows = try threeRows(store)
        #expect(store.writeMark(PresenceMark(slot: 1, restart: 0), of: rows[1].generation) == .notFull)
        #expect(store.mark(of: rows[1].generation) == nil)
    }

    /// Never inside a unit: SQLite refuses the pragma inside a transaction, which would fail the caller's unit. Both stores
    /// refuse at once, write nothing, and leave the unit standing.
    @Test(arguments: kinds)
    func aMarkAskedInsideAUnitIsRefusedAtOnceAndFailsNothing(kind: RepositoryKind) throws {
        let stores = try kind.make()
        let rows = try threeRows(stores.presenceKeys)
        #expect(stores.presenceKeys.writeMark(PresenceMark(slot: 5, restart: 0), of: rows[1].generation) == .durable)
        let unit = stores.transactor.atomically { () -> PresenceMarkWrite? in
            stores.presenceKeys.writeMark(PresenceMark(slot: 6, restart: 1), of: rows[1].generation)
        }
        #expect(unit == .committed(.insideUnit))
        #expect(stores.presenceKeys.mark(of: rows[1].generation) == PresenceMark(slot: 5, restart: 0), "the mark as it was")
    }

    @Test(arguments: kinds)
    func aFailedUnitWritesNoKeyOfOurs(kind: RepositoryKind) throws {
        let failures = FailureCount()
        let stores = try kind.make(failures: failures.record)
        let rows = [try own(now, activatedAt: now, [alice])]
        let outcome = stores.transactor.atomically { () -> Int? in
            stores.presenceKeys.applyOwn(inserted: rows, updated: [], keep: [now])
            if let memory = stores.transactor as? MemoryTransactor {
                memory.failCurrentUnit()
            } else {
                // A second insert of one generation breaks the key: a store error inside the unit (`insertOwn`'s ABORT).
                stores.presenceKeys.applyOwn(inserted: rows, updated: [], keep: [now])
            }
            return 1
        }
        #expect(outcome == .failed)
        #expect(stores.presenceKeys.ownKeys().isEmpty)
    }
}
