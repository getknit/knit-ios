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

    /// The AVATAR twin (contract `ios-avatar-push-mark`, trial run 20261031-021140): bob pushes a photo of the same hash
    /// past the ceiling while it is wanted of him only as a photo. The link cuts it at its header and the engine never
    /// hears of it: nobody is passed over, and no ask is withdrawn.
    @Test func aPushedAvatarOverThePhotoLimitPassesNobodyOverThroughTheMesh() async throws {
        let rig = rig()
        await rig.mesh.start()
        await linkBob(rig)
        let dave = TestPeer(seed: 4)
        let photo = BlobHash(of: Array("dave's face".utf8))
        let profile = try dave.profile(publishedAt: EngineFixture.start, avatarHash: photo.string)
        await rig.mesh.process(.received(channel, LinkRig.admittedRecord(profile)))
        let header = FileHeader(kind: .avatar, key: photo.string, mime: "image/jpeg", size: FileIntake.maxAvatarBytes + 1)
        await rig.mesh.process(.received(channel, LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []))
        #expect(await rig.mesh.blobs.photosOverCeiling == 0, "a push answers no want")
        let types = rig.radio.frames(on: channel).compactMap { try? RelayEnvelope(decoding: $0.signed).type }
        #expect(!types.contains(.blobCancel), "no ask of bob's is withdrawn")
    }
}
