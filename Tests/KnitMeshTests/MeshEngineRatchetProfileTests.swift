import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A sealed `CTL_PROFILE` on receive, with the switch on (ADR 2026-10.5sk9, phase P5a; `applySealedProfile`,
/// `InboundPipeline.kt:1353-1396`): the presentation alone, on the presentation's watermark, never the key, the prekey or
/// the bits, which move only with the cleartext profile on their own watermark. Ported by name from knit-next's
/// `InboundPipelineTest.kt:5524-5640`.
@Suite struct MeshEngineRatchetProfileTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    /// The iPhone with the switch on, Alice pinned (at `version`, with her prekey unless told otherwise), and Carol.
    private func rig(version: Int64? = nil, prekey withPrekey: Bool = true) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        let profile = try alice.profile(
            name: "Ann",
            version: version,
            publishedAt: now,
            capabilities: AndroidPeer.capabilities,
            prekey: withPrekey ? android.prekey.info : nil
        )
        fixture.deliver(profile, from: alice)
        try fixture.pin(carol)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    private var now: Int64 { EngineFixture.start }

    @Test func theSealedProfileCarriesTheFlagAndAStaleOneCannotRevertIt() throws {
        let (fixture, android) = try rig(version: 10)
        let prekey = try fixture.ourPrekey()
        #expect(fixture.stores.peers.peer(alice.nodeId)?.openToChat == false)
        let fresh = ProfilePayload(name: "Ann", status: "", version: 20, openToChat: true)
        fixture.deliver(try android.dm(profileUpdate(fresh), to: me, prekey: prekey, id: "ctl-otc-1", sentAt: now), from: android)
        #expect(fixture.stores.peers.peer(alice.nodeId)?.openToChat == true)
        #expect(fixture.stores.peers.peer(alice.nodeId)?.updatedAt == 20)
        let stale = ProfilePayload(name: "Ann", status: "", version: 15)
        fixture.deliver(try android.dm(profileUpdate(stale), to: me, prekey: prekey, id: "ctl-otc-2", sentAt: now), from: android)
        #expect(fixture.stores.peers.peer(alice.nodeId)?.openToChat == true, "an older sealed update is ignored whole")
        let newer = ProfilePayload(name: "Ann", status: "", version: 30)
        fixture.deliver(try android.dm(profileUpdate(newer), to: me, prekey: prekey, id: "ctl-otc-3", sentAt: now), from: android)
        #expect(fixture.stores.peers.peer(alice.nodeId)?.openToChat == false, "the whole presentation moves together")
        #expect(fixture.transport.written(.receipt).isEmpty)
    }

    @Test func aPrekeyOnlyAdmissionOfAnOlderProfileDoesNotRegressTheFlag() throws {
        let (fixture, android) = try rig(version: 10, prekey: false)
        let prekey = try fixture.ourPrekey()
        let fresh = ProfilePayload(name: "Ann", status: "", version: 100, openToChat: true)
        fixture.deliver(try android.dm(profileUpdate(fresh), to: me, prekey: prekey, id: "ctl-otc-4", sentAt: now), from: android)
        #expect(fixture.stores.peers.peer(alice.nodeId)?.openToChat == true)
        fixture.deliver(try android.profile(publishedAt: now + 1, version: 50), from: android)
        let held = try #require(fixture.stores.peers.peer(alice.nodeId))
        #expect(held.openToChat, "the stale half must not revert the flag")
        #expect(held.prekey?.id == android.prekey.id && held.prekeyProfileAt == 50)
    }

    @Test func aSealedProfileUpdateCannotSuppressTheCleartextFrameCarryingThePrekey() throws {
        let (fixture, android) = try rig(version: 10, prekey: false)
        let prekey = try fixture.ourPrekey()
        #expect(fixture.stores.peers.peer(alice.nodeId)?.prekey == nil)
        let newest = ProfilePayload(name: "Newest", status: "", version: 100)
        fixture.deliver(try android.dm(profileUpdate(newest), to: me, prekey: prekey, id: "ctl-p1", sentAt: now), from: android)
        #expect(fixture.stores.peers.peer(alice.nodeId)?.name == "Newest")
        #expect(fixture.stores.peers.peer(alice.nodeId)?.updatedAt == 100)
        fixture.deliver(try android.profile(publishedAt: now + 1, version: 50, name: "Older"), from: android)
        let held = try #require(fixture.stores.peers.peer(alice.nodeId))
        #expect(held.prekey?.pub == android.prekey.publicKey, "the prekey lands on its own watermark")
        #expect(held.name == "Newest" && held.updatedAt == 100, "the stale half reverts nothing")
    }

    @Test func aSealedProfileMovesThePresentationAndNeverTheKeyThePrekeyOrTheBits() throws {
        let (fixture, android) = try rig(version: 10)
        let prekey = try fixture.ourPrekey()
        let before = try #require(fixture.stores.peers.peer(alice.nodeId))
        let update = ProfilePayload(name: "Annie", status: "Away", avatarHash: String(repeating: "a", count: 64), version: 20)
        fixture.deliver(try android.dm(profileUpdate(update), to: me, prekey: prekey, id: "ctl-p2", sentAt: now), from: android)
        let after = try #require(fixture.stores.peers.peer(alice.nodeId))
        #expect(after.name == "Annie" && after.status == "Away" && after.updatedAt == 20)
        #expect(after.advertisedAvatarHash?.string == String(repeating: "a", count: 64) && after.avatarHash == nil, "named, not held")
        #expect(after.publicKey == before.publicKey && after.prekey == before.prekey && after.prekeyProfileAt == before.prekeyProfileAt)
        #expect(after.capabilities == before.capabilities && after.deviceTag == before.deviceTag)
        let updated = fixture.engine.drainEvents().contains { $0 == .peerUpdated(alice.nodeId) }
        #expect(updated)
    }

    @Test func aSealedProfileThatChangesNothingAnnouncesNothing() throws {
        let (fixture, android) = try rig(version: 10)
        let prekey = try fixture.ourPrekey()
        let update = ProfilePayload(name: "Ann", status: "", version: 20)
        fixture.deliver(try android.dm(profileUpdate(update), to: me, prekey: prekey, id: "ctl-same-1", sentAt: now), from: android)
        #expect(fixture.engine.drainEvents().contains(.peerUpdated(alice.nodeId)))
        fixture.deliver(try android.dm(profileUpdate(update), to: me, prekey: prekey, id: "ctl-same-2", sentAt: now + 1), from: android)
        #expect(fixture.engine.drainEvents().isEmpty, "the same presentation again moves nothing")
    }

    /// The photo a sealed profile names follows the rule a cleartext one meets: a name that is no hash leaves the photo
    /// shown, and a photo whose bytes are held replaces the one shown, which goes once nothing names it.
    @Test func aSealedProfilesPhotoFollowsTheCleartextRule() throws {
        let (fixture, android) = try rig(version: 10)
        let prekey = try fixture.ourPrekey()
        let old = Array("old face".utf8)
        let new = Array("new face".utf8)
        let oldHash = BlobHash(of: old)
        let newHash = BlobHash(of: new)
        #expect(fixture.stores.blobs.insert(old, hash: oldHash, mime: "image/jpeg", storedAt: now))
        #expect(fixture.stores.blobs.insert(new, hash: newHash, mime: "image/jpeg", storedAt: now))
        var row = try #require(fixture.stores.peers.peer(alice.nodeId))
        row.avatarHash = oldHash
        row.advertisedAvatarHash = oldHash
        fixture.stores.peers.upsert(row)

        let garbled = ProfilePayload(name: "Ann", status: "", avatarHash: "not a hash", version: 20)
        fixture.deliver(try android.dm(profileUpdate(garbled), to: me, prekey: prekey, id: "ctl-photo-1", sentAt: now), from: android)
        #expect(fixture.stores.peers.peer(alice.nodeId)?.avatarHash == oldHash, "a hash that is no hash leaves the photo shown")
        #expect(fixture.stores.peers.peer(alice.nodeId)?.advertisedAvatarHash == nil)

        let held = ProfilePayload(name: "Ann", status: "", avatarHash: newHash.string, version: 30)
        fixture.deliver(try android.dm(profileUpdate(held), to: me, prekey: prekey, id: "ctl-photo-2", sentAt: now + 1), from: android)
        #expect(fixture.stores.peers.peer(alice.nodeId)?.avatarHash == newHash)
        #expect(!fixture.stores.blobs.contains(oldHash), "the photo it replaced is let go after the commit")
        #expect(fixture.stores.blobs.contains(newHash))
    }

    private func profileUpdate(_ payload: ProfilePayload) -> MessageContent {
        MessageContent(body: "", ctl: MessageContent.Control.profile, pr: payload)
    }
}
