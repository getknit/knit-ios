import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The keyreq answer budget wired into the engine (ADR 2026-10.f5zs, rule 5): a request's answers and a pin's wanters
/// draw on one bucket per link peer, on the monotonic clock.
@Suite struct MeshEngineKeyBudgetTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)

    /// The profiles that went to `peer` point to point, as a keyreq's answers do.
    private func served(to peer: TestPeer, in fixture: EngineFixture) -> [Written] {
        fixture.transport.written(.profile).filter { $0.to == peer.nodeId && !$0.wire.relay }
    }

    /// Production's custody limits with the profile cap lifted (ADR 2026-10.r88m): the budget counts bytes, so one profile
    /// past a whole burst stands for the many in-cap answers that would drain it.
    static let liftedProfileCap = CustodyLimits(maxProfileSignedBytes: .max)

    @Test func aWanterInDebtIsNotServedWhenItsKeyPinsAndIsServedOnRefill() throws {
        let fixture = EngineFixture(alice, stores: .inMemory(custodyLimits: Self.liftedProfileCap))
        fixture.link(carol, dave)
        try fixture.pin(carol)
        // Bob's profile of 300 KiB, past Carol's whole burst.
        fixture.deliver(try bob.profile(status: String(repeating: "s", count: 300 * 1024), publishedAt: EngineFixture.start), from: bob)
        fixture.transport.clear()
        fixture.deliver(try carol.keyRequest(for: [bob.nodeId], id: frameIdOf("req-drain")), from: carol)
        #expect(served(to: carol, in: fixture).count == 1, "served once, on debt")
        let unknown = TestPeer(seed: 40)
        fixture.transport.clear()
        fixture.deliver(try carol.keyRequest(for: [unknown.nodeId], id: frameIdOf("req-unknown")), from: carol)
        #expect(fixture.transport.written(.keyRequest).contains { $0.to == dave.nodeId }, "a key we lack is asked on")
        let skipped = fixture.engine.keyExchange.skippedAnswers
        fixture.transport.clear()
        // The pin reads the monotonic clock: a wall clock would read as hours of refill and serve Carol at once.
        fixture.deliver(try unknown.profile(publishedAt: EngineFixture.start), from: dave)
        #expect(served(to: carol, in: fixture).isEmpty, "Carol is in debt when the key she waited on pins")
        #expect(fixture.engine.keyExchange.skippedAnswers == skipped + 1)
        fixture.clock.advance(Int64(KeyExchange.answerBurstBytes / KeyExchange.answerRefillBytesPerSecond) * 1000)
        fixture.transport.clear()
        fixture.deliver(try carol.keyRequest(for: [unknown.nodeId], id: frameIdOf("req-again")), from: carol)
        #expect(served(to: carol, in: fixture).map(\.envelope.senderId) == [unknown.nodeId.string], "served once refilled")
    }

    @Test func aKeyRequestSkipsAndDoesNotChargeAProfileTheLinkAlreadyCarried() throws {
        let fixture = EngineFixture(alice, stores: .inMemory(custodyLimits: Self.liftedProfileCap))
        fixture.link(carol)
        try fixture.pin(carol)
        let large = try bob.profile(status: String(repeating: "s", count: 300 * 1024), publishedAt: EngineFixture.start)
        fixture.deliver(large, from: bob)
        fixture.deliver(try dave.profile(publishedAt: EngineFixture.start), from: dave)
        fixture.transport.crossed[carol.nodeId] = [try #require(FrameKey.ofSigned(large.wire))]
        fixture.transport.clear()
        fixture.deliver(try carol.keyRequest(for: [bob.nodeId, dave.nodeId], id: frameIdOf("req-crossed")), from: carol)
        #expect(served(to: carol, in: fixture).map(\.envelope.senderId) == [dave.nodeId.string], "Bob's crossed; Dave's still fits")
        #expect(fixture.transport.written(.keyRequest).isEmpty, "a crossed key is not asked on")
        #expect(fixture.engine.keyExchange.skippedAnswers == 0)
        fixture.transport.crossed = [:]
        fixture.transport.clear()
        fixture.deliver(try carol.keyRequest(for: [bob.nodeId], id: frameIdOf("req-uncrossed")), from: carol)
        #expect(served(to: carol, in: fixture).map(\.envelope.senderId) == [bob.nodeId.string], "the crossed one cost nothing")
    }
}
