import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The engine's half of a link's proof (knit-ios #25, the `link-hello-proof` contract): a peer whose signed profile carries
/// ``Capabilities/linkProof`` is one every link claiming its id must prove, so the bit must not be taken back by an older
/// frame (§7), and its gain tells the transport (R4).
///
/// - A peer's capabilities follow the presentation's watermark, as knit-next's `InboundPipeline` now writes them: a
///   profile older than the presentation the row holds, re-served or replayed, leaves them, even when it is new on the
///   prekey's own watermark.
/// - Our own profile is published again as an edit when the capabilities it would carry differ from those its last
///   publish recorded, so every profile from before is strictly older than the first with the new bit.
@Suite struct MeshEngineLinkProofCapabilityTests {
    private let me = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let dave = TestPeer(seed: 4)
    private var now: Int64 { EngineFixture.start }

    /// Every bit through `CAP_CRYPTO_V3`, as Android 2.10.1 signs, and the same with the link-proof bit, as an upgraded one does.
    private static let before: Int64 = 0x15F
    private static let upgraded: Int64 = 0x4015F

    private func capabilities(of peer: TestPeer, in fixture: EngineFixture) -> Int64? {
        fixture.stores.peers.peer(peer.nodeId)?.capabilities
    }

    // MARK: R4: a gain tells the transport

    @Test func aFirstProfileCarryingTheBitTellsTheTransportOnce() throws {
        let fixture = EngineFixture(me)
        fixture.deliver(try bob.profile(version: 5, publishedAt: now, capabilities: Self.upgraded), from: bob)
        #expect(fixture.transport.provesItself == [bob.nodeId])
        #expect(capabilities(of: bob, in: fixture) == Self.upgraded)
        fixture.deliver(try bob.profile(version: 6, publishedAt: now + 1, capabilities: Self.upgraded), from: bob)
        #expect(fixture.transport.provesItself == [bob.nodeId], "a row that keeps the bit gains nothing")
    }

    @Test func aProfileWithoutTheBitTellsNothing() throws {
        let fixture = EngineFixture(me)
        fixture.deliver(try bob.profile(version: 5, publishedAt: now, capabilities: Self.before), from: bob)
        fixture.deliver(try bob.profile(version: 6, publishedAt: now + 1, capabilities: Self.before), from: bob)
        #expect(fixture.transport.provesItself.isEmpty)
    }

    @Test func anUpgradeTellsTheTransportWhenTheBitArrives() throws {
        let fixture = EngineFixture(me)
        fixture.deliver(try bob.profile(version: 5, publishedAt: now, capabilities: Self.before), from: bob)
        #expect(fixture.transport.provesItself.isEmpty)
        fixture.deliver(try bob.profile(version: 6, publishedAt: now + 1, capabilities: Self.upgraded), from: bob)
        #expect(fixture.transport.provesItself == [bob.nodeId])
    }

    @Test func aBitStrippedByANewerProfileAndRegainedTellsAgain() throws {
        let fixture = EngineFixture(me)
        fixture.deliver(try bob.profile(version: 5, publishedAt: now, capabilities: Self.upgraded), from: bob)
        fixture.deliver(try bob.profile(version: 6, publishedAt: now + 1, capabilities: Self.before), from: bob)
        #expect(capabilities(of: bob, in: fixture) == Self.before, "a downgrade at a newer version clears it")
        fixture.deliver(try bob.profile(version: 7, publishedAt: now + 2, capabilities: Self.upgraded), from: bob)
        #expect(fixture.transport.provesItself == [bob.nodeId, bob.nodeId])
    }

    @Test func aBlockedSendersBitStillMovesAndTells() throws {
        // A block holds what a person presents, never what the mesh relies on (ADR 2026-11.y793).
        let fixture = EngineFixture(me)
        fixture.engine.block(bob.nodeId)
        fixture.deliver(try bob.profile(version: 5, publishedAt: now, capabilities: Self.upgraded), from: bob)
        #expect(capabilities(of: bob, in: fixture) == Self.upgraded)
        #expect(fixture.transport.provesItself == [bob.nodeId])
    }

    @Test func ourOwnProfileComingBackTellsNothing() throws {
        let fixture = EngineFixture(me)
        fixture.deliver(try me.profile(version: 5, publishedAt: now, capabilities: Self.upgraded), from: bob)
        #expect(fixture.transport.provesItself.isEmpty)
    }

    // MARK: §7: the bit cannot be taken back by an older frame

    @Test func aProfileFromBeforeTheUpgradeLandingAfterTheBumpedOneLeavesTheBitSet() throws {
        // Bob's old build published at version 5, and its 12-hour republishes kept that version under new stamps. His
        // upgraded build's first start bumped it to 6 with the bit. A version-5 copy custody still holds lands after.
        let fixture = EngineFixture(me)
        fixture.deliver(try bob.profile(version: 5, publishedAt: now - 2000, capabilities: Self.before), from: bob)
        fixture.deliver(try bob.profile(version: 6, publishedAt: now, capabilities: Self.upgraded), from: bob)
        fixture.deliver(try bob.profile(version: 5, publishedAt: now - 1000, capabilities: Self.before), from: bob)
        #expect(capabilities(of: bob, in: fixture) == Self.upgraded)
        #expect(fixture.transport.provesItself == [bob.nodeId])
    }

    @Test func aDowngradeAtAnEqualVersionClearsTheBit() throws {
        // A build put back republishes at the version it persisted, without the bit; the strict gate passes an equal
        // version, so the peer reads it as what that build does (contract §10).
        let fixture = EngineFixture(me)
        fixture.deliver(try bob.profile(version: 6, publishedAt: now, capabilities: Self.upgraded), from: bob)
        fixture.deliver(try bob.profile(version: 6, publishedAt: now + 1, capabilities: Self.before), from: bob)
        #expect(capabilities(of: bob, in: fixture) == Self.before)
    }

    /// Dave, an Android phone, pinned at version 10 with `capabilities` and his prekey, then his sealed profile at version
    /// 20, which moves the presentation and carries neither capabilities nor a prekey.
    private func presentedPastThePrekey(capabilities: Int64) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me)
        let sealer = try AndroidPeer(dave)
        fixture.deliver(
            try dave.profile(name: "Dave", version: 10, publishedAt: now, capabilities: capabilities, prekey: sealer.prekey.info),
            from: dave)
        let control = MessageContent(
            body: "", ctl: MessageContent.Control.profile, pr: ProfilePayload(name: "Dave", status: "", avatarHash: nil, version: 20))
        fixture.deliver(
            try sealer.dm(control, to: me, prekey: try fixture.ourPrekey(), id: frameIdOf("ctl-p1"), sentAt: now), from: sealer)
        let row = try #require(fixture.stores.peers.peer(dave.nodeId))
        #expect(row.updatedAt == 20 && row.prekeyProfileAt == 10 && row.capabilities == capabilities)
        return (fixture, sealer)
    }

    @Test func aSealedProfileMovesNoCapabilitiesAndTellsNothing() throws {
        let (fixture, _) = try presentedPastThePrekey(capabilities: Self.before)
        #expect(fixture.transport.provesItself.isEmpty)
    }

    @Test func aProfileOlderThanThePresentationLandsItsPrekeyButNotItsLackOfTheBit() throws {
        // The sharp case: version 15 is stale for the presentation (20) and fresh for the prekey (10). Before §7 it wrote
        // its capabilities and took the bit back.
        let (fixture, sealer) = try presentedPastThePrekey(capabilities: Self.upgraded)
        fixture.deliver(
            try dave.profile(name: "Dave", version: 15, publishedAt: now + 1, capabilities: Self.before, prekey: sealer.prekey.info),
            from: dave)
        let row = try #require(fixture.stores.peers.peer(dave.nodeId))
        #expect(row.prekeyProfileAt == 15, "its prekey still lands on the prekey's watermark")
        #expect(row.capabilities == Self.upgraded)
    }

    @Test func aProfileOlderThanThePresentationGainsNoBitEither() throws {
        let (fixture, sealer) = try presentedPastThePrekey(capabilities: Self.before)
        fixture.deliver(
            try dave.profile(name: "Dave", version: 15, publishedAt: now + 1, capabilities: Self.upgraded, prekey: sealer.prekey.info),
            from: dave)
        #expect(capabilities(of: dave, in: fixture) == Self.before)
        #expect(fixture.transport.provesItself.isEmpty)
        fixture.deliver(
            try dave.profile(name: "Dave", version: 20, publishedAt: now + 2, capabilities: Self.upgraded, prekey: sealer.prekey.info),
            from: dave)
        #expect(capabilities(of: dave, in: fixture) == Self.upgraded, "one at the presentation's version does")
        #expect(fixture.transport.provesItself == [dave.nodeId])
    }

    // MARK: Our own profile: republished as an edit when its capabilities change

    /// Our profile frame as custody holds it for the current stamp.
    private func ourProfile(_ fixture: EngineFixture) throws -> (envelope: RelayEnvelope, content: ProfileContent) {
        let id = "profile-\(me.nodeId)-\(fixture.stores.ownProfile.load().publishedAt)"
        let held = try #require(fixture.stores.custody.frame(id, now: fixture.clock.wallMilliseconds()))
        return (held.envelope, try ProfileContent(decoding: held.envelope.payload))
    }

    @Test func aProfileFromBeforeTheBitIsPublishedAgainAsAnEditOnceAtStart() throws {
        let earlier = now - 60_000
        let stores = MeshStores.inMemory(ownProfile: OwnProfile(name: "Me", version: 5, publishedAt: earlier))
        let fixture = EngineFixture(me, stores: stores)
        let own = stores.ownProfile.load()
        #expect(own.version == now && own.publishedAt == now, "an edit: a new version and a new stamp")
        #expect(own.capabilities?.rawValue == 0x4000F, "the switch is off, so no ratchet bits, and the link-proof bit")
        #expect(own.name == "Me", "nothing presented moved")
        let (envelope, content) = try ourProfile(fixture)
        #expect(envelope.id == "profile-\(me.nodeId)-\(now)" && content.version == now && content.capabilities == 0x4000F)
        #expect(fixture.log.all.contains("info mesh republished our profile: its capabilities are now 4000f"))
        let flooded = fixture.transport.written(.profile)
        #expect(flooded.count == 1 && flooded.first?.envelope.id == envelope.id)

        let again = EngineFixture(me, stores: stores, wall: now + 60_000)
        #expect(stores.ownProfile.load() == own, "a second start finds the capabilities it recorded and edits nothing")
        #expect(again.transport.written(.profile).isEmpty)
    }

    @Test func recordedCapabilitiesWithoutTheBitArePublishedAgain() {
        // A build put back and then upgraded again: it recorded what it signed, without the bit.
        let earlier = now - 60_000
        let stores = MeshStores.inMemory(ownProfile: OwnProfile(name: "Me", version: 5, publishedAt: earlier, capabilities: 0xF))
        _ = EngineFixture(me, stores: stores)
        #expect(stores.ownProfile.load().version == now && stores.ownProfile.load().capabilities?.rawValue == 0x4000F)
    }

    @Test func recordedCapabilitiesThatMatchPublishNothing() {
        let earlier = now - 60_000
        let own = OwnProfile(name: "Me", version: 5, publishedAt: earlier, capabilities: 0x4000F)
        let stores = MeshStores.inMemory(ownProfile: own)
        let fixture = EngineFixture(me, stores: stores)
        #expect(stores.ownProfile.load() == own)
        #expect(fixture.transport.written(.profile).isEmpty)
    }

    @Test func withTheSwitchOnTheEditCarriesThePrekeyTheBitsAndTheLinkProofBit() throws {
        let earlier = now - 60_000
        let ring = try PrekeyRing.load(for: me.keys, from: KeptSecretStore(me.keys.storedForm))
        var minting = ring
        _ = try minting.rotate(now: earlier)
        let own = OwnProfile(name: "Me", version: 5, publishedAt: earlier, prekeyId: 1, capabilities: 0x15F)
        let stores = MeshStores.inMemory(ownProfile: own)
        let fixture = EngineFixture(me, stores: stores, configuration: MeshConfiguration(ratchet: true), prekeys: minting)
        let after = stores.ownProfile.load()
        #expect(after.version == now && after.prekeyId == 1 && after.capabilities?.rawValue == 0x4015F)
        let (_, content) = try ourProfile(fixture)
        #expect(content.capabilities == 0x4015F && content.prekey?.id == 1)
    }

    @Test func aProfileNeverEditedIsRepublishedAtVersionZero() {
        // An edit would flood its empty name at a version every peer takes; the onboarding's edit outranks it later.
        let stores = MeshStores.inMemory()
        _ = EngineFixture(me, stores: stores)
        let own = stores.ownProfile.load()
        #expect(own.version == 0 && own.publishedAt == now && own.capabilities?.rawValue == 0x4000F)
    }

    @Test func everyEditAndRepublishRecordsWhatItCarries() {
        let stores = MeshStores.inMemory()
        let fixture = EngineFixture(me, stores: stores)
        fixture.engine.updateProfile(name: "Me", status: "", openToChat: false)
        #expect(stores.ownProfile.load().capabilities?.rawValue == 0x4000F)
        var stale = stores.ownProfile.load()
        stale.capabilities = nil
        stores.ownProfile.save(stale)
        fixture.advance(MeshConfiguration().republishMilliseconds + 1000)
        #expect(stores.ownProfile.load().publishedAt > stale.publishedAt, "the 12-hour republish")
        #expect(stores.ownProfile.load().capabilities?.rawValue == 0x4000F)
    }

    // MARK: Two engines: the upgrade, a re-served old frame, and the peer's row

    @Test func aPeerHoldingOurUpgradedProfileKeepsTheBitWhenOurOldProfileIsReServed() throws {
        // Our old build signed version 5 without the bit, twice, twelve hours apart; custody carries both. Our upgraded
        // build starts, and its edit reaches Bob. Then the other old copy reaches him.
        let first = try me.profile(name: "Me", version: 5, publishedAt: now - 50_000_000, capabilities: 0xF)
        let second = try me.profile(name: "Me", version: 5, publishedAt: now - 7_000_000, capabilities: 0xF)
        let ours = EngineFixture(me, stores: .inMemory(ownProfile: OwnProfile(name: "Me", version: 5, publishedAt: now - 7_000_000)))
        let edit = try #require(ours.transport.written(.profile).first)
        let theirs = EngineFixture(bob, seed: 11)
        theirs.deliver(first, from: dave)
        #expect(theirs.stores.peers.peer(me.nodeId)?.capabilities == 0xF)
        theirs.deliver(TestFrame(wire: edit.wire, envelope: edit.envelope), from: me)
        #expect(theirs.stores.peers.peer(me.nodeId)?.capabilities == 0x4000F)
        #expect(theirs.transport.provesItself == [me.nodeId])
        theirs.deliver(second, from: dave)
        #expect(theirs.stores.peers.peer(me.nodeId)?.capabilities == 0x4000F, "strictly older, so the bit stays")
        #expect(theirs.transport.provesItself == [me.nodeId])
    }
}
