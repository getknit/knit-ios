import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// Our profile and everyone else's (`MeshManager.ownProfile`, `broadcastProfile`, `republishProfile` and
/// `InboundPipeline.handleProfile` in knit-next).
@Suite struct MeshEngineProfileTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)

    private func ourProfileId(_ fixture: EngineFixture) -> String {
        "profile-\(fixture.me.nodeId)-\(fixture.stores.ownProfile.load().publishedAt)"
    }

    @Test func startPutsAFreshlyStampedProfileInCustody() throws {
        let fixture = EngineFixture(alice)
        #expect(fixture.stores.ownProfile.load().publishedAt == EngineFixture.start, "a fresh identity's stamp of 0 is stale")
        let held = try #require(fixture.stores.custody.frame(ourProfileId(fixture), now: EngineFixture.start))
        let content = try ProfileContent(decoding: held.envelope.payload)
        let expected = ProfileContent(
            name: "",
            status: "",
            pubKey: alice.keys.bundle.encoded,
            deviceTag: "0011223344556677",
            protoVersion: 1,
            capabilities: 0xF,
            version: 0
        )
        #expect(content == expected, "every required field, status included, or Android never pins our key")
        #expect(held.envelope.sentAt == EngineFixture.start)
        #expect(alice.keys.bundle.isValidSignature(held.sig, for: held.signed))
        #expect(fixture.stores.messages.messages(in: Conversations.nearby).isEmpty)
    }

    @Test func startIsIdempotent() {
        let fixture = EngineFixture(alice)
        let before = fixture.stores.custody.liveIds(now: EngineFixture.start)
        fixture.engine.start()
        #expect(fixture.stores.custody.liveIds(now: EngineFixture.start) == before)
    }

    @Test func aNewLinkGetsOurProfileThenOurDigest() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        let pushed = fixture.transport.written(.profile)
        #expect(pushed.map(\.to) == [bob.nodeId])
        #expect(pushed.map(\.envelope.id) == [ourProfileId(fixture)])
        #expect(fixture.transport.digests.map(\.to) == [bob.nodeId])
        #expect(fixture.transport.digests.first?.ids == [ourProfileId(fixture)])
    }

    @Test func theProfileIsSignedOnceForEachStamp() {
        let fixture = EngineFixture(alice)
        let carol = TestPeer(seed: 3)
        fixture.link(bob, carol)
        let pushed = fixture.transport.written(.profile).map(\.wire)
        #expect(pushed.count == 2)
        #expect(pushed.first == pushed.last, "the same bytes to everyone")
    }

    @Test func anEditFloodsANewFrameWithANewVersion() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        let oldId = ourProfileId(fixture)
        fixture.transport.clear()
        fixture.clock.advance(5000)
        fixture.engine.updateProfile(name: "  Alice   Liddell ", status: "Looking-glass", openToChat: true)
        let flooded = try #require(fixture.transport.written(.profile).first)
        #expect(flooded.to == nil, "an edit floods")
        #expect(flooded.envelope.id == ourProfileId(fixture))
        #expect(flooded.envelope.id != oldId)
        let content = try ProfileContent(decoding: flooded.envelope.payload)
        #expect(content.name == "Alice Liddell", "normalized, as knit-next normalizes it")
        #expect(content.status == "Looking-glass")
        #expect(content.openToChat)
        #expect(content.version == EngineFixture.start + 5000)
        let now = fixture.clock.wallMilliseconds()
        #expect(fixture.stores.custody.frame(oldId, now: now) != nil, "the old stamp lingers until its own TTL")
        #expect(fixture.stores.custody.frame(flooded.envelope.id, now: now) != nil)
    }

    @Test func twoEditsInOneMillisecondStillGetTwoStamps() {
        let fixture = EngineFixture(alice)
        fixture.engine.updateProfile(name: "A", status: "", openToChat: false)
        let first = fixture.stores.ownProfile.load()
        fixture.engine.updateProfile(name: "B", status: "", openToChat: false)
        let second = fixture.stores.ownProfile.load()
        #expect(second.publishedAt == first.publishedAt + 1)
        #expect(second.version == first.version + 1)
    }

    @Test func aStaleStampIsRepublishedWithTheSameVersion() {
        let fixture = EngineFixture(alice)
        fixture.engine.updateProfile(name: "Alice", status: "", openToChat: false)
        let edited = fixture.stores.ownProfile.load()
        fixture.transport.clear()
        fixture.advance(12 * 3_600_000 - 1)
        #expect(fixture.stores.ownProfile.load().publishedAt == edited.publishedAt, "not quite 12 hours")
        fixture.advance(900_000)
        let republished = fixture.stores.ownProfile.load()
        #expect(republished.publishedAt == fixture.clock.wallMilliseconds())
        #expect(republished.version == edited.version, "a republish is not an edit")
        #expect(fixture.transport.written(.profile).isEmpty, "custody carries it; nothing floods")
        #expect(fixture.stores.custody.frame(ourProfileId(fixture), now: fixture.clock.wallMilliseconds()) != nil)
    }

    @Test func aFirstProfilePinsTheKeyAndClampsTheText() throws {
        let fixture = EngineFixture(alice)
        let longName = String(repeating: "😀", count: 20)
        let profile = try bob.profile(name: longName, version: 5, publishedAt: EngineFixture.start)
        fixture.deliver(profile, from: bob)
        let peer = try #require(fixture.stores.peers.peer(bob.nodeId))
        #expect(peer.publicKey == bob.keys.bundle.encoded)
        #expect(peer.name.utf16.count == 32, "16 emoji: the name limit counts UTF-16 units")
        #expect(peer.updatedAt == 5)
        #expect(peer.capabilities == 0xFFF)
        #expect(fixture.engine.drainEvents() == [.peerUpdated(bob.nodeId)])
    }

    @Test func anOlderProfileIsIgnoredAndANewerOneApplies() throws {
        let fixture = EngineFixture(alice)
        fixture.deliver(try bob.profile(name: "New", version: 20, publishedAt: EngineFixture.start), from: bob)
        fixture.deliver(try bob.profile(name: "Old", version: 10, publishedAt: EngineFixture.start + 1), from: bob)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.name == "New")
        fixture.deliver(try bob.profile(name: "Newer", version: 30, publishedAt: EngineFixture.start + 2), from: bob)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.name == "Newer")
    }

    @Test func aProfileWithNoVersionOrdersBySentAt() throws {
        let fixture = EngineFixture(alice)
        fixture.deliver(try bob.profile(name: "Later", publishedAt: EngineFixture.start), from: bob)
        fixture.deliver(try bob.profile(name: "Earlier", publishedAt: EngineFixture.start - 60_000), from: bob)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.name == "Later")
    }

    @Test func aFarFutureVersionIsClampedSoItCannotWedgeTheWatermark() throws {
        let fixture = EngineFixture(alice)
        fixture.deliver(try bob.profile(name: "Wedge", version: .max, publishedAt: EngineFixture.start), from: bob)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.updatedAt == EngineFixture.start + WireProtocol.maxFutureSkewMilliseconds)
        fixture.clock.advance(WireProtocol.maxFutureSkewMilliseconds + 1)
        let honest = try bob.profile(name: "Honest", version: fixture.clock.wallMilliseconds(), publishedAt: EngineFixture.start + 1)
        fixture.deliver(honest, from: bob)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.name == "Honest")
    }

    @Test func aPinnedKeyNeverChanges() throws {
        let stores = MeshStores.inMemory()
        let impostorKey = TestPeer(seed: 9).keys.bundle.encoded
        stores.peers.upsert(PeerRecord(nodeId: bob.nodeId, name: "Pinned", status: "", publicKey: impostorKey, updatedAt: 0))
        let fixture = EngineFixture(alice, stores: stores)
        fixture.deliver(try bob.profile(name: "Swap", version: 1, publishedAt: EngineFixture.start), from: bob)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.publicKey == impostorKey)
        #expect(fixture.stores.peers.peer(bob.nodeId)?.name == "Pinned")
        #expect(fixture.engine.dropped[.pinChangeRefused] == 1)
    }

    @Test func aProfileWhoseKeyDerivesElsewhereIsDropped() throws {
        let fixture = EngineFixture(alice)
        let content = ProfileContent(name: "Liar", status: "", pubKey: TestPeer(seed: 9).keys.bundle.encoded)
        let envelope = RelayEnvelope(
            type: .profile,
            id: "profile-\(bob.nodeId)-1",
            senderId: bob.nodeId.string,
            sentAt: EngineFixture.start,
            payload: content.encoded
        )
        fixture.deliver(try bob.signed(envelope), from: bob)
        #expect(fixture.stores.peers.peer(bob.nodeId) == nil)
        #expect(fixture.engine.dropped[.keyMismatch] == 1)
    }

    @Test func aProfileWithNoKeyIsDroppedWithoutAKeyRequest() throws {
        let fixture = EngineFixture(alice)
        fixture.link(TestPeer(seed: 3))
        fixture.transport.clear()
        let envelope = RelayEnvelope(
            type: .profile,
            id: "profile-\(bob.nodeId)-1",
            senderId: bob.nodeId.string,
            sentAt: EngineFixture.start,
            payload: ProfileContent(name: "Keyless", status: "").encoded
        )
        fixture.deliver(try bob.signed(envelope), from: bob)
        #expect(fixture.engine.dropped[.noSenderKey] == 1)
        #expect(fixture.transport.written(.keyRequest).isEmpty, "a profile carries its own key")
    }

    @Test func ourOwnProfileComingBackIsCarriedButNotPinned() throws {
        let fixture = EngineFixture(alice)
        let echo = try alice.profile(name: "Me", publishedAt: EngineFixture.start - 10)
        fixture.deliver(echo, from: bob)
        #expect(fixture.stores.peers.peer(alice.nodeId) == nil)
        #expect(fixture.stores.custody.contains(echo.envelope.id))
    }

    @Test func aProfileServedPointToPointIsStillCarried() throws {
        // A key request's answer arrives with relay = false; knit-next's ADR 2026-09.7bu7 carries it anyway.
        let fixture = EngineFixture(alice)
        let served = try bob.profile(publishedAt: EngineFixture.start, relay: false)
        fixture.deliver(served, from: TestPeer(seed: 3))
        #expect(fixture.stores.custody.contains(served.envelope.id))
        #expect(fixture.stores.peers.peer(bob.nodeId) != nil)
    }

    @Test func aServedProfileCustodyRefusesAsDeadOnArrivalStillPins() throws {
        // The pin path has no age check, so a key sent ahead of a backlog pins even when its frame has expired, and
        // the digests stay convergent: every node refuses that frame alike (knit-next ADR 2026-09.g64k).
        let fixture = EngineFixture(alice)
        let expired = try bob.profile(publishedAt: EngineFixture.start - CustodyLimits().ttlMilliseconds - 1, relay: false)
        fixture.deliver(expired, from: TestPeer(seed: 3))
        #expect(!fixture.stores.custody.contains(expired.envelope.id))
        #expect(fixture.stores.peers.peer(bob.nodeId)?.publicKey == bob.keys.bundle.encoded)
    }

    // MARK: The proof of key (knit-next ADR 2026-09.g64k)

    @Test func aPinnedProfileIsKeptVerbatimAsItsSendersProofOfKey() throws {
        let fixture = EngineFixture(alice)
        let profile = try bob.profile(publishedAt: EngineFixture.start)
        fixture.deliver(profile, from: bob)
        let kept = try #require(fixture.stores.peers.profileFrame(of: bob.nodeId))
        #expect(kept == WireEnvelope(relay: false, sig: profile.wire.sig, signed: profile.wire.signed))
    }

    @Test func theNewestPublishStampIsKeptWhateverTheArrivalOrder() throws {
        // A republish keeps the version and moves the stamp; an older copy re-served later passes the version check
        // and still never replaces the newer proof.
        let fixture = EngineFixture(alice)
        let older = try bob.profile(version: 1, publishedAt: EngineFixture.start - 2)
        let newer = try bob.profile(version: 1, publishedAt: EngineFixture.start - 1)
        fixture.deliver(newer, from: bob)
        fixture.deliver(older, from: bob)
        #expect(fixture.stores.peers.profileFrame(of: bob.nodeId)?.signed == newer.wire.signed)
    }

    @Test func aFarFutureStampIsClampedSoItCannotWedgeTheProof() throws {
        // The peer picks the stamp. Unclamped, one stamped at the end of time would outrank every honest copy after it.
        let fixture = EngineFixture(alice)
        fixture.deliver(try bob.profile(version: 1, publishedAt: .max), from: bob)
        fixture.clock.advance(WireProtocol.maxFutureSkewMilliseconds + 1)
        let now = fixture.clock.wallMilliseconds()
        let honest = try bob.profile(version: now, publishedAt: now)
        fixture.deliver(honest, from: bob)
        #expect(fixture.stores.peers.profileFrame(of: bob.nodeId)?.signed == honest.wire.signed)
    }

    @Test func aProfileThatPinsNothingKeepsNoProofOfKey() throws {
        // Never our own, never one refusing a pinned key, never one older than the pin's watermark.
        let stores = MeshStores.inMemory()
        let carol = TestPeer(seed: 3)
        stores.peers.upsert(
            PeerRecord(nodeId: bob.nodeId, name: "", status: "", publicKey: TestPeer(seed: 9).keys.bundle.encoded, updatedAt: 0))
        stores.peers.upsert(PeerRecord(nodeId: carol.nodeId, name: "", status: "", publicKey: carol.keys.bundle.encoded, updatedAt: 100))
        let fixture = EngineFixture(alice, stores: stores)
        fixture.deliver(try alice.profile(name: "Me", publishedAt: EngineFixture.start - 10), from: bob)
        fixture.deliver(try bob.profile(version: 1, publishedAt: EngineFixture.start), from: bob)
        fixture.deliver(try carol.profile(version: 6, publishedAt: EngineFixture.start), from: carol)
        #expect([alice, bob, carol].allSatisfy { stores.peers.profileFrame(of: $0.nodeId) == nil })
    }
}
