import KnitCrypto
import KnitMesh
import KnitStore
import KnitSync
import KnitWire
import Testing

/// Our profile's store with its database locked: reads and writes fail, and ``load()`` answers a fresh profile, as
/// `SQLOwnProfileStore`'s fallback does.
private final class LockedOwnProfileStore: OwnProfileStore {
    private struct State {
        var profile: OwnProfile
        var locked = true
        /// Whether a write is refused while locked too; a damaged row fails its reads while writes still land.
        var refusesWrites: Bool
    }

    private let state: Lock<State>

    init(_ profile: OwnProfile, refusesWrites: Bool = true) {
        state = Lock(State(profile: profile, refusesWrites: refusesWrites))
    }

    /// What the database holds, read past the lock.
    var held: OwnProfile { state.withLock { $0.profile } }

    var locked: Bool {
        get { state.withLock { $0.locked } }
        set { state.withLock { $0.locked = newValue } }
    }

    func load() -> OwnProfile {
        loadIfReadable() ?? OwnProfile()
    }

    func loadIfReadable() -> OwnProfile? {
        state.withLock { $0.locked ? nil : $0.profile }
    }

    func save(_ profile: OwnProfile) {
        state.withLock { state in
            if !state.locked || !state.refusesWrites {
                state.profile = profile
            }
        }
    }
}

