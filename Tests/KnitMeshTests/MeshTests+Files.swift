import KnitCrypto
import KnitMesh
import KnitStore
import KnitTestSupport
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
        let frame = bob.unsigned(.blobProgress, payload: report.encoded, id: frameIdOf("prog-1"))
        await rig.mesh.process(.received(channel, LinkRig.admittedRecord(frame)))
        #expect(chunks() > 8192, "the report freed the window")
    }

    @Test func aSecondAskForAPhotoWeFeedIsParkedAndServedOnceTheFeedEnds() async {
        // knit-next ADR 2026-10.g24x (`e2191bb9`): one copy of a blob at a time on the one radio. The link's poke at the
        // feed's end reaches the engine through the actor.
        let rig = rig()
        let carol = TestPeer(seed: 3)
        let carols = ChannelID(51)
        await rig.mesh.start()
        let photo = (0..<40_960).map { UInt8(truncatingIfNeeded: $0 &* 3) }
        let hash = BlobHash(of: photo)
        rig.stores.blobs.insert(photo, hash: hash, mime: "image/jpeg", storedAt: EngineFixture.start)
        await rig.mesh.process(.accepted(channel))
        await rig.mesh.process(.received(channel, hello(bob, capabilities: 0x2FFF)))
        await rig.mesh.process(.accepted(carols))
        await rig.mesh.process(.received(carols, hello(carol, capabilities: 0x2FFF)))
        for (peer, id) in [(bob, channel), (carol, carols)] {
            let ask = peer.unsigned(.blobRequest, payload: BlobRequestContent(hash: hash.string).encoded, id: frameIdOf("breq-\(id)"))
            await rig.mesh.process(.received(id, LinkRig.admittedRecord(ask)))
        }
        func records(_ tag: LinkRecord.Tag, on id: ChannelID) -> [LinkRecord] {
            rig.radio.records(on: id).filter { $0.tag == tag }
        }
        #expect(records(.fileHeader, on: carols).isEmpty, "parked behind bob's copy")
        var held = 0
        for index in 0..<40 where records(.fileEnd, on: channel).isEmpty {
            held = records(.fileChunk, on: channel).reduce(0) { $0 + $1.payload.count }
            let report = BlobProgressContent(hash: hash.string, held: Int64(held), ms: Int64(500 * (index + 1)))
            let frame = bob.unsigned(.blobProgress, payload: report.encoded, id: frameIdOf("prog-\(index)"))
            await rig.mesh.process(.received(channel, LinkRig.admittedRecord(frame)))
        }
        #expect(held == photo.count && records(.fileEnd, on: channel).count == 1)
        #expect(records(.fileHeader, on: carols).count == 1, "served at the feed's end")
    }

    @Test func aPhotoStreamingInShowsHowFarItHasGotUntilItIsStoredInTheSameTurn() async {
        // knit-next ADR 2026-10.y9qh's `arrivingFiles()`: the app's ring reads the kept bytes against the declared size.
        // The END and the engine's store run in one turn of the actor, so a landed file is never seen here, and Android's
        // `landing.all` has nothing to add on this port.
        let rig = rig()
        let photo = (0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 5) }
        let hash = BlobHash(of: photo)
        rig.stores.peers.upsert(
            PeerRecord(
                nodeId: bob.nodeId,
                name: "Bob",
                status: "",
                publicKey: bob.keys.bundle.encoded,
                updatedAt: 1,
                advertisedAvatarHash: hash
            ))
        await rig.mesh.start()
        await rig.mesh.process(.accepted(channel))
        await rig.mesh.process(.received(channel, hello(bob, capabilities: 0x2FFF)))
        let header = FileHeader(kind: .avatar, key: hash.string, mime: "image/jpeg", size: photo.count)
        let headerRecord = LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []
        await rig.mesh.process(.received(channel, headerRecord + (LinkRecord(.fileChunk, payload: Array(photo[..<1024])).encoded ?? [])))
        #expect(await rig.mesh.arrivingFiles == [hash: FileIntake.Reading(key: hash, bytes: 1024, total: photo.count)])
        let rest = (LinkRecord(.fileChunk, payload: Array(photo[1024...])).encoded ?? []) + (LinkRecord(.fileEnd).encoded ?? [])
        await rig.mesh.process(.received(channel, rest))
        #expect(await rig.mesh.arrivingFiles[hash] == nil)
        #expect(rig.stores.blobs.allHashes().contains(hash), "stored in the turn its END came in")
    }
}
