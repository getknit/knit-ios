import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// `CAP_LINK_PREVIEW` (`0x400`), the promise that this phone draws a link's preview card (ADR 2026-11.hcvg). Android reads
/// it from our signed profile alone before it attaches a card to a DM or a group toward us, so a debug build with link
/// previews signs it, prekey or none, and republishes when it comes or goes. A release build, knit-peer and the tests
/// start without it, and nothing else carries it: not ``Capabilities/local``, which the HELLO and the advert send.
@Suite struct MeshEngineLinkPreviewCapabilityTests {
    private let me = TestPeer(seed: 1)
    private var now: Int64 { EngineFixture.start }

    /// Our profile frame as custody holds it for the current stamp.
    private func ourProfile(_ fixture: EngineFixture) throws -> ProfileContent {
        let id = "profile-\(me.nodeId)-\(fixture.stores.ownProfile.load().publishedAt)"
        let held = try #require(fixture.stores.custody.frame(id, now: fixture.clock.wallMilliseconds()))
        return try ProfileContent(decoding: held.envelope.payload)
    }

    @Test func theSwitchAddsTheBitToTheProfileAlone() {
        #expect(!MeshConfiguration().linkPreviews && MeshConfiguration().drawnCapabilities.isEmpty)
        #expect(MeshConfiguration(ratchet: true, linkPreviews: true).capabilities.rawValue == 0x1C055F)
        #expect(MeshConfiguration(linkPreviews: true).capabilities.rawValue == 0x1C040F)
        #expect(MeshConfiguration(ratchet: true).capabilities.rawValue == 0x1C015F, "a release build's set is unchanged")
        #expect(!Capabilities.local.contains(.linkPreview), "the HELLO and the advert never claim it")
    }

    /// With no prekey to carry, the profile still says the build draws cards: the ratchet's bits wait for the prekey, the
    /// card's do not.
    @Test func aProfileWithoutAPrekeyCarriesTheBit() throws {
        let earlier = now - 60_000
        let stores = MeshStores.inMemory(ownProfile: OwnProfile(name: "Me", version: 5, publishedAt: earlier, capabilities: 0x1C000F))
        let fixture = EngineFixture(me, stores: stores, configuration: MeshConfiguration(linkPreviews: true))
        let own = stores.ownProfile.load()
        #expect(own.version == now && own.capabilities?.rawValue == 0x1C040F, "the bit came, so the profile is edited at start")
        #expect(try ourProfile(fixture).capabilities == 0x1C040F)
        #expect(fixture.log.all.contains("info mesh republished our profile: its capabilities are now 1c040f"))
    }

    @Test func withThePrekeyTheEditCarriesEveryBit() throws {
        let earlier = now - 60_000
        let ring = try PrekeyRing.load(for: me.keys, from: KeptSecretStore(me.keys.storedForm))
        var minting = ring
        _ = try minting.rotate(now: earlier)
        let own = OwnProfile(name: "Me", version: 5, publishedAt: earlier, prekeyId: 1, capabilities: 0x1C015F)
        let stores = MeshStores.inMemory(ownProfile: own)
        let fixture = EngineFixture(
            me, stores: stores, configuration: MeshConfiguration(ratchet: true, linkPreviews: true), prekeys: minting)
        #expect(stores.ownProfile.load().capabilities?.rawValue == 0x1C055F)
        let content = try ourProfile(fixture)
        #expect(content.capabilities == 0x1C055F && content.prekey?.id == 1)
    }

    /// The bit's reader is a peer's row, where Android reads it: another engine pins our profile with it, and drops it when
    /// a build without link previews publishes again.
    @Test func anotherEnginePinsTheBitAndDropsItWithoutLinkPreviews() throws {
        let bob = TestPeer(seed: 2)
        let ours = EngineFixture(me, configuration: MeshConfiguration(linkPreviews: true))
        let theirs = EngineFixture(bob)
        ours.link(bob)
        let pushed = try #require(ours.transport.written(.profile).last)
        theirs.deliver(TestFrame(wire: pushed.wire, envelope: pushed.envelope), from: me)
        #expect(theirs.stores.peers.peer(me.nodeId)?.capabilities == 0x1C040F)
        let off = EngineFixture(me, stores: ours.stores)
        off.link(bob)
        let plain = try #require(off.transport.written(.profile).last)
        theirs.deliver(TestFrame(wire: plain.wire, envelope: plain.envelope), from: me)
        #expect(theirs.stores.peers.peer(me.nodeId)?.capabilities == 0x1C000F)
    }

    /// A release build put on a phone that ran a debug one takes the bit back, under a new version that outranks every
    /// profile that claimed it.
    @Test func aBuildWithoutLinkPreviewsTakesTheBitBack() throws {
        let earlier = now - 60_000
        let stores = MeshStores.inMemory(ownProfile: OwnProfile(name: "Me", version: 5, publishedAt: earlier, capabilities: 0x1C040F))
        let fixture = EngineFixture(me, stores: stores)
        #expect(stores.ownProfile.load().version == now && stores.ownProfile.load().capabilities?.rawValue == 0x1C000F)
        #expect(try ourProfile(fixture).capabilities == 0x1C000F)
    }
}
