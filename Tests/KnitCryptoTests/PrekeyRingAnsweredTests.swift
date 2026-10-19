import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

/// The inits this identity answered, kept beside its prekeys in the identity's own item (ADR 2026-10.wcex): the stored form
/// grows by a fourth key that an older build loads past and writes back as it was, a write reads, checks the identity,
/// replaces that key alone, writes and reads back before the ring changes, and what is kept is pruned past its window and
/// capped per peer and in all.
@Suite struct PrekeyRingAnsweredTests {
    private let start: Int64 = 1_756_200_000_000
    private let window = PrekeyRing.answeredMilliseconds

    private func keys(_ seed: Int) throws -> IdentityKeys {
        try #require(IdentityKeys(signingSeed: fixtureBytes(32, seed: seed), agreementScalar: fixtureBytes(32, seed: seed + 1)))
    }

    private func peer(_ seed: Int) throws -> NodeId {
        try keys(seed).nodeId
    }

    private func eph(_ seed: Int) -> [UInt8] {
        fixtureBytes(32, seed: 500 + seed)
    }

    private func entries(_ bytes: [UInt8]?) throws -> [CBOR.Entry] {
        guard case .map(let entries) = try CBOR.decode(try #require(bytes)) else {
            Issue.record("the item is not a map")
            return []
        }
        return entries
    }

    private func value(_ key: String, in bytes: [UInt8]?) throws -> CBOR? {
        try entries(bytes).last { $0.key == .text(key) }?.value
    }

    @Test func anAnsweredInitIsKeptBesideThePrekeysAndTheIdentityAndReadBackByAReinstall() throws {
        let identity = try keys(1)
        let store = MemorySecretStore(secret: identity.storedForm, refuses: false)
        var ring = try PrekeyRing.load(for: identity, from: store)
        try ring.rotate(now: start)
        let prekeys = try value("prekeys", in: store.contents)
        let carol = try peer(10)

        #expect(try ring.keepAnswered(eph(1), from: carol, now: start + 1))
        #expect(ring.answered(eph(1), by: carol, now: start + 2))
        #expect(!ring.answered(eph(1), by: try peer(11), now: start + 2), "keyed by peer")
        #expect(!ring.answered(eph(2), by: carol, now: start + 2))
        #expect(try value("prekeys", in: store.contents) == prekeys, "the prekeys as they were stored")
        #expect(IdentityKeys(storedForm: try #require(store.contents))?.nodeId == identity.nodeId)

        let writes = store.writes
        #expect(try !ring.keepAnswered(eph(1), from: carol, now: start + 3), "already kept")
        #expect(store.writes == writes, "and nothing written for it")

        let reinstalled = try PrekeyRing.load(for: identity, from: store)
        #expect(reinstalled.answeredInits == [PrekeyRing.AnsweredInit(peer: carol, eph: eph(1), at: start + 1)])
        #expect(reinstalled.prekeys.map(\.id) == ring.prekeys.map(\.id))
    }

    /// The additive growth: a build from before this one reads its identity and prekeys from the grown map by key, loading
    /// writes nothing, and its rotation, the code this build still runs, writes the fourth key back as it was stored. A
    /// write of this build likewise leaves the prekeys as stored.
    @Test func anOlderBuildLoadsTheGrownMapAndItsRotationKeepsTheAnsweredInits() throws {
        let identity = try keys(1)
        let store = MemorySecretStore(secret: identity.storedForm, refuses: false)
        var ring = try PrekeyRing.load(for: identity, from: store)
        try ring.rotate(now: start)
        try ring.keepAnswered(eph(1), from: try peer(10), now: start)
        let answered = try value("answered", in: store.contents)
        let grown = try #require(store.contents)

        let loaded = try IdentityKeys.load(from: store)
        #expect(loaded.origin == .stored && loaded.keys.nodeId == identity.nodeId)
        #expect(store.contents == grown, "loading the identity writes nothing")
        var older = try PrekeyRing.load(for: identity, from: store)
        #expect(older.newest?.id == 1)
        try older.rotate(now: start + PrekeyRing.rotationMilliseconds)
        #expect(try value("answered", in: store.contents) == answered, "a rotation writes the answered inits back as stored")
        #expect(try PrekeyRing.load(for: identity, from: store).answeredInits.count == 1)
    }

    @Test func aRefusedWriteLeavesTheRingAndTheKeptSetAsTheyWere() throws {
        let identity = try keys(1)
        let store = MemorySecretStore(secret: identity.storedForm, refuses: false)
        var ring = try PrekeyRing.load(for: identity, from: store)
        try ring.rotate(now: start)
        try ring.keepAnswered(eph(1), from: try peer(10), now: start)
        let before = (ring.prekeys.map(\.info), ring.answeredInits, store.contents)

        store.refusesWrites = true
        #expect(throws: PrekeyRing.Failure.store(.unavailable("full"))) {
            try ring.keepAnswered(eph(2), from: try peer(10), now: start + 1)
        }
        #expect(ring.prekeys.map(\.info) == before.0 && ring.answeredInits == before.1 && store.contents == before.2)
        #expect(!ring.answered(eph(2), by: try peer(10), now: start + 1))

