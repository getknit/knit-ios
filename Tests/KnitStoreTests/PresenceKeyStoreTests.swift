import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The presence key store's contract (ADR 2026-11.sv5t), against every implementation: `PresenceKeyRepository`'s peer half
/// (`data/presencekey/PresenceKeyRepository.kt:70-110` at knit-next `cad69c77b`), and its writes inside a store unit.
@Suite struct PresenceKeyStoreTests {
    private static let kinds = RepositoryKind.allCases

    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)
    private let carol = fixtureNodeId(3)

    private func key(_ seed: Int) throws -> PresenceKey {
        try #require(PresenceKey(bytes: fixtureBytes(PresenceKey.byteCount, seed: seed)))
    }

    private func held(_ generation: Int64, _ seed: Int, tag: Int64 = 7) throws -> HeldPresenceKey {
        HeldPresenceKey(generation: generation, key: try key(seed), rootTag: tag)
    }

    @Test(arguments: kinds)
    func keysAreHeldNewestFirstPerPeerAndReplacedWhole(kind: RepositoryKind) throws {
        let store = try kind.make().presenceKeys
        #expect(store.keys(of: bob).isEmpty)
        store.replaceKeys(of: bob, with: [try held(10, 1), try held(12, 2), try held(11, 3)], now: 100)
        store.replaceKeys(of: carol, with: [try held(5, 4, tag: -9)], now: 100)
        #expect(store.keys(of: bob).map(\.held.generation) == [12, 11, 10])
        #expect(store.keys(of: carol) == [StoredPresenceKey(held: try held(5, 4, tag: -9), receivedAt: 100)], "a negative tag reads back")
        // The verdict is every key held afterwards: a generation it leaves out goes.
        store.replaceKeys(of: bob, with: [try held(13, 5), try held(12, 2)], now: 200)
        #expect(store.keys(of: bob).map(\.held.generation) == [13, 12])
        #expect(store.peersWithKeys() == [bob, carol].sorted())
        #expect(store.keys(of: [alice, bob, carol]).mapValues { $0.map(\.held.generation) } == [bob: [13, 12], carol: [5]])
    }

    /// `applyHeld` keeps a row's first arrival only when its bytes and its root both stand (`PresenceKeyRepository.kt:85-95`).
    @Test(arguments: kinds)
    func aRowKeepsItsFirstArrivalOnlyWhileItsBytesAndRootStand(kind: RepositoryKind) throws {
        let store = try kind.make().presenceKeys
        store.replaceKeys(of: bob, with: [try held(10, 1), try held(11, 2), try held(12, 3)], now: 100)
        store.replaceKeys(of: bob, with: [try held(10, 1), try held(11, 9), try held(12, 3, tag: 8)], now: 200)
        #expect(store.keys(of: bob).map(\.receivedAt) == [200, 200, 100], "a new root, new bytes, then the same row")
    }

    @Test(arguments: kinds)
    func deletingAPeersKeysLeavesTheOthers(kind: RepositoryKind) throws {
        let store = try kind.make().presenceKeys
        store.replaceKeys(of: bob, with: [try held(10, 1)], now: 100)
        store.replaceKeys(of: carol, with: [try held(10, 2)], now: 100)
        store.deleteKeys(of: [bob, alice])
        store.deleteKeys(of: [])
        #expect(store.peersWithKeys() == [carol])
        #expect(store.keys(of: bob).isEmpty)
        store.replaceKeys(of: carol, with: [], now: 300)
        #expect(store.peersWithKeys().isEmpty, "an empty verdict holds nothing")
    }

    /// A key written inside a unit that fails is gone with the rest of it, as the ratchet open it rode is.
    @Test(arguments: kinds)
    func aFailedUnitWritesNoKey(kind: RepositoryKind) throws {
        let failures = FailureCount()
        let stores = try kind.make(failures: failures.record)
        stores.presenceKeys.replaceKeys(of: carol, with: [try held(1, 1)], now: 1)
        let rows = [try held(10, 2)]
        let outcome = stores.transactor.atomically { () -> Int? in
            stores.presenceKeys.replaceKeys(of: bob, with: rows, now: 100)
            stores.presenceKeys.deleteKeys(of: [carol])
            if let memory = stores.transactor as? MemoryTransactor {
                memory.failCurrentUnit()
            } else {
                // A roster naming a member twice breaks `group_members`' primary key: a store error inside the unit.
                let member = GroupMember(nodeId: alice.string)
                stores.groups.save(GroupRecord(id: "g-refused", createdBy: alice.string, createdAt: 1, roster: [member, member]))
            }
            return 1
        }
        #expect(outcome == .failed)
        #expect(stores.presenceKeys.keys(of: bob).isEmpty)
        #expect(stores.presenceKeys.peersWithKeys() == [carol])
        #expect(failures.value == (kind == .sql ? 1 : 0))
    }

    /// Nothing a store row prints shows a key (knit-next ADR 2026-11.xp6d, "Logging").
    @Test func aStoredKeyPrintsItsGenerationOnly() throws {
        let row = StoredPresenceKey(held: try held(42, 1), receivedAt: 5)
        let printed = "\(row) \(row.held) \(String(reflecting: row.held.key)) \([row])"
        #expect(printed.contains("g=42"))
        #expect(!printed.contains("rootTag") && !printed.contains(", 8, 15"), "\(printed)")
    }
}
