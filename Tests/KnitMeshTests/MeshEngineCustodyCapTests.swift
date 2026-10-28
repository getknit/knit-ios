import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh
@testable import KnitStore

/// Custody's byte cap at the engine (knit-next #227): a frame custody refuses for its size is still delivered and relayed,
/// and our own still goes out. Each runs on a small cap, as the shared vector's rig does, so a body inside the 2000-unit
/// clamp is over it.
@Suite struct MeshEngineCustodyCapTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let start = EngineFixture.start

    private static let cap = 1024

    private func fixture() -> EngineFixture {
        EngineFixture(alice, stores: .inMemory(custodyLimits: CustodyLimits(maxSignedBytes: Self.cap)))
    }

    @Test func anOversizeRoomPostIsDeliveredAndRelayedThoughCustodyRefusesIt() throws {
        let fixture = fixture()
        fixture.link(bob, carol)
        try fixture.pin(bob)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        let post = try bob.roomPost(String(repeating: "x", count: 1500), id: frameIdOf("big-post"), sentAt: start)
        #expect(post.wire.signed.count > Self.cap)
        fixture.deliver(post, from: bob)
        #expect(announced(fixture.engine.drainEvents()).map(\.record.id) == [frameIdOf("big-post")], "delivered")
        #expect(!fixture.stores.custody.contains(frameIdOf("big-post")))
        #expect(fixture.engine.custodyOversizeRefused == 1)
        #expect(fixture.engine.groupCustodyRefused == 0)
        #expect(fixture.log.all.contains { $0.hasPrefix("debug custody refused ") && $0.hasSuffix("signed bytes over the cap") })
        fixture.advance(150)
        #expect(fixture.transport.written(.chat).map(\.to) == [carol.nodeId], "and relayed")
    }

    @Test func ourOwnOversizePostStillGoesOut() throws {
        let fixture = fixture()
        fixture.link(bob)
        fixture.transport.clear()
        let record = try #require(fixture.engine.postToRoom(String(repeating: "y", count: 1500)))
        #expect(!fixture.stores.custody.contains(record.id))
        #expect(fixture.engine.custodyOversizeRefused == 1)
        fixture.advance(150)
        let sent = fixture.transport.written(.chat)
        #expect(sent.map(\.envelope.id) == [record.id], "the send goes")
    }

    @Test func aRowStoredBeforeTheCapIsSweptAtStartAndTwoNodesAgree() throws {
        // The blobs design pass's sixth point: an upgraded node's custody holds a row a build without the cap stored. Its
        // start sweeps it, so a peer that never held it agrees on the live ids after the digests cross, with nothing in
        // the cap evicted and nothing re-served to be refused.
        let stores = MeshStores.inMemory(custodyLimits: CustodyLimits(maxSignedBytes: 1_000_000))
        let custody = try #require(stores.custody as? MemoryCustodyStore)
        let big = try carol.roomPost(String(repeating: "x", count: 62_000), id: frameIdOf("old-big"), sentAt: start)
        let small = try carol.roomPost("small", id: frameIdOf("old-small"), sentAt: start)
        #expect(big.wire.signed.count > CustodyLimits().maxSignedBytes)
        for frame in [big, small] {
            custody.store(
                CarriedFrame(envelope: frame.envelope, sig: frame.wire.sig, signed: frame.wire.signed), origin: .relayed, now: start)
        }
        #expect(custody.contains(frameIdOf("old-big")))
        custody.limits = CustodyLimits()

        let upgraded = EngineFixture(alice, stores: stores)
        #expect(!custody.contains(frameIdOf("old-big")), "swept at start")
        #expect(custody.contains(frameIdOf("old-small")))
        let peer = EngineFixture(bob, seed: 9)
        try upgraded.pin(carol)
        try peer.pin(carol)
        let lab = EngineLab([upgraded, peer])
        lab.link(0, 1)
        lab.advance(MeshConfiguration().reofferMilliseconds)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)))
        #expect(lab.liveIds(1).contains(frameIdOf("old-small")), "the row in the cap is back-filled")
        #expect(!lab.liveIds(1).contains(frameIdOf("old-big")))
        #expect(upgraded.engine.custodyOversizeRefused == 0 && peer.engine.custodyOversizeRefused == 0, "nothing re-served to refuse")
    }
}
