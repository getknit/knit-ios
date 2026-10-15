import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// What the peer and own-profile stores keep of the ratchet's prekeys, run against every implementation (ADR
/// 2026-10.5sk9): a peer's verified prekey with its own watermark, and the prekey our own publish carries.
@Suite struct PrekeyStoreTests {
    private static let kinds = RepositoryKind.allCases

    private let bob = fixtureNodeId(2)

    @Test(arguments: kinds)
    func aPeerKeepsItsPrekeyAndItsWatermark(kind: RepositoryKind) throws {
        let store = try kind.make().peers
        let prekey = PrekeyInfo(id: 3, pub: fixtureBytes(32, seed: 1), sig: fixtureBytes(64, seed: 2))
        let pinned = PeerRecord(nodeId: bob, name: "Bob", status: "", publicKey: "key", updatedAt: 9, prekey: prekey, prekeyProfileAt: 7)
        store.upsert(pinned)
        #expect(store.peer(bob) == pinned)
        #expect(store.allPeers() == [pinned])
        var cleared = pinned
        cleared.prekey = nil
        cleared.prekeyProfileAt = 8
        store.upsert(cleared)
        #expect(store.peer(bob) == cleared, "a cleared pin reads back as none, with its watermark")
    }

    @Test func aPeerPinnedBeforePrekeysHasNoneAndAWatermarkOfZero() {
        let peer = PeerRecord(nodeId: bob, name: "", status: "", publicKey: "key", updatedAt: 4)
        #expect(peer.prekey == nil)
        #expect(peer.prekeyProfileAt == 0)
    }

    /// `INSERT OR REPLACE` nulls every column its list leaves out, so the 12-hour republish, which moves only the stamp,
    /// would drop the prekey our profile carries from a store that forgot its column.
    @Test(arguments: kinds)
    func ourProfileKeepsThePrekeyItCarriesAcrossARepublish(kind: RepositoryKind) throws {
        let store = try kind.make().ownProfile
        #expect(store.load().prekeyId == nil)
        #expect(store.loadIfReadable() == OwnProfile(), "a store that reads answers what it holds, a fresh profile here")
        var profile = OwnProfile(name: "Alice", version: 7, publishedAt: 9, prekeyId: 4)
        store.save(profile)
        #expect(store.load() == profile)
        #expect(store.loadIfReadable() == profile)
        profile.publishedAt = 43_200_009
        store.save(profile)
        #expect(store.load().prekeyId == 4)
        profile.prekeyId = nil
        store.save(profile)
        #expect(store.load().prekeyId == nil, "the switch turned off clears it")
    }
}
