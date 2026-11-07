import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The presence key feed against stores that fail (ADR 2026-11.sv5t; the crypto review's round-one findings): a failed read
/// deletes and lists nothing and leaves the revision to try again, and a block unlists at once however the store fares.
@Suite struct MeshEnginePresenceKeyFailureTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }

    private static func key(_ byte: UInt8) -> [UInt8] {
        [UInt8](repeating: byte, count: PresenceKey.byteCount)
    }

    private func held(_ byte: UInt8, _ generation: Int64 = 9) throws -> HeldPresenceKey {
        HeldPresenceKey(generation: generation, key: try #require(PresenceKey(bytes: Self.key(byte))), rootTag: 1)
    }

    /// A contact's read failing (the accepted threads) fails the first pass's unit: nobody reads as a contact, so a pass
    /// that went ahead would delete every key. Nothing is deleted or listed, the revision stays to be tried, and the
    /// failure is logged once for it however often it is tried.
    @Test func aFailedContactsReadDeletesAndListsNothingAndLeavesTheRevision() throws {
        let (stores, conversations) = try StoreKind.memory.storesRefusingConversationReads(
            blobs: scratchDirectory("pk-conversations"), failures: ReportedFailures().record)
        stores.conversations.accept(alice.nodeId.string)
        stores.presenceKeys.replaceKeys(of: alice.nodeId, with: [try held(1)], now: 1)
        stores.presenceKeys.replaceKeys(of: carol.nodeId, with: [try held(2)], now: 1)
        conversations.failsReads = true
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let revision = fixture.engine.presenceKeyFeed.revision
        fixture.engine.feedPresenceKeys()
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.presenceKeyListings.isEmpty)
        #expect(stores.presenceKeys.peersWithKeys() == [alice.nodeId, carol.nodeId].sorted())
        #expect(fixture.engine.presenceKeyFeed.listed != revision && fixture.engine.presenceKeyFeed.lastDirect == nil)
        #expect(fixture.log.all.count { $0.contains("mesh presence key listing skipped") } == 1, "once for the revision")
        conversations.failsReads = false
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.presenceKeyListings.last?.mapValues { $0.map(\.bytes) } == [alice.nodeId: [Self.key(1)]])
        #expect(stores.presenceKeys.peersWithKeys() == [alice.nodeId], "the stranger's key, at the first pass that committed")
        #expect(fixture.engine.presenceKeyFeed.listed == fixture.engine.presenceKeyFeed.revision)
    }

    /// The round-one finding: a damaged row (or a schema a lab database skipped) fails every feed's unit for good. A block
    /// still unlists the contact at once, from the last listing pushed, with no read, and the keys go at the next feed
    /// that commits.
    @Test func aBlockUnlistsAtOnceWhileTheStoreKeepsFailing() throws {
        let memory = MeshStores.inMemory()
        let refusing = try RefusingPresenceKeys(memory)
        memory.conversations.accept(alice.nodeId.string)
        memory.conversations.accept(carol.nodeId.string)
        memory.presenceKeys.replaceKeys(of: alice.nodeId, with: [try held(1)], now: 1)
        memory.presenceKeys.replaceKeys(of: carol.nodeId, with: [try held(2)], now: 1)
        let fixture = try EngineFixture.ratcheting(me, stores: memory.replacing(presenceKeys: refusing))
        try fixture.pin(alice)
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.presenceKeyListings.last?.keys.sorted() == [alice.nodeId, carol.nodeId].sorted())
        refusing.refusesReads = true
        fixture.engine.block(alice.nodeId)
        #expect(fixture.transport.presenceKeyListings.last?.keys.sorted() == [carol.nodeId], "unlisted at once")
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.presenceKeyListings.last?.keys.sorted() == [carol.nodeId], "the failed feed lists nothing new")
        #expect(memory.presenceKeys.peersWithKeys() == [alice.nodeId, carol.nodeId].sorted(), "and deletes nothing")
        refusing.refusesReads = false
        fixture.engine.feedPresenceKeys()
        #expect(memory.presenceKeys.peersWithKeys() == [carol.nodeId], "the leaver's keys, once a feed commits")
        #expect(fixture.engine.presenceKeyCounts.leavers == 1)
    }

    /// The same through the link manager: a block unlists the contact's tag from the resolver while the store fails.
    @Test func aBlockedContactsTagStopsResolvingWhileTheStoreFails() async throws {
        let radio = FakeRadio(advertisesServiceData: false)
        let clock = ManualClock(wall: now, monotonic: 1000)
        let memory = MeshStores.inMemory()
        let refusing = try RefusingPresenceKeys(memory)
        let blinding = BlindingPeer(alice.nodeId)
        memory.conversations.accept(alice.nodeId.string)
        memory.presenceKeys.replaceKeys(
            of: alice.nodeId, with: [HeldPresenceKey(generation: 9, key: blinding.key, rootTag: 1)], now: 1)
        let mesh = Mesh(
            identity: me.keys,
            deviceTag: nil,
            stores: memory.replacing(presenceKeys: refusing),
            radio: radio,
            clock: clock,
            random: SeededGenerator(seed: 11),
            log: RecordingLog()
        )
        await mesh.start()
        await mesh.process(.sighted(blinding.sighting(blinding.tag(wall: clock.wallMilliseconds()))))
        #expect(await mesh.aliasCounters.resolvedByKey == 1)
        refusing.refusesReads = true
        await mesh.block(alice.nodeId)
        var away = blinding
        away.address = RadioAddress("addr-away")
        await mesh.process(.sighted(away.sighting(away.tag(wall: clock.wallMilliseconds()))))
        #expect(await mesh.aliasCounters.resolvedByKey == 1, "the blocked contact's tag resolves no more")
    }
}
