import KnitCrypto
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Our presence keys' settle sitting out after a failed unit (ADR 2026-11.prsp): the pass opens no unit while it waits,
/// unless the listing is due, and the end of the wait is a deadline the mesh wakes for.
@Suite struct MeshEngineOwnPresenceKeySitOutTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)

    /// The iPhone over `stores` with its keys on, and Alice's Android pinned, accepted, holding the session she opened to
    /// us, and linked.
    private func rig(stores: MeshStores) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(
            me, stores: stores, configuration: MeshConfiguration(ratchet: true, sendsOwnPresenceKeys: true))
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        fixture.engine.accept(alice.nodeId.string)
        let hello = try android.dm(
            MessageContent(body: "hi"), to: me, prekey: try fixture.ourPrekey(), id: frameIdOf("hello"), sentAt: EngineFixture.start)
        fixture.deliver(hello, from: android)
        fixture.link(alice)
        return (fixture, android)
    }

    /// While the settle sits out after a failed unit, an owed pass opens no unit unless the listing is due, and the end of
    /// the sit-out is a deadline the mesh wakes for.
    @Test func theSitOutOpensNoUnitAndWakesOnItsDeadline() throws {
        let memory = MeshStores.inMemory()
        let refusing = try RefusingPresenceKeys(memory)
        let counting = CountingTransactor(memory.transactor)
        let stores = MeshStores(
            custody: memory.custody,
            peers: memory.peers,
            messages: memory.messages,
            conversations: memory.conversations,
            blocks: memory.blocks,
            groups: memory.groups,
            ownProfile: memory.ownProfile,
            blobs: memory.blobs,
            ratchet: memory.ratchet,
            groupRatchet: memory.groupRatchet,
            presenceKeys: refusing,
            transactor: counting
        )
        let (fixture, android) = try rig(stores: stores)
        // The link-up's own delayed pass falls due first, so only the sit-out's deadline is left.
        fixture.advance(MeshEngine.presenceLinkUpDelay.upperBound)
        refusing.refusesWrites = true
        fixture.engine.feedPresenceKeys()
        refusing.refusesWrites = false
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.provenSends.isEmpty, "the listing committed, our keys sat out")
        let retry = try #require(fixture.engine.presenceKeyFeed.ownSettleRetryAt)
        let units = counting.units
        for _ in 0..<5 {
            fixture.clock.advance(10_000)
            fixture.engine.feedPresenceKeys()
        }
        #expect(counting.units == units, "no unit opens while no listing is due")
        #expect(fixture.engine.nextPresenceLinkUp == retry)
        #expect(try #require(fixture.engine.nextDeadline) <= retry, "the mesh wakes for it")
        fixture.advance(retry - fixture.clock.monotonicMilliseconds())
        fixture.engine.feedPresenceKeys()
        #expect(fixture.transport.provenSends.filter { $0.to == android.nodeId }.count == 1)
    }
}

/// A store unit that counts the units opened through it, over the memory one.
private final class CountingTransactor: StoreTransactor, @unchecked Sendable {
    private let inner: any StoreTransactor
    private let opened = Lock(0)

    init(_ inner: any StoreTransactor) {
        self.inner = inner
    }

    /// Units opened so far.
    var units: Int { opened.withLock { $0 } }

    func atomically<Value>(_ body: () -> Value?) -> Transacted<Value> {
        opened.withLock { $0 += 1 }
        return inner.atomically(body)
    }
}
