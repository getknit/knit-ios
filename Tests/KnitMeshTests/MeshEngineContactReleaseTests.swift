import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The frames parked for a key, released at a card's pin (ADR 2026-10.tpr5), apart from `MeshEngineContactTests` to keep
/// its body inside the lint's length.
@Suite struct MeshEngineContactReleaseTests {
    private let me = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }

    /// `peer`'s card as their own engine would sign it.
    private func card(of peer: TestPeer) throws -> ContactCard.Card {
        let links = try #require(ContactCard.encode(peer.keys, name: "Bob", issuedAt: now))
        return try #require(ContactCard.parse(links.url).card)
    }

    /// An engine for `me` with Carol linked as a neighbour, and what linking wrote cleared.
    private func linked() -> EngineFixture {
        let fixture = EngineFixture(me, stores: .inMemory())
        fixture.link(carol)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        return fixture
    }

    /// The design pass's non-blocking finding, adopted: a frame parked for the key is delivered at the card's pin, where
    /// Kotlin waits for the profile (`InboundPipeline.kt:3649`).
    @Test(arguments: [ContactSource.scan, .link])
    func aFrameParkedForTheKeyIsDeliveredAtThePin(source: ContactSource) throws {
        let fixture = linked()
        fixture.deliver(try bob.roomPost("early", id: "post-1", sentAt: now), from: carol)
        #expect(fixture.engine.dropped[.noSenderKey] == 1 && fixture.stores.messages.message("post-1") == nil, "parked")
        fixture.transport.clear()
        #expect(fixture.engine.addContact(try card(of: bob), from: source, unblock: false) == .added(bob.nodeId))
        #expect(fixture.stores.messages.message("post-1")?.body == "early")
        // The release goes through `deliver`, which carries what it delivers, and past the router, which flooded the frame
        // when it arrived (the blobs review).
        #expect(fixture.stores.custody.liveIds(now: fixture.clock.wallMilliseconds()).contains("post-1"), "carried at the pin")
        #expect(fixture.transport.written(.chat).isEmpty, "not flooded a second time")
    }

    /// A DM to us parked for the key is delivered at the pin and ticked once, in the clear, since the card carries no
    /// ratchet bits.
    @Test func aDirectMessageParkedForTheKeyIsDeliveredAndTickedOnceAtThePin() throws {
        let fixture = linked()
        fixture.deliver(try bob.directMessage("psst", to: me, id: "dm-1", sentAt: now), from: carol)
        #expect(fixture.stores.messages.message("dm-1") == nil, "parked")
        fixture.transport.clear()
        #expect(fixture.engine.addContact(try card(of: bob), from: .link, unblock: false) == .added(bob.nodeId))
        #expect(fixture.stores.messages.message("dm-1")?.body == "psst")
        let receipts = try fixture.transport.written(.receipt).map { try ReceiptContent(decoding: $0.envelope.payload).ackId }
        #expect(receipts == ["dm-1"])
        #expect(!fixture.stores.custody.liveIds(now: fixture.clock.wallMilliseconds()).contains("dm-1"), "our receipt purged our copy")
    }
}
