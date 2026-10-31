import Foundation
import KnitCrypto
import KnitMesh
import KnitPeer
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// knit-peer's `advertise-photo` store: while set, our profile reads as naming the hash; a save never keeps it; the
/// checkpoint is the inner store's; and with nothing set it is the store it wraps.
@Suite struct ForgingOwnProfileStoreTests {
    private let real = BlobHash(of: fixtureBytes(1000, seed: 1))
    private let advertised = BlobHash(of: fixtureBytes(1000, seed: 2))

    private var profile: OwnProfile {
        OwnProfile(name: "Liar", status: "lying low", openToChat: true, version: 5, publishedAt: 6, avatarHash: real, prekeyId: 3)
    }

    @Test func withNothingSetItIsTheStoreItWraps() {
        let inner = MemoryOwnProfileStore(profile)
        let store = ForgingOwnProfileStore(wrapping: inner)
        #expect(store.advertisedPhoto == nil)
        #expect(store.load() == profile && store.loadIfReadable() == profile)
        var edited = profile
        edited.avatarHash = advertised
        edited.version = 9
        store.save(edited)
        #expect(inner.load() == edited, "saved as given, the advertised hash too, since nothing is set")
    }

    @Test func whileSetOurProfileNamesTheAdvertisedHashAndASaveKeepsOurOwn() {
        let inner = MemoryOwnProfileStore(profile)
        let store = ForgingOwnProfileStore(wrapping: inner)
        store.advertise(advertised)
        #expect(store.advertisedPhoto == advertised)
        var lying = profile
        lying.avatarHash = advertised
        #expect(store.load() == lying && store.loadIfReadable() == lying)
        #expect(inner.load() == profile, "the store holds no lie")

        // An edit saves what it loaded, with its clocks moved.
        var edited = store.load()
        edited.version = 10
        edited.publishedAt = 11
        store.save(edited)
        var kept = edited
        kept.avatarHash = real
        #expect(inner.load() == kept, "the clocks kept, the photo our own")
        #expect(store.load() == edited)

        // A new photo of our own is kept as it is.
        let newPhoto = BlobHash(of: fixtureBytes(1000, seed: 3))
        var replaced = store.load()
        replaced.avatarHash = newPhoto
        store.save(replaced)
        #expect(inner.load().avatarHash == newPhoto && store.load().avatarHash == advertised)

        store.advertise(nil)
        #expect(store.load().avatarHash == newPhoto)
    }

    @Test func theFileNeverKeepsTheAdvertisedHash() throws {
        let directory = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let state = PeerState(directory: directory)
        state.profileStore().save(profile)
        let store = ForgingOwnProfileStore(wrapping: state.profileStore())
        store.advertise(advertised)
        var edited = store.load()
        edited.version = 20
        edited.publishedAt = 21
        store.save(edited)
        let file = try #require(FileManager.default.contents(atPath: directory + "/profile.json"))
        #expect(try #require(String(bytes: file, encoding: .utf8)).contains(advertised.string) == false)
        let reread = state.profileStore().load()
        #expect(reread.avatarHash == real && reread.version == 20 && reread.publishedAt == 21)
    }

    @Test func theCheckpointIsTheInnerStoresAndLeavesTheSwitch() {
        let inner = MemoryOwnProfileStore(profile)
        let store = ForgingOwnProfileStore(wrapping: inner)
        let checkpoint = store.checkpoint()
        store.advertise(advertised)
        var edited = store.load()
        edited.version = 30
        store.save(edited)
        checkpoint.restore()
        #expect(inner.load() == profile, "put back as it was")
        #expect(store.advertisedPhoto == advertised, "the switch is outside the unit")
    }

    @Test func aUnitUndoneThroughTheWrapperPutsTheInnerStoreBack() {
        let inner = MemoryOwnProfileStore(profile)
        let store = ForgingOwnProfileStore(wrapping: inner)
        let stores = MeshStores.inMemory(ownProfileStore: store)
        store.advertise(advertised)
        let undone = stores.transactor.atomically { () -> Int? in
            var edited = stores.ownProfile.load()
            edited.version = 40
            stores.ownProfile.save(edited)
            return nil
        }
        #expect(undone == .abandoned && inner.load() == profile)
    }
}
