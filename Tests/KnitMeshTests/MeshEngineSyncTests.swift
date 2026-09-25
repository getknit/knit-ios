import KnitMesh
import KnitStore
import KnitWire
import Testing

/// Verification, custody exchange, key recovery and the timers (`InboundPipeline.verifyInbound`,
/// `ForwardSync.onDigest`, `KeyExchange` and `MeshManager.reofferToNeighborsPeriodically`).
@Suite struct MeshEngineSyncTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    @Test func aBadSignatureIsDroppedAndNotCarriedButStillRelayed() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        fixture.transport.clear()
        var post = try bob.roomPost("Tampered", id: "post-1", sentAt: EngineFixture.start)
        post.wire.sig[0] ^= 0xFF
        fixture.deliver(post, from: bob)
        #expect(fixture.engine.dropped[.badSignature] == 1)
        #expect(!fixture.stores.custody.contains("post-1"))
        #expect(fixture.stores.messages.message("post-1") == nil)
        fixture.advance(150)
        #expect(fixture.transport.written(.chat).map(\.to) == [carol.nodeId], "a relay that drops what it cannot read is a black hole")
    }

    @Test func anUnsignedChatIsDropped() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let post = try bob.roomPost("Unsigned", id: "post-2", sentAt: EngineFixture.start)
        let unsigned = WireEnvelope(sig: [], signed: post.wire.signed)
        fixture.engine.receive(InboundFrame(wire: unsigned, envelope: post.envelope, from: bob.nodeId))
        #expect(fixture.engine.dropped[.unsigned] == 1)
    }

    @Test func anUndecodablePayloadIsDroppedQuietly() throws {
        let fixture = EngineFixture(alice)
        try fixture.pin(bob)
        let envelope = RelayEnvelope(type: .chat, id: "junk", senderId: bob.nodeId.string, sentAt: EngineFixture.start, payload: [0xFF])
        fixture.deliver(try bob.signed(envelope), from: bob)
        #expect(fixture.engine.dropped[.undecodable] == 1)
        #expect(!fixture.stores.custody.contains("junk"), "a room post that does not decode is not carried")
    }

    @Test func ourOwnFrameComingBackVerifiesWithOurKey() throws {
        // How a node whose custody was wiped carries its own frames again.
        let stores = MeshStores.inMemory()
        let fixture = EngineFixture(alice, stores: stores)
        let mine = try alice.roomPost("Mine", id: "mine-1", sentAt: EngineFixture.start)
        fixture.deliver(mine, from: bob)
        #expect(stores.custody.contains("mine-1"))
        #expect(stores.custody.frame("mine-1", now: EngineFixture.start)?.signed == mine.wire.signed)
    }

    @Test func aDigestIsAnsweredWithWhatThePeerLacks() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        let post = try #require(fixture.engine.postToRoom("Back-fill me"))
        fixture.transport.clear()
        let profileId = "profile-\(alice.nodeId)-\(EngineFixture.start)"
        fixture.engine.receiveDigest([profileId], from: bob.nodeId)
        let served = fixture.transport.written
        #expect(served.map(\.envelope.id) == [post.id])
        #expect(served.map(\.to) == [bob.nodeId])
        #expect(served.first?.wire == WireEnvelope(sig: served[0].wire.sig, signed: served[0].wire.signed), "a fresh hop budget")
    }

    @Test func everyLinkedNeighbourGetsOurDigestEveryMinute() {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        fixture.transport.clear()
        fixture.advance(59_999)
        #expect(fixture.transport.digests.isEmpty)
        fixture.advance(1)
        #expect(Set(fixture.transport.digests.map(\.to)) == [bob.nodeId, carol.nodeId])
        fixture.advance(60_000)
        #expect(fixture.transport.digests.count == 4)
    }

    @Test func expiredCustodyIsSweptOnTheTenMinuteTimer() throws {
        let fixture = EngineFixture(alice)
        let post = try #require(fixture.engine.postToRoom("Short-lived"))
        #expect(fixture.stores.custody.contains(post.id))
        fixture.clock.advance(CustodyLimits().roomChatTTLMilliseconds + 1)
        #expect(fixture.stores.custody.contains(post.id), "expired but not swept yet")
        let revision = fixture.engine.custodyRevision
        fixture.advance(600_000)
        #expect(!fixture.stores.custody.contains(post.id))
        #expect(fixture.engine.custodyRevision > revision)
    }

    @Test func aKeyRequestIsServedFromTheCachedProfile() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        try fixture.pin(carol)
        let profile = try bob.profile(publishedAt: EngineFixture.start)
        fixture.deliver(profile, from: bob)
        fixture.transport.clear()
        fixture.deliver(try carol.keyRequest(for: [bob.nodeId], id: "req-1"), from: carol)
        let served = try #require(fixture.transport.written(.profile).first)
        #expect(served.to == carol.nodeId)
        #expect(!served.wire.relay)
        #expect(served.wire.signed == profile.wire.signed && served.wire.sig == profile.wire.sig, "verbatim")
    }

    @Test func aKeyRequestWeCannotAnswerIsAskedOnAndAnsweredLater() throws {
        let fixture = EngineFixture(alice)
        let dave = TestPeer(seed: 4)
        fixture.link(carol, dave)
        try fixture.pin(carol)
        fixture.transport.clear()
        fixture.deliver(try carol.keyRequest(for: [bob.nodeId], id: "req-2"), from: carol)
        let asked = fixture.transport.written(.keyRequest)
        #expect(Set(asked.map(\.to)) == [carol.nodeId, dave.nodeId])
        #expect(asked.allSatisfy { !$0.wire.relay })
        fixture.transport.clear()
        fixture.deliver(try bob.profile(publishedAt: EngineFixture.start), from: dave)
        let served = fixture.transport.written(.profile).filter { !$0.wire.relay }
        #expect(served.map(\.to) == [carol.nodeId])
    }

    @Test func aKeyRequestFromAnUnpinnedPeerIsRefused() throws {
        // A request verifies against the asker's pinned key; neighbours swap profiles at link-up, so it is there.
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        fixture.deliver(try bob.profile(publishedAt: EngineFixture.start), from: bob)
        fixture.transport.clear()
        fixture.deliver(try carol.keyRequest(for: [bob.nodeId], id: "req-0"), from: carol)
        #expect(fixture.transport.written(.profile).isEmpty)
        #expect(fixture.engine.dropped[.noSenderKey] == 1)
    }

    @Test func aKeyRequestIsNeverRelayed() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol, TestPeer(seed: 4))
        try fixture.pin(carol)
        fixture.transport.clear()
        fixture.deliver(try carol.keyRequest(for: [alice.nodeId], id: "req-3"), from: carol)
        fixture.advance(1000)
        #expect(fixture.transport.written(.keyRequest).isEmpty, "a request for our own key is skipped, and never flooded")
    }

    @Test func aNewNeighbourIsAskedForEveryKeyStillMissing() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        fixture.deliver(try bob.roomPost("Who?", id: "post-3", sentAt: EngineFixture.start), from: carol)
        fixture.transport.clear()
        let dave = TestPeer(seed: 4)
        fixture.link(dave)
        let asked = fixture.transport.written(.keyRequest)
        #expect(asked.map(\.to) == [dave.nodeId])
        #expect(try KeyRequestContent(decoding: asked[0].envelope.payload).nodeIds == [bob.nodeId.string])
    }

    @Test func aMissingKeyIsAskedForAgainWithinTheCooldownOnlyByTheHealPass() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        fixture.deliver(try bob.roomPost("One", id: "post-4", sentAt: EngineFixture.start), from: carol)
        fixture.deliver(try bob.roomPost("Two", id: "post-5", sentAt: EngineFixture.start), from: carol)
        #expect(fixture.transport.written(.keyRequest).count == 1, "the cooldown holds a burst to one request")
        fixture.transport.clear()
        fixture.advance(900_000)
        #expect(fixture.transport.written(.keyRequest).map(\.to).contains(carol.nodeId))
    }

    @Test func nothingIsScheduledBeforeStart() {
        let fixture = EngineFixture(alice, started: false)
        #expect(fixture.engine.nextDeadline == nil)
        #expect(!fixture.engine.isStarted)
        fixture.advance(1_000_000)
        #expect(fixture.transport.digests.isEmpty)
        fixture.engine.start()
        #expect(fixture.engine.nextDeadline == fixture.clock.monotonicMilliseconds() + 60_000)
    }

    @Test func thePendingRelayIsTheNextDeadline() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        let now = fixture.clock.monotonicMilliseconds()
        let deadline = try #require(fixture.engine.nextDeadline)
        #expect(deadline >= now && deadline < now + 150)
    }

    @Test func linkChangesAreAnnounced() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.transport.neighbors.removeAll()
        fixture.engine.linkDown(bob.nodeId)
        #expect(fixture.engine.drainEvents() == [.neighborsChanged([Neighbor(nodeId: bob.nodeId)]), .neighborsChanged([])])
    }

    @Test func theDigestCueFoldsTheLiveIds() {
        let fixture = EngineFixture(alice)
        let ids = fixture.stores.custody.liveIds(now: EngineFixture.start)
        #expect(fixture.engine.digestCue == UInt32(truncatingIfNeeded: StoreDigest.fingerprint(of: ids)))
        #expect(fixture.engine.digestCue != 0)
    }

    @Test func theSilentLogKeepsNothing() {
        // The default log for the Linux peer and anywhere nothing reads the log.
        let engine = MeshEngine(
            identity: alice.keys,
            deviceTag: nil,
            stores: .inMemory(),
            transport: RecordingTransport(),
            clock: ManualClock(wall: EngineFixture.start, monotonic: 0),
            random: SeededGenerator(seed: 1)
        )
        engine.start()
        engine.linkDown(bob.nodeId)
        #expect(engine.isStarted)
    }
}
