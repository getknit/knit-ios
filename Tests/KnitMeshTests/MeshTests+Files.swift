import KnitCrypto
import KnitMesh
import KnitWire
import Testing

/// Files through the actor, in a file of their own so ``MeshTests`` stays in bounds.
extension MeshTests {
    @Test func aFileStreamingInIsReportedBackToItsSender() async throws {
        // knit-next ADR 2026-10.nsr7 (ADR 2026-10.ds45): an Android peer, its HELLO carrying `CAP_BLOB_HAVE`, is told how
        // much of the photo it pushes us has arrived, two seconds into it.
        let rig = rig()
        await rig.mesh.start()
        await rig.mesh.process(.accepted(channel))
        await rig.mesh.process(.received(channel, hello(bob, capabilities: 0x2FFF)))
        let photo = (0..<4096).map { UInt8(truncatingIfNeeded: $0) }
        let header = FileHeader(kind: .avatar, key: BlobHash(of: photo).string, mime: "image/jpeg", size: photo.count)
        await rig.mesh.process(.received(channel, LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []))
        await rig.mesh.process(.received(channel, LinkRecord(.fileChunk, payload: Array(photo[..<1024])).encoded ?? []))
        rig.clock.advance(LinkManager.progressEveryMilliseconds)
        await rig.mesh.process(.received(channel, LinkRecord(.fileChunk, payload: Array(photo[1024..<2048])).encoded ?? []))
        let sent = rig.radio.frames(on: channel).compactMap { try? RelayEnvelope(decoding: $0.signed) }
        let report = try #require(sent.first { $0.type == .blobProgress })
        let expected = BlobProgressContent(hash: BlobHash(of: photo).string, held: 2048, ms: LinkManager.progressEveryMilliseconds)
        #expect(try BlobProgressContent(decoding: report.payload) == expected)
    }
}