        store.refusesWrites = false
        store.refuses = true
        #expect(throws: PrekeyRing.Failure.store(.unavailable("locked"))) {
            try ring.keepAnswered(eph(2), from: try peer(10), now: start + 1)
        }
        #expect(ring.answeredInits == before.1)
        #expect(throws: SecretStoreError.unavailable("locked"), "before the first unlock loading throws, never an empty set") {
            try PrekeyRing.load(for: identity, from: store)
        }
    }

    @Test func anotherIdentityInTheStoreChangesNothing() throws {
        let identity = try keys(1)
        let store = MemorySecretStore(secret: identity.storedForm, refuses: false)
        var ring = try PrekeyRing.load(for: identity, from: store)
        try ring.keepAnswered(eph(1), from: try peer(10), now: start)
        let replaced = try keys(3).storedForm
        try store.write(replaced)

        #expect(throws: PrekeyRing.Failure.identityReplaced) {
            try ring.keepAnswered(eph(2), from: try peer(10), now: start + 1)
        }
        #expect(store.contents == replaced)
        #expect(ring.answeredInits.count == 1)
        #expect(try PrekeyRing.load(for: identity, from: store).answeredInits.isEmpty, "another identity's item keeps none of ours")
    }

    @Test func aWriteThatDoesNotReadBackChangesNothing() throws {
        let identity = try keys(1)
        let store = MemorySecretStore(secret: identity.storedForm, refuses: false)
        var ring = try PrekeyRing.load(for: identity, from: store)
        store.dropsWrites = true
        #expect(throws: PrekeyRing.Failure.readBack) {
            try ring.keepAnswered(eph(1), from: try peer(10), now: start)
        }
        #expect(ring.answeredInits.isEmpty && store.contents == identity.storedForm)
    }

    /// An `answered` this build cannot read as a list, a newer build's, is neither read nor written over, and a rotation
    /// keeps it as it was. Within a list, an entry this build cannot read is dropped at the next write: a hint, never a key.
    @Test func anAnsweredFormThisBuildCannotReadIsLeftAlone() throws {
        let identity = try keys(1)
        let newer = CBOR.Entry(key: .text("answered"), value: .map([CBOR.Entry(key: .text("v"), value: CBOR(Int64(2)))]))
        let store = MemorySecretStore(secret: CBOR.map(try entries(identity.storedForm) + [newer]).encoded, refuses: false)
        var ring = try PrekeyRing.load(for: identity, from: store)
        #expect(ring.answeredInits.isEmpty)
        #expect(throws: PrekeyRing.Failure.unreadableAnswers) {
            try ring.keepAnswered(eph(1), from: try peer(10), now: start)
        }
        try ring.rotate(now: start)
        #expect(try value("answered", in: store.contents) == newer.value)

        let odd = CBOR.Entry(key: .text("answered"), value: .array([.text("not an init")]))
        try store.write(CBOR.map(try entries(identity.storedForm) + [odd]).encoded)
        var again = try PrekeyRing.load(for: identity, from: store)
        #expect(again.answeredInits.isEmpty)
        try again.keepAnswered(eph(1), from: try peer(10), now: start)
        #expect(try value("answered", in: store.contents) == .array([try #require(answeredItems(store.contents).first)]))
        #expect(try answeredItems(store.contents).count == 1)
    }

    private func answeredItems(_ bytes: [UInt8]?) throws -> [CBOR] {
        guard case .array(let items) = try value("answered", in: bytes) else {
            return []
        }
        return items
    }

    @Test func whatIsKeptIsPrunedPastItsWindowAtTheNextWrite() throws {
        let identity = try keys(1)
        let store = MemorySecretStore(secret: identity.storedForm, refuses: false)
        var ring = try PrekeyRing.load(for: identity, from: store)
        let carol = try peer(10)
        try ring.keepAnswered(eph(1), from: carol, now: start)
        try ring.keepAnswered(eph(2), from: carol, now: start + window / 2)
        #expect(ring.answered(eph(1), by: carol, now: start + window - 1))
        #expect(!ring.answered(eph(1), by: carol, now: start + window), "past its window it answers nothing")

        try ring.keepAnswered(eph(3), from: carol, now: start + window)
        #expect(ring.answeredInits.map(\.eph) == [eph(2), eph(3)], "and the next write prunes it")
        #expect(try answeredItems(store.contents).count == 2)
        #expect(try PrekeyRing.load(for: identity, from: store).answeredInits.map(\.eph) == [eph(2), eph(3)])
    }

    @Test func theNewestAreKeptPerPeerAndInAll() throws {
        let perPeer = PrekeyRing.answeredPerPeer
        let carol = try peer(10)
        let dave = try peer(11)
        let many = (0...perPeer).map { PrekeyRing.AnsweredInit(peer: carol, eph: eph($0), at: start + Int64($0)) }
        let other = PrekeyRing.AnsweredInit(peer: dave, eph: eph(99), at: start)
        let identity = try keys(1)
        let store = MemorySecretStore(secret: identity.storedForm, refuses: false)
        var ring = try PrekeyRing.load(for: identity, from: store)
        for answered in [other] + many {
            try ring.keepAnswered(answered.eph, from: answered.peer, now: answered.at)
        }
        #expect(ring.answeredInits == [other] + many.dropFirst(), "the oldest of carol's goes, dave's stays")

        var all = try PrekeyRing.load(for: identity, from: MemorySecretStore(secret: identity.storedForm, refuses: false))
        let total = PrekeyRing.answeredCount
        for index in 0...total {
            let distinct = [UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index)]
            let peer = try #require(NodeId(bytes: distinct + [UInt8](repeating: 7, count: NodeId.byteCount - 2)))
            try all.keepAnswered(distinct + [UInt8](repeating: 9, count: 30), from: peer, now: start + Int64(index))
        }
        #expect(all.answeredInits.count == total)
        #expect(all.answeredInits.first?.at == start + 1 && all.answeredInits.last?.at == start + Int64(total), "the oldest went")
    }
}
