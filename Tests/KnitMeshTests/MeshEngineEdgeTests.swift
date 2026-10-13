import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// Frames this build carries and relays but never shows, frames it cannot open, and the edges of its profile cache.
/// Blob requests, reactions and typing cues have suites of their own (`MeshEngineBlobTests`, `MeshEngineReactionTests`,
/// `MeshEngineTypingTests`).
@Suite struct MeshEngineEdgeTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    private func received(_ events: [MeshEvent]) -> [String] {
        events.compactMap { event in
            guard case .received(let record, _) = event else {
                return nil
            }
            return record.id
        }
    }

    @Test func aFrameOfATypeThisBuildHasNeverHeardOfIsRelayedAndShownNowhere() throws {
        // A newer build's type: not custodial here, so not carried, and dropped without a word, but still flooded on.
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        fixture.advance(1000)
        fixture.transport.clear()
        _ = fixture.engine.drainEvents()
        let future = RelayEnvelope(type: FrameType(rawValue: "future"), id: "future-1", senderId: bob.nodeId.string, payload: [0xA0])
        fixture.deliver(try bob.signed(future), from: bob)
        #expect(!fixture.stores.custody.contains("future-1"))
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.engine.dropped.isEmpty)
        fixture.advance(1000)
        #expect(fixture.transport.written(FrameType(rawValue: "future")).map(\.to) == [carol.nodeId])
    }

    @Test func aSealedRoomPostCannotBeOpened() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let sealed = EncEnvelope(nonce: Array(repeating: 1, count: 12), ct: Array(repeating: 2, count: 32), keys: [])
        let envelope = RelayEnvelope(
            type: .chat,
            id: "room-sealed",
            senderId: bob.nodeId.string,
            sentAt: EngineFixture.start,
            payload: ChatContent(enc: sealed).encoded
        )
        fixture.deliver(try bob.signed(envelope), from: bob)
        #expect(fixture.engine.dropped[.cannotOpen] == 1)
    }

    @Test func aDMAddressedToUsButSealedForSomeoneElseCannotBeOpened() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        _ = fixture.engine.drainEvents()
        let forCarol = try bob.directMessage("Not yours", to: carol, id: "dm-x", sentAt: EngineFixture.start)
        var envelope = forCarol.envelope
        envelope.recipientId = alice.nodeId.string
        fixture.deliver(try bob.signed(envelope), from: bob)
        #expect(received(fixture.engine.drainEvents()).isEmpty)
        #expect(fixture.engine.dropped[.cannotOpen] == 1)
    }

    @Test func receiptsAndKeyRequestsThatDoNotDecodeAreDropped() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let receipt = RelayEnvelope(type: .receipt, id: "r-bad", senderId: bob.nodeId.string, sentAt: EngineFixture.start, payload: [0xFF])
        let request = RelayEnvelope(type: .keyRequest, id: "k-bad", senderId: bob.nodeId.string, payload: [0xFF])
        fixture.deliver(try bob.signed(receipt), from: bob)
        fixture.deliver(try bob.signed(request, relay: false), from: bob)
        #expect(fixture.engine.dropped[.undecodable] == 2)
    }

    @Test func aProfileMissingOptionalFieldsKeepsWhatWasKnown() throws {
        let fixture = EngineFixture(alice)
        fixture.deliver(try bob.profile(name: "Full", version: 1, publishedAt: EngineFixture.start), from: bob)
        let sparse = ProfileContent(name: "Sparse", status: "", pubKey: bob.keys.bundle.encoded, version: 2)
        let envelope = RelayEnvelope(
            type: .profile,
            id: "profile-\(bob.nodeId)-\(EngineFixture.start + 1)",
            senderId: bob.nodeId.string,
            sentAt: EngineFixture.start + 1,
            payload: sparse.encoded
        )
        fixture.deliver(try bob.signed(envelope), from: bob)
        let peer = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(peer.name == "Sparse")
        #expect(peer.capabilities == 0xFFF && peer.protocolVersion == 1)
    }

    @Test func ourProfilePushedAfterCustodyEvictedItIsTheSameBytes() throws {
        // A busy node's own posts can push its profile out of its own sender bucket; the push must not re-sign.
        let stores = MeshStores.inMemory(custodyLimits: CustodyLimits(maxPerSender: 3))
        let fixture = EngineFixture(alice, stores: stores)
        fixture.link(bob)
        let first = try #require(fixture.transport.written(.profile).first?.wire)
        for index in 0..<3 {
            fixture.clock.advance(1)
            fixture.engine.postToRoom("Post \(index)")
        }
        let profileId = "profile-\(alice.nodeId)-\(EngineFixture.start)"
        #expect(!stores.custody.contains(profileId), "evicted by our own newer posts")
        fixture.transport.clear()
        fixture.link(carol)
        #expect(fixture.transport.written(.profile).first?.wire == first)
    }

    @Test func theLogSaysWhatHappened() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        var post = try carol.roomPost("Unknown sender", id: "post-1", sentAt: EngineFixture.start)
        post.wire.sig[0] ^= 1
        fixture.deliver(post, from: bob)
        fixture.transport.neighbors.removeAll()
        fixture.engine.linkDown(bob.nodeId)
        let lines = fixture.log.all
        #expect(lines.contains("info mesh link up \(bob.nodeId)"))
        #expect(lines.contains("info mesh link down \(bob.nodeId)"))
        #expect(lines.contains("debug mesh drop chat post-1 from \(carol.nodeId): noSenderKey"))
    }

    @Test func aPinChangeIsLoggedAsAWarning() throws {
        let stores = MeshStores.inMemory()
        stores.peers.upsert(PeerRecord(nodeId: bob.nodeId, name: "", status: "", publicKey: carol.keys.bundle.encoded, updatedAt: 0))
        let fixture = EngineFixture(alice, stores: stores)
        fixture.deliver(try bob.profile(publishedAt: EngineFixture.start), from: bob)
        #expect(fixture.log.all.contains("warning mesh refused a key change for pinned \(bob.nodeId)"))
    }
}
