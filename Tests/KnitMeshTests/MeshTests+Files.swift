import KnitCrypto
import KnitMesh
import KnitWire
import Testing

/// Files through the actor, in a file of their own so ``MeshTests`` stays in bounds.
extension MeshTests {
    @Test func aFileStreamingInIsReportedBackToItsSender() async throws {
        // knit-next ADR 2026-10.nsr7 (ADR 2026-10.ds45): an Android peer, its HELLO carrying `CAP_BLOB_HAVE`, is told how
        // much of the photo it pushes us has arrived, on the chunk that brings a windowed sender's smallest chunk
        // (`RxReports`, ADR 2026-10.xwjc).
        let rig = rig()
        await rig.mesh.start()
        await rig.mesh.process(.accepted(channel))
        await rig.mesh.process(.received(channel, hello(bob, capabilities: 0x2FFF)))
        let photo = (0..<4096).map { UInt8(truncatingIfNeeded: $0) }
        let header = FileHeader(kind: .avatar, key: BlobHash(of: photo).string, mime: "image/jpeg", size: photo.count)
        await rig.mesh.process(.received(channel, LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []))
        rig.clock.advance(100)
        await rig.mesh.process(.received(channel, LinkRecord(.fileChunk, payload: Array(photo[..<2048])).encoded ?? []))
        let sent = rig.radio.frames(on: channel).compactMap { try? RelayEnvelope(decoding: $0.signed) }
        let report = try #require(sent.first { $0.type == .blobProgress })
        let expected = BlobProgressContent(hash: BlobHash(of: photo).string, held: 2048, ms: 100)
        #expect(try BlobProgressContent(decoding: report.payload) == expected)
    }

    @Test func aReportArrivingOnTheLinkFreesTheWindowOfThePhotoWePush() async {
        // ADR 2026-10.xwjc: our photo goes to a peer that reports in its starting window, and the peer's `blobprog`
        // through the engine frees the next.
        let rig = rig()
        await rig.mesh.start()
        let photo = (0..<40_960).map { UInt8(truncatingIfNeeded: $0 &* 3) }
        await rig.mesh.setAvatar(photo)
        await rig.mesh.process(.accepted(channel))
        await rig.mesh.process(.received(channel, hello(bob, capabilities: 0x2FFF)))
        func chunks() -> Int {
            rig.radio.records(on: channel).filter { $0.tag == .fileChunk }.reduce(0) { $0 + $1.payload.count }
        }
        #expect(chunks() == 8192, "the starting window")
        let report = BlobProgressContent(hash: BlobHash(of: photo).string, held: 8192, ms: 500)
        let frame = bob.unsigned(.blobProgress, payload: report.encoded, id: "prog-1")
        await rig.mesh.process(.received(channel, LinkRig.frameRecord(frame.wire)))
        #expect(chunks() > 8192, "the report freed the window")
    }
}
