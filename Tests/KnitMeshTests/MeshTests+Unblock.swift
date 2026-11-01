import KnitCrypto
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// An unblock through the actor while the mesh is stopped (contract revision 2 of `block-hides-profile`, knit-ios #37):
/// the engine takes it whatever ``Mesh/isRunning`` says, so the kept profile shows at once, and the start's re-want asks
/// for the photo the row kept.
extension MeshTests {
    @Test func anUnblockWhileStoppedShowsTheKeptProfileAndTheStartAsksForItsPhoto() async throws {
        let rig = rig()
        let photo = BlobHash(of: Array("bob's face".utf8))
        let first = try bob.profile(name: "Bob", version: 5, publishedAt: EngineFixture.start + 5)
        let held = try bob.profile(name: "Robert", version: 6, publishedAt: EngineFixture.start + 6, avatarHash: photo.string)
        rig.stores.peers.upsert(PeerRecord(nodeId: bob.nodeId, name: "Bob", status: "", publicKey: bob.keys.bundle.encoded, updatedAt: 6))
        rig.stores.peers.recordProfileFrame(first.wire, of: bob.nodeId, sentAt: EngineFixture.start + 5)
        rig.stores.peers.recordProfileFrame(held.wire, of: bob.nodeId, sentAt: EngineFixture.start + 6)
        rig.stores.blocks.block(bob.nodeId, deviceTag: nil)

        await rig.mesh.unblock(bob.nodeId)
        #expect(await !rig.mesh.isRunning)
        let row = try #require(rig.stores.peers.peer(bob.nodeId))
        #expect(row.name == "Robert" && row.advertisedAvatarHash == photo)
        #expect(rig.stores.blocks.blockedNodeIds().isEmpty)

        await rig.mesh.start()
        await linkBob(rig)
        let asked = rig.radio.frames(on: channel).compactMap { try? RelayEnvelope(decoding: $0.signed) }.filter { $0.type == .blobRequest }
            .compactMap { try? BlobRequestContent(decoding: $0.payload).hash }
        #expect(asked == [photo.string], "wanted at the start, and asked of Bob as he links")
    }
}
