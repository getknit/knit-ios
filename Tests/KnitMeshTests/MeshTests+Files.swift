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

    // MARK: Resuming a cut photo (knit-ios #2)

    /// A mesh whose kept prefixes are `partials`, the log it writes, and a DM from bob in its store naming `photo`.
    private func resumeRig(_ partials: MemoryPartialBlobStore, photo: BlobHash) -> (rig: Rig, log: RecordingLog) {
        let radio = FakeRadio(advertisesServiceData: false)
        let clock = ManualClock(wall: EngineFixture.start, monotonic: 1000)
        let stores = MeshStores.inMemory()
        let log = RecordingLog()
        stores.conversations.accept(bob.nodeId.string)
        stores.messages.save(
            MessageRecord(
                id: frameIdOf("dm-photo"),
                senderId: bob.nodeId,
                recipientId: alice.nodeId,
                conversationId: bob.nodeId.string,
                body: "",
                sentAt: EngineFixture.start,
                attachment: MessageAttachment(hash: photo)
            ))
        let mesh = Mesh(
            identity: alice.keys,
            deviceTag: nil,
            stores: stores,
            radio: radio,
            clock: clock,
            random: SeededGenerator(seed: 11),
            log: log,
            partials: partials
        )
        return (Rig(mesh: mesh, radio: radio, clock: clock, stores: stores), log)
    }

    /// The offsets of the photo asks written to bob, in order.
    private func offsetsAsked(_ rig: Rig) -> [Int64?] {
        rig.radio.frames(on: channel).compactMap { try? RelayEnvelope(decoding: $0.signed) }.filter { $0.type == .blobRequest }
            .compactMap { try? BlobRequestContent(decoding: $0.payload).offset }
    }

    /// Bob streams `bytes` as the blob `hash` from `offset`, the header declaring the tail's size, as Android's
    /// `streamFile` does, in records of 10 kB, then its END.
    private func stream(_ rig: Rig, _ bytes: ArraySlice<UInt8>, of hash: BlobHash, offset: Int?, declared: Int? = nil) async {
        let header = FileHeader(kind: .attachment, key: hash.string, mime: "image/jpeg", size: declared ?? bytes.count, offset: offset)
        await rig.mesh.process(.received(channel, LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []))
        for start in stride(from: bytes.startIndex, to: bytes.endIndex, by: 10_000) {
            let chunk = Array(bytes[start..<min(start + 10_000, bytes.endIndex)])
            await rig.mesh.process(.received(channel, LinkRecord(.fileChunk, payload: chunk).encoded ?? []))
        }
        await rig.mesh.process(.received(channel, LinkRecord(.fileEnd).encoded ?? []))
    }

    private var resumedPhoto: [UInt8] { (0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) } }

    @Test func aKeptPrefixIsAskedForAndTheResumedTailLandsWhole() async {
        // What a cut left (`FileIntake.cut`, kept by the link's teardown): the next ask names it, a holder that reads the
        // offset streams the rest, and the splice is the photo, stored, its prefix dropped.
        let photo = resumedPhoto
        let hash = BlobHash(of: photo)
        let partials = MemoryPartialBlobStore()
        let (rig, log) = resumeRig(partials, photo: hash)
        await rig.mesh.start()
        #expect(partials.keep(hash, bytes: Array(photo[..<20_000]), basedOn: nil, now: 1000))
        await linkBob(rig)
        #expect(offsetsAsked(rig) == [20_000], "the ask names the bytes kept")
        await stream(rig, photo[20_000...], of: hash, offset: 20_000)
        #expect(rig.stores.blobs.bytes(of: hash) == photo)
        #expect(partials.length(hash) == 0, "landed: nothing left to resume")
        #expect(await rig.mesh.files.resumedIn == 1)
        #expect(log.all.contains("info link file ATTACHMENT \(hash.string.prefix(12)) from \(bob.nodeId): 20000 bytes resumed at 20000"))
    }

    @Test func anOffsetIgnoringHoldersWholeFileLandsAndDropsThePrefix() async {
        // An older build, or Android's holder for an offset it will not serve: the whole file, from byte 0.
        let photo = resumedPhoto
        let hash = BlobHash(of: photo)
        let partials = MemoryPartialBlobStore()
        let (rig, _) = resumeRig(partials, photo: hash)
        await rig.mesh.start()
        partials.keep(hash, bytes: Array(photo[..<20_000]), basedOn: nil, now: 1000)
        await linkBob(rig)
        await stream(rig, photo[...], of: hash, offset: nil)
        #expect(rig.stores.blobs.bytes(of: hash) == photo)
        #expect(partials.length(hash) == 0)
        #expect(await rig.mesh.files.resumedIn == 0)
    }

    @Test func anOffsetPastAShrunkPrefixIsRefusedAndItsTailSkipped() async {
        // The holder answers an ask from before a sibling's failed splice dropped the prefix this one shrank to.
        let photo = resumedPhoto
        let hash = BlobHash(of: photo)
        let partials = MemoryPartialBlobStore()
        let (rig, log) = resumeRig(partials, photo: hash)
        await rig.mesh.start()
        partials.keep(hash, bytes: Array(photo[..<20_000]), basedOn: nil, now: 1000)
        await linkBob(rig)
        await stream(rig, photo[30_000...], of: hash, offset: 30_000)
        #expect(!rig.stores.blobs.contains(hash))
        #expect(partials.length(hash) == 20_000, "the prefix is untouched")
        #expect(await rig.mesh.files.refused == 1)
        #expect(log.all.contains("info link \(channel) file \(hash.string.prefix(12)) refused resumed at 30000: 20000B kept"))
    }

    @Test func aCompletePrefixFinishesOnAnEmptyTail() async {
        // The cut fell between the last chunk and the END: the ask names the whole length, and a header and its END land it.
        let photo = resumedPhoto
        let hash = BlobHash(of: photo)
        let partials = MemoryPartialBlobStore()
        let (rig, _) = resumeRig(partials, photo: hash)
        await rig.mesh.start()
        partials.keep(hash, bytes: photo, basedOn: nil, now: 1000)
        await linkBob(rig)
        #expect(offsetsAsked(rig) == [40_000])
        await stream(rig, [][...], of: hash, offset: 40_000)
        #expect(rig.stores.blobs.bytes(of: hash) == photo)
    }

    @Test func aSpliceThatFailsItsHashIsAskedForAgainFromZeroAtOnce() async {
        // The landed file leaves the link before the re-ask reads it (`fileTaken` first), so a real link's landing never
        // keeps the ask from 0 quiet.
        let photo = resumedPhoto
        let hash = BlobHash(of: photo)
        let partials = MemoryPartialBlobStore()
        let (rig, _) = resumeRig(partials, photo: hash)
        await rig.mesh.start()
        partials.keep(hash, bytes: [UInt8](repeating: 0, count: 20_000), basedOn: nil, now: 1000)
        await linkBob(rig)
        await stream(rig, photo[20_000...], of: hash, offset: 20_000)
        #expect(!rig.stores.blobs.contains(hash))
        #expect(partials.length(hash) == 0, "the prefix may be what was wrong")
        #expect(offsetsAsked(rig) == [20_000, nil], "asked again, for the whole blob, at once")
        #expect(await rig.mesh.blobs.splicesRefused == 1)
    }

    @Test func aStartOrAStopPurgesTheKeptPrefixes() async {
        // Session-scoped (`MeshManager.kt:997-998`): a prefix is one transfer's, and a start or a stop ends the session.
        let hash = BlobHash(of: resumedPhoto)
        let partials = MemoryPartialBlobStore()
        let (rig, _) = resumeRig(partials, photo: hash)
        partials.keep(hash, bytes: Array(resumedPhoto[..<20_000]), basedOn: nil, now: 0)
        await rig.mesh.start()
        #expect(partials.length(hash) == 0, "a dead session's prefix")
        partials.keep(hash, bytes: Array(resumedPhoto[..<20_000]), basedOn: nil, now: 1000)
        await rig.mesh.stop()
        #expect(partials.length(hash) == 0)
    }

    @Test func aMeshWithNoStoreGivenKeepsACutInMemoryAndLogsIt() async {
        // The default every host but the app takes (knit-peer, the demo): the store in memory, its lines the mesh's.
        let photo = resumedPhoto
        let hash = BlobHash(of: photo)
        let radio = FakeRadio(advertisesServiceData: false)
        let stores = MeshStores.inMemory()
        let log = RecordingLog()
        stores.conversations.accept(bob.nodeId.string)
        stores.messages.save(
            MessageRecord(
                id: frameIdOf("dm-photo"),
                senderId: bob.nodeId,
                recipientId: alice.nodeId,
                conversationId: bob.nodeId.string,
                body: "",
                sentAt: EngineFixture.start,
                attachment: MessageAttachment(hash: hash)
            ))
        let mesh = Mesh(
            identity: alice.keys,
            deviceTag: nil,
            stores: stores,
            radio: radio,
            clock: ManualClock(wall: EngineFixture.start, monotonic: 1000),
            random: SeededGenerator(seed: 11),
            log: log
        )
        let rig = Rig(mesh: mesh, radio: radio, clock: ManualClock(wall: EngineFixture.start, monotonic: 1000), stores: stores)
        await mesh.start()
        await linkBob(rig)
        let header = FileHeader(kind: .attachment, key: hash.string, mime: "image/jpeg", size: photo.count)
        await mesh.process(.received(channel, LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []))
        await mesh.process(.received(channel, LinkRecord(.fileChunk, payload: Array(photo[..<20_000])).encoded ?? []))
        await mesh.process(.closed(channel))
        #expect(log.all.contains("info mesh partial \(hash.string.prefix(12)) kept 20000B"))
    }
}