/// Our prekey on a profile never edited: a reinstall's, before onboarding publishes the name, or a node's that never
/// set one. It rides a republish at version 0, never an edit, so no peer is shown an empty name, and a profile the
/// store cannot read changes nothing (ADR 2026-10.5sk9, ADR 2026-09.tkww).
@Suite struct MeshEnginePrekeyReinstallTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let ratchetOn = MeshConfiguration(ratchet: true)
    private let hour: Int64 = 3_600_000
    private let heal: Int64 = 900_000

    /// Our profile frame for the current stamp, as custody holds it.
    private func ourFrame(_ fixture: EngineFixture) throws -> TestFrame {
        let id = "profile-\(alice.nodeId)-\(fixture.stores.ownProfile.load().publishedAt)"
        let held = try #require(fixture.stores.custody.frame(id, now: fixture.clock.wallMilliseconds()))
        return TestFrame(wire: held.reserved, envelope: held.envelope)
    }

    @Test func aReinstallShowsNoPeerAnEmptyNameAndEndsOnTheFreshPrekeyAtTheOnboardingVersion() throws {
        // Alice's first life: her name published with prekey 1, kept in the Keychain beside her identity.
        let keychain = KeptSecretStore(alice.keys.storedForm)
        let firstLife = EngineFixture(alice, configuration: ratchetOn, prekeys: try PrekeyRing.load(for: alice.keys, from: keychain))
        firstLife.engine.updateProfile(name: "Alice", status: "", openToChat: false)
        let named = try ourFrame(firstLife)
        // The reinstall an hour later: the Keychain kept both, the database is new, and the mesh starts on onboarding's
        // permissions page, a minute before onboarding publishes the name (`OnboardingModel.allowBluetooth`, `finish`).
        let reinstalled = EngineFixture(
            alice, configuration: ratchetOn, prekeys: try PrekeyRing.load(for: alice.keys, from: keychain), started: false)
        reinstalled.clock.advance(hour)
        reinstalled.engine.start()
        let atStart = try ourFrame(reinstalled)
        reinstalled.clock.advance(60_000)
        reinstalled.engine.updateProfile(name: "Alice", status: "", openToChat: false)
        let onboarded = try ourFrame(reinstalled)
        let onboarding = reinstalled.stores.ownProfile.load().version
        let ring = try PrekeyRing.load(for: alice.keys, from: keychain)
        let fresh = try #require(ring.newest)
        #expect(fresh.id == 2)
        #expect(ring.prekey(id: 1) != nil, "the prekey peers pinned before still opens an init")
        // Bob pinned her first life, and custody brings him the two new frames in either order.
        for order in [[atStart, onboarded], [onboarded, atStart]] {
            let peer = EngineFixture(bob)
            peer.clock.advance(hour + 60_000)
            peer.deliver(named, from: alice)
            #expect(peer.stores.peers.peer(alice.nodeId)?.prekey?.id == 1)
            for frame in order {
                peer.deliver(frame, from: alice)
                #expect(peer.stores.peers.peer(alice.nodeId)?.name == "Alice", "never an empty name")
            }
            let pinned = try #require(peer.stores.peers.peer(alice.nodeId))
            #expect(pinned.prekey == fresh.info)
            #expect(pinned.prekeyProfileAt == onboarding)
            #expect(pinned.updatedAt == onboarding)
            #expect(pinned.capabilities == 0x15F)
        }
    }

    @Test func aRotationBeforeAnyEditIsARepublishThatFloodsNothing() throws {
        let keychain = KeptSecretStore(alice.keys.storedForm)
        let fixture = EngineFixture(alice, configuration: ratchetOn, prekeys: try PrekeyRing.load(for: alice.keys, from: keychain))
        fixture.link(bob)
        fixture.advance(PrekeyRing.rotationMilliseconds - 1)
        fixture.transport.clear()
        fixture.advance(heal)
        #expect(fixture.transport.written(.profile).isEmpty, "a republish waits for the digest, as the 12-hour one does")
        let own = fixture.stores.ownProfile.load()
        #expect(own.version == 0)
        #expect(own.prekeyId == 2)
        #expect(own.publishedAt == EngineFixture.start + PrekeyRing.rotationMilliseconds - 1 + heal, "a new stamp for the new payload")
        let content = try ProfileContent(decoding: try ourFrame(fixture).envelope.payload)
        #expect(content.prekey?.id == 2)
        #expect(content.version == 0)
    }

    @Test func aRowThatCannotBeReadIsNeverRepublishedOverEvenWhenWritesLand() {
        // A damaged row fails every read while a write still lands: a republish built from the store's fallback would
        // save a blank, version-0 row over the edited one, and every later prekey would ride version 0.
        let own = OwnProfile(name: "Alice", version: 5, publishedAt: EngineFixture.start - 13 * hour)
        let store = LockedOwnProfileStore(own, refusesWrites: false)
        var stores = MeshStores.inMemory()
        stores.ownProfile = store
        let fixture = EngineFixture(alice, stores: stores)
        #expect(store.held == own, "the start's republish read nothing, so it saved nothing")
        store.locked = false
        fixture.advance(heal)
        #expect(store.held.name == "Alice")
        #expect(store.held.version == 5)
        #expect(store.held.publishedAt > own.publishedAt, "the next heal that reads republishes")
    }

    @Test func aProfileTheStoreCannotReadIsNoReinstallAndNoEdit() throws {
        // Read as the fresh profile the store falls back to, it would mint as a reinstall does, and edit an empty name.
        let keychain = KeptSecretStore(alice.keys.storedForm)
        var ring = try PrekeyRing.load(for: alice.keys, from: keychain)
        try ring.rotate(now: EngineFixture.start - hour)
        let kept = keychain.contents
        let own = OwnProfile(name: "Alice", version: 5, publishedAt: EngineFixture.start - 1000)
        let locked = LockedOwnProfileStore(own)
        var stores = MeshStores.inMemory()
        stores.ownProfile = locked
        let fixture = EngineFixture(alice, stores: stores, configuration: ratchetOn, prekeys: ring)
        #expect(keychain.contents == kept, "no reinstall's mint")
        #expect(locked.held == own)
        #expect(fixture.transport.written.isEmpty, "nothing flooded")
        #expect(fixture.log.all.contains("warning mesh left our prekey as it was: our profile could not be read"))
        // The database reads again by the next heal, which publishes the prekey kept, with the name.
        locked.locked = false
        fixture.advance(heal)
        #expect(locked.held.name == "Alice")
        #expect(locked.held.prekeyId == 1)
        #expect(locked.held.version == EngineFixture.start + heal)
        #expect(try PrekeyRing.load(for: alice.keys, from: keychain).prekeys.map(\.id) == [1])
        let flooded = try #require(fixture.transport.written(.profile).last)
        let content = try ProfileContent(decoding: flooded.envelope.payload)
        #expect(content.name == "Alice")
        #expect(content.prekey?.id == 1)
    }
}
