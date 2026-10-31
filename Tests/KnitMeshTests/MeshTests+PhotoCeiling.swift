import KnitCrypto
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// The Mesh hands a link's over-limit file to the engine (ADR 2026-10.r88m), part of ``MeshTests``.
extension MeshTests {
    @Test func aFileOverItsPhotoLimitReachesTheEngineThroughTheMesh() async throws {
        let rig = rig()
        await rig.mesh.start()
        await linkBob(rig)
        // Dave is not linked, so his photo is wanted of bob, only as a photo.
        let dave = TestPeer(seed: 4)
        let photo = BlobHash(of: Array("dave's face".utf8))
        let profile = try dave.profile(publishedAt: EngineFixture.start, avatarHash: photo.string)
        await rig.mesh.process(.received(channel, LinkRig.admittedRecord(profile)))
        let header = FileHeader(kind: .attachment, key: photo.string, mime: "image/jpeg", size: FileIntake.maxAvatarBytes + 1)
        await rig.mesh.process(.received(channel, LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []))
        #expect(await rig.mesh.blobs.photosOverCeiling == 1, "bob is passed over for it")
    }
}
