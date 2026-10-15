import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// Our prekey on our profile, behind the ratchet's switch (ADR 2026-10.5sk9): minted and kept before any profile names
/// it, rotated weekly, republished at every toggle and rotation (`MeshManager.rotatePrekeyIfDue` and `finishRestore` in
/// knit-next), as an edit once the profile has been edited and at version 0 before that, and nothing of it on air while
/// the switch is off.
@Suite struct MeshEnginePrekeyTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let ratchetOn = MeshConfiguration(ratchet: true)
    private let week = PrekeyRing.rotationMilliseconds
    private let heal: Int64 = 900_000

    /// Our profile with the switch off, signed at a fixed stamp, as the engine wrote it before the ratchet's switch
    /// existed: these are the bytes that must not move.
    private let profileBeforeTheSwitch =
        "a564747970656770726f66696c65626964783070726f66696c652d736a6b6832376864376e61326e663735756e6264366b6d72636d2d"
        + "313735363139393939393030306873656e6465724964781a736a6b6832376864376e61326e663735756e6264366b6d72636d6673656e"
        + "7441741b00000198e5ad5618677061796c6f616458dfa8646e616d6565416c696365667374617475736661726f756e64667075624b65"
        + "7978706f6d5a7a6157645164574a59494f5144435a6a5031613058493846702b56617143353634595a745a6b7231684c4372304b4f76"
        + "486e3433775a3268776132565164574a5949425732435a4f4754656c7569674572414e5375577967666b583564446e6232704e69726a"
        + "7450344d6167616964657669636554616770303031313232333334343535363637376c70726f746f56657273696f6e016c6361706162"
        + "696c69746965730f6776657273696f6e076a6f70656e546f43686174f5"

    /// Alice's ring over a store that holds her identity, with prekeys minted at `minted`, and the store.
    private func ring(minted: [Int64] = []) throws -> (PrekeyRing, KeptSecretStore) {
        let store = KeptSecretStore(alice.keys.storedForm)
        var ring = try PrekeyRing.load(for: alice.keys, from: store)
        for stamp in minted {
            try ring.rotate(now: stamp)
        }
        return (ring, store)
    }

    /// The ids Alice's store keeps, newest first.
    private func kept(_ store: KeptSecretStore) throws -> [Int] {
        try PrekeyRing.load(for: alice.keys, from: store).prekeys.map(\.id)
    }

    /// Our profile as custody holds it for the current stamp.
    private func ourProfile(_ fixture: EngineFixture) throws -> ProfileContent {
        let id = "profile-\(alice.nodeId)-\(fixture.stores.ownProfile.load().publishedAt)"
        let held = try #require(fixture.stores.custody.frame(id, now: fixture.clock.wallMilliseconds()))
        return try ProfileContent(decoding: held.envelope.payload)
    }

    @Test func theSwitchAddsTheRatchetsThreeBitsToTheProfileAlone() {
        #expect(MeshConfiguration().ratchet == false)
        #expect(MeshConfiguration().capabilities == .local)
        #expect(ratchetOn.capabilities.rawValue == 0x15F)
        #expect(ratchetOn.capabilities == Capabilities.local.union([.ratchet, .inlineAck, .cryptoV3]))
        #expect(Capabilities.local.rawValue == 0xF, "the HELLO and the advert keep what they had")
    }

    @Test func withTheSwitchOffOurProfileIsTheBytesItWasAndNothingIsMinted() throws {
        let stamp = EngineFixture.start - 1000
        let own = OwnProfile(name: "Alice", status: "around", openToChat: true, version: 7, publishedAt: stamp)
        let (ring, store) = try ring(minted: [stamp])
        let before = store.contents
        let fixture = EngineFixture(alice, stores: .inMemory(ownProfile: own), prekeys: ring)
        let held = try #require(fixture.stores.custody.frame("profile-\(alice.nodeId)-\(stamp)", now: EngineFixture.start))
        #expect(Hex.encode(held.signed) == profileBeforeTheSwitch)
        #expect(fixture.stores.ownProfile.load() == own, "no edit, no new stamp")
        #expect(store.contents == before)
        fixture.advance(week)
        #expect(fixture.stores.ownProfile.load().prekeyId == nil)
        #expect(store.contents == before, "a heal with the switch off rotates nothing")
    }

    @Test func withTheSwitchOnOurProfileCarriesOurPrekeyAndTheBits() throws {
        let (ring, store) = try ring()
        let fixture = EngineFixture(alice, configuration: ratchetOn, prekeys: ring)
        let own = fixture.stores.ownProfile.load()
        #expect(own.prekeyId == 1)
        #expect(own.version == 0, "never edited, so the first prekey rides a republish, and no empty name goes out as an edit")
        #expect(own.publishedAt == EngineFixture.start)
        let content = try ourProfile(fixture)
        #expect(content.capabilities == 0x15F)
        let prekey = try #require(content.prekey)
        #expect(prekey.id == 1)
        #expect(PeerPrekey(verifying: prekey, signedBy: alice.keys.bundle)?.publicKey == prekey.pub)
        // Kept in the identity's store before the profile named it.
        #expect(try PrekeyRing.load(for: alice.keys, from: store).prekey(id: 1)?.publicKey == prekey.pub)
        #expect(fixture.log.all.contains("info mesh minted prekey 1"))
    }

    @Test func turningTheSwitchOffRepublishesWithoutThePrekeyAndKeepsTheKeys() throws {
        let earlier = EngineFixture.start - 1000
        let (ring, store) = try ring(minted: [earlier])
        let own = OwnProfile(name: "Alice", version: 5, publishedAt: earlier, prekeyId: 1)
        let fixture = EngineFixture(alice, stores: .inMemory(ownProfile: own), prekeys: ring)
        let after = fixture.stores.ownProfile.load()
        #expect(after.prekeyId == nil)
        #expect(after.version == EngineFixture.start)
        #expect(after.publishedAt == EngineFixture.start, "a new stamp, so no copy of the old payload takes its id")
        let content = try ourProfile(fixture)
        #expect(content.prekey == nil)
        #expect(content.capabilities == 0xF)
        #expect(try kept(store) == [1])
    }

    @Test func turningTheSwitchOnRepublishesWithTheKeptPrekey() throws {
        let earlier = EngineFixture.start - 1000
        let (ring, store) = try ring(minted: [earlier])
        let own = OwnProfile(name: "Alice", version: 5, publishedAt: earlier)
        let fixture = EngineFixture(alice, stores: .inMemory(ownProfile: own), configuration: ratchetOn, prekeys: ring)
        let after = fixture.stores.ownProfile.load()
        #expect(after.prekeyId == 1, "a prekey not yet due is published, not replaced")
        #expect(after.version == EngineFixture.start)
        #expect(after.publishedAt == EngineFixture.start)
        #expect(try ourProfile(fixture).prekey == ring.newest?.info)
        #expect(try kept(store) == [1])
    }

    @Test func aWeekOldPrekeyRotatesAtAHealAndTheEditFloods() throws {
        let (ring, store) = try ring()
        let own = OwnProfile(name: "Alice", version: 5, publishedAt: EngineFixture.start - 1000)
        let fixture = EngineFixture(alice, stores: .inMemory(ownProfile: own), configuration: ratchetOn, prekeys: ring)
        fixture.link(bob)
        fixture.transport.clear()
        fixture.advance(week - 1)
        #expect(fixture.stores.ownProfile.load().prekeyId == 1, "not quite a week")
        #expect(fixture.transport.written(.profile).isEmpty)
        fixture.advance(heal)
        let flooded = try #require(fixture.transport.written(.profile).first)
        #expect(flooded.to == nil, "a rotation floods, as an edit does")
        let content = try ProfileContent(decoding: flooded.envelope.payload)
        #expect(content.prekey?.id == 2)
        #expect(content.version == EngineFixture.start + week - 1 + heal)
        #expect(fixture.stores.ownProfile.load().prekeyId == 2)
        #expect(try kept(store) == [2, 1])
    }

    @Test func aHealMendsAProfileThatLostItsPrekey() throws {
        // The store's write landed and the publish did not, or a build before prekeys rewrote the row without its column.
        let (ring, _) = try ring()
        let published = OwnProfile(name: "Alice", version: 5, publishedAt: EngineFixture.start - 1000)
        let fixture = EngineFixture(alice, stores: .inMemory(ownProfile: published), configuration: ratchetOn, prekeys: ring)
        var own = fixture.stores.ownProfile.load()
        own.prekeyId = nil
        fixture.stores.ownProfile.save(own)
        fixture.advance(heal)
        let mended = fixture.stores.ownProfile.load()
        #expect(mended.prekeyId == 1)
        #expect(mended.version == EngineFixture.start + heal)
        #expect(try ourProfile(fixture).prekey?.id == 1)
    }

    @Test func aReinstallMintsAFreshPrekeyBeforeTheFirstPublishAndSendsNothingElse() throws {
        // The Keychain kept the identity and an hour-old prekey; the database, our profile among it, is new.
        let (ring, store) = try ring(minted: [EngineFixture.start - 3_600_000])
        let fixture = EngineFixture(alice, configuration: ratchetOn, prekeys: ring)
        #expect(try kept(store) == [2, 1])
        let own = fixture.stores.ownProfile.load()
        #expect(own.prekeyId == 2)
        #expect(own.version == 0, "no edit: onboarding has not published the name, and an empty one must not win")
        #expect(own.publishedAt == EngineFixture.start)
        #expect(try ourProfile(fixture).prekey?.id == 2)
        #expect(fixture.transport.written.isEmpty, "nothing flooded, and no resets: there is no peer list")
    }

    @Test func aReinstallWithTheSwitchOffMintsNothing() throws {
        let (ring, store) = try ring(minted: [EngineFixture.start - 3_600_000])
        let before = store.contents
        let fixture = EngineFixture(alice, prekeys: ring)
        #expect(store.contents == before)
        #expect(fixture.stores.ownProfile.load().prekeyId == nil)
    }

    @Test func aStoreThatRefusesLeavesTheProfileWithoutTheRatchetUntilAHealKeepsOne() throws {
        let (ring, store) = try ring()
        store.refusesWrites = true
        let fixture = EngineFixture(alice, configuration: ratchetOn, prekeys: ring)
        #expect(fixture.stores.ownProfile.load().prekeyId == nil)
        let content = try ourProfile(fixture)
        #expect(content.prekey == nil)
        #expect(content.capabilities == 0xF, "the bits and the prekey ride together, or neither does")
        #expect(fixture.log.all.contains { $0.hasPrefix("warning mesh kept no new prekey") })
        store.refusesWrites = false
        fixture.advance(heal)
        #expect(fixture.stores.ownProfile.load().prekeyId == 1)
        #expect(try ourProfile(fixture).capabilities == 0x15F)
    }

    @Test func withNoRingTheSwitchPublishesNoPrekeyAndNoBits() throws {
        let fixture = EngineFixture(alice, configuration: ratchetOn)
        let content = try ourProfile(fixture)
        #expect(content.prekey == nil)
        #expect(content.capabilities == 0xF)
        #expect(fixture.stores.ownProfile.load().prekeyId == nil)
    }

    @Test func anotherEnginePinsThePrekeyWePublishAndDropsItWhenTheSwitchGoesOff() throws {
        // Both sides of the pair in this port: Alice publishes, and Bob's engine, its switch off, takes it in.
        let (ring, store) = try ring()
        let ours = EngineFixture(alice, configuration: ratchetOn, prekeys: ring)
        let theirs = EngineFixture(bob)
        ours.link(bob)
        let pushed = try #require(ours.transport.written(.profile).last)
        theirs.deliver(TestFrame(wire: pushed.wire, envelope: pushed.envelope), from: alice)
        let published = try PrekeyRing.load(for: alice.keys, from: store).newest?.info
        let pinned = try #require(theirs.stores.peers.peer(alice.nodeId))
        #expect(pinned.prekey == published)
        #expect(pinned.prekey != nil)
        #expect(pinned.capabilities == 0x15F)
        #expect(pinned.prekeyProfileAt == ours.stores.ownProfile.load().version)
        // Alice starts again with her switch off, her profile still never edited: a new stamp with no prekey, which Bob
        // takes at version 0, and his pin clears. The frame that carried the bits is not pushed again.
        let off = EngineFixture(alice, stores: ours.stores, prekeys: ring)
        #expect(off.stores.ownProfile.load().version == 0)
        off.link(bob)
        let plain = try #require(off.transport.written(.profile).last)
        theirs.deliver(TestFrame(wire: plain.wire, envelope: plain.envelope), from: alice)
        let cleared = try #require(theirs.stores.peers.peer(alice.nodeId))
        #expect(cleared.prekey == nil)
        #expect(cleared.prekeyProfileAt == off.stores.ownProfile.load().version)
        #expect(cleared.capabilities == 0xF)
    }

    @Test func aRingAnotherIdentitySignsIsNotThisNodes() throws {
        let store = KeptSecretStore(bob.keys.storedForm)
        let theirs = try PrekeyRing.load(for: bob.keys, from: store)
        let fixture = EngineFixture(alice, configuration: ratchetOn, prekeys: theirs)
        #expect(store.contents == bob.keys.storedForm, "nothing minted into someone else's store")
        #expect(try ourProfile(fixture).prekey == nil)
    }
}
