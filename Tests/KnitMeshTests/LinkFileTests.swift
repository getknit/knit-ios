import KnitCrypto
import KnitMesh
import KnitWire
import Testing

/// FILE records both ways on a link (ADR 2026-10.nh55): a file comes in through Android's receiver rules, and goes out
/// as Android streams one (`FramedLinkTest.sendFileEmitsHeaderChunkEndOnTheWire`,
/// `liveFrameInterleavesBetweenFileChunks` and `attachmentFileStreamsReassemblesAndFinalizes`).
@Suite struct LinkFileTests {
    private let channel = ChannelID(100)
    private let other = ChannelID(101)

    private func bytes(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }
    }

    private func records(_ kind: FileHeader.Kind, _ file: [UInt8], mime: String = "image/jpeg", chunk: Int = 16 * 1024) -> [UInt8] {
        let header = LinkRecord(
            .fileHeader, payload: LinkJSON.fileHeaderPayload(FileHeader(kind: kind, key: BlobHash(of: file).string, mime: mime)))
        let chunks = stride(from: 0, to: file.count, by: chunk).map { start in
            LinkRecord(.fileChunk, payload: Array(file[start..<min(start + chunk, file.count)]))
        }
        return ([header] + chunks + [LinkRecord(.fileEnd)]).compactMap(\.encoded).flatMap(\.self)
    }

    private func outbound(_ file: [UInt8], kind: FileHeader.Kind = .attachment, readable: Bool = true) -> OutboundFile {
        OutboundFile(kind: kind, hash: BlobHash(of: file), mime: "image/jpeg", size: file.count) { offset, count in
            readable ? Array(file[offset..<min(file.count, offset + count)]) : nil
        }
    }

    // MARK: In

    @Test func aWantedFileArrivesWholeAndGoesToTheEngine() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(40_000)
        rig.links.acceptFiles([BlobHash(of: file)])
        let events = rig.handle(.received(channel, records(.attachment, file)))
        #expect(
            events == [.file(InboundFile(from: LinkRig.low, kind: .attachment, hash: BlobHash(of: file), mime: "image/jpeg", bytes: file))])
        #expect(rig.links.filesReceived == 1)
        #expect(rig.links.arrivingFileKeys.isEmpty)
    }

    @Test func aPeersOwnPhotoIsKeptUnaskedButAnAttachmentOnlyWhenWanted() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let photo = bytes(500)
        let pushed = rig.handle(.received(channel, records(.avatar, photo)))
        #expect(pushed.count == 1, "the engine checks a push against the signed profile")
        let unasked = rig.handle(.received(channel, records(.attachment, bytes(500, seed: 2))))
        #expect(unasked.isEmpty)
        #expect(rig.links.filesRefused == 1)
        #expect(rig.links.neighbors.count == 1, "the link stays up")
    }

    @Test func aPhotoPastItsCapIsDropped() {
        var configuration = LinkManager.Configuration()
        configuration.maxAvatarFileBytes = 4
        let rig = LinkRig(local: LinkRig.high, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        #expect(rig.handle(.received(channel, records(.avatar, bytes(5)))).isEmpty)
        #expect(rig.links.filesRefused == 1)
    }

    @Test func partialFilesOnEveryLinkShareOneBudget() {
        var configuration = LinkManager.Configuration()
        configuration.maxBufferedFileBytes = 10
        let rig = LinkRig(local: LinkRig.high, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        _ = rig.accept(LinkRig.middle, on: other)
        let first = bytes(12)
        let second = bytes(12, seed: 2)
        rig.links.acceptFiles([BlobHash(of: first), BlobHash(of: second)])
        // Each file's header and first chunk of 6 bytes, then nothing more: the second link has only 4 bytes left.
        let partial = { (file: [UInt8]) in
            [
                LinkRecord(
                    .fileHeader,
                    payload: LinkJSON.fileHeaderPayload(FileHeader(kind: .attachment, key: BlobHash(of: file).string, mime: "x"))),
                LinkRecord(.fileChunk, payload: Array(file.prefix(6))),
            ].compactMap(\.encoded).flatMap(\.self)
        }
        _ = rig.handle(.received(channel, partial(first)))
        _ = rig.handle(.received(other, partial(second)))
        #expect(rig.links.arrivingFileKeys == [BlobHash(of: first)])
        #expect(rig.links.filesRefused == 1)
    }

    @Test func aChunkOrAnEndBeforeAnyHeaderIsIgnored() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let stray = [LinkRecord(.fileChunk, payload: [1, 2]), LinkRecord(.fileEnd)].compactMap(\.encoded).flatMap(\.self)
        #expect(rig.handle(.received(channel, stray)).isEmpty)
        #expect(rig.links.filesRefused == 0 && rig.links.filesReceived == 0)
        #expect(rig.links.neighbors.count == 1)
    }

    @Test func aFileStreamingInIsArrivingUntilItsEndOrItsLinkCloses() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(100)
        rig.links.acceptFiles([BlobHash(of: file)])
        let header = LinkRecord(
            .fileHeader, payload: LinkJSON.fileHeaderPayload(FileHeader(kind: .attachment, key: BlobHash(of: file).string, mime: "x")))
        _ = rig.handle(.received(channel, header.encoded ?? []))
        #expect(rig.links.arrivingFileKeys == [BlobHash(of: file)])
        _ = rig.handle(.closed(channel))
        #expect(rig.links.arrivingFileKeys.isEmpty, "a torn link clears its own state (`FramedLink.kt:183-190`)")
    }

    // MARK: Out

    @Test func aFileStreamsAsAHeaderChunksAndAnEndAtTheBlePace() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(40 * 1024)
        #expect(rig.links.sendFile(outbound(file), to: LinkRig.low))
        func fileRecords() -> [LinkRecord] {
            rig.radio.records(on: channel).filter { [.fileHeader, .fileChunk, .fileEnd].contains($0.tag) }
        }
        #expect(fileRecords().map(\.tag) == [.fileHeader, .fileChunk], "the header and a first chunk at once")
        #expect(rig.links.isFileInFlight(BlobHash(of: file), to: LinkRig.low))
        // 16 KiB at 28 KiB/s is 571 ms a chunk.
        #expect(rig.advance(570).isEmpty)
        #expect(fileRecords().count == 2)
        _ = rig.advance(1)
        #expect(fileRecords().count == 3)
        _ = rig.advance(571)
        #expect(fileRecords().count == 4, "8 KiB left")
        _ = rig.advance(284)
        #expect(fileRecords().count == 4)
        let ended = rig.advance(1)
        #expect(ended == [.fileSent(BlobHash(of: file), to: LinkRig.low)])
        let written = fileRecords()
        #expect(written.map(\.tag) == [.fileHeader, .fileChunk, .fileChunk, .fileChunk, .fileEnd])
        #expect(
            written.first?.payload
                == LinkJSON.fileHeaderPayload(FileHeader(kind: .attachment, key: BlobHash(of: file).string, mime: "image/jpeg")))
        #expect(written.filter { $0.tag == .fileChunk }.map(\.payload.count) == [16_384, 16_384, 8192])
        #expect(written.filter { $0.tag == .fileChunk }.flatMap(\.payload) == file)
        #expect(rig.links.filesSent == 1)
        #expect(!rig.links.isFileInFlight(BlobHash(of: file), to: LinkRig.low))
        let key = BlobHash(of: file).string.prefix(12)
        #expect(
            rig.log.all.contains("info link file ATTACHMENT \(key) to \(LinkRig.low): 40960 bytes in 1427 ms"), "as a file in is logged")
    }

    @Test func aReportingRadioGetsTheNextRecordOnlyOnceTheLastIsOut() {
        var configuration = LinkManager.Configuration()
        configuration.filePaceBytesPerSecond = 0
        let rig = LinkRig(local: LinkRig.high, reportsFileWrites: true, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(20 * 1024)
        _ = rig.links.sendFile(outbound(file), to: LinkRig.low)
        let fileCount = { rig.radio.records(on: channel).filter { $0.tag == .fileChunk || $0.tag == .fileEnd }.count }
        #expect(fileCount() == 1)
        #expect(rig.advance(60_000).isEmpty, "the pace has run, but the chunk is still in the radio's queue")
        #expect(fileCount() == 1)
        #expect(rig.links.nextDeadline != rig.clock.monotonicMilliseconds(), "the report brings the next chunk, not a timer")
        _ = rig.handle(.wroteFileRecord(channel))
        #expect(fileCount() == 2)
        _ = rig.handle(.wroteFileRecord(channel))
        #expect(fileCount() == 3, "the END")
        #expect(rig.links.filesSent == 0, "not sent until the END is out")
        #expect(rig.handle(.wroteFileRecord(channel)) == [.fileSent(BlobHash(of: file), to: LinkRig.low)])
    }

    @Test func framesWrittenMeanwhileGoOutBetweenTheChunks() {
        var configuration = LinkManager.Configuration()
        configuration.filePaceBytesPerSecond = 0
        let rig = LinkRig(local: LinkRig.high, reportsFileWrites: true, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        _ = rig.links.sendFile(outbound(bytes(20 * 1024)), to: LinkRig.low)
        rig.links.send(LinkRig.signedFrame("f1"), to: LinkRig.low)
        _ = rig.handle(.wroteFileRecord(channel))
        let tags = rig.radio.records(on: channel).map(\.tag).filter { $0 != .hello }
        #expect(tags == [.fileHeader, .fileChunk, .frame, .fileChunk])
    }

    @Test func oneFileStreamsAtATimeAndAFileAlreadyQueuedIsNotQueuedAgain() {
        var configuration = LinkManager.Configuration()
        configuration.filePaceBytesPerSecond = 0
        let rig = LinkRig(local: LinkRig.high, reportsFileWrites: true, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        let first = bytes(10)
        let second = bytes(10, seed: 2)
        _ = rig.links.sendFile(outbound(first), to: LinkRig.low)
        _ = rig.links.sendFile(outbound(second), to: LinkRig.low)
        #expect(rig.links.sendFile(outbound(first), to: LinkRig.low), "already on its way")
        #expect(rig.links.isFileInFlight(BlobHash(of: second), to: LinkRig.low), "waiting counts as on its way")
        #expect(rig.links.queuedFileCount == 2)
        let headers = { rig.radio.records(on: channel).filter { $0.tag == .fileHeader }.count }
        #expect(headers() == 1)
        #expect(rig.handle(.wroteFileRecord(channel)).isEmpty, "the chunk is out; the END goes")
        #expect(rig.handle(.wroteFileRecord(channel)) == [.fileSent(BlobHash(of: first), to: LinkRig.low)])
        #expect(headers() == 2, "the next file starts once the last is out")
        _ = rig.handle(.wroteFileRecord(channel))
        #expect(rig.handle(.wroteFileRecord(channel)) == [.fileSent(BlobHash(of: second), to: LinkRig.low)])
        #expect(rig.links.queuedFileCount == 0)
    }

    @Test func aFileThatFinishesInsideSendIsHandedOverAtTheNextTick() {
        var configuration = LinkManager.Configuration()
        configuration.filePaceBytesPerSecond = 0
        let rig = LinkRig(local: LinkRig.high, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(10)
        _ = rig.links.sendFile(outbound(file), to: LinkRig.low)
        #expect(rig.links.nextDeadline == rig.clock.monotonicMilliseconds(), "due at once")
        #expect(rig.advance(0) == [.fileSent(BlobHash(of: file), to: LinkRig.low)])
    }

    @Test func filesDueOnTwoLinksAtOnceGoOutInChannelOrder() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        _ = rig.accept(LinkRig.middle, on: other)
        let first = bytes(1000)
        let second = bytes(1000, seed: 2)
        // The later channel first: the order is the channels', not the sends'.
        _ = rig.links.sendFile(outbound(second), to: LinkRig.middle)
        _ = rig.links.sendFile(outbound(first), to: LinkRig.low)
        #expect(rig.links.queuedFileCount == 2)
        // 1000 bytes at 28 KiB/s is 34 ms, and then both ENDs are due.
        #expect(rig.advance(34) == [.fileSent(BlobHash(of: first), to: LinkRig.low), .fileSent(BlobHash(of: second), to: LinkRig.middle)])
        #expect(rig.links.queuedFileCount == 0)
    }

    @Test func aWriteReportWithNoFileStreamingChangesNothing() {
        let rig = LinkRig(local: LinkRig.high, reportsFileWrites: true)
        _ = rig.accept(LinkRig.low, on: channel)
        #expect(rig.handle(.wroteFileRecord(channel)).isEmpty)
        #expect(rig.handle(.wroteFileRecord(ChannelID(999))).isEmpty)
        #expect(rig.links.queuedFileCount == 0)
    }

    @Test func aFileForAPeerWithNoLinkGoesNowhere() {
        let rig = LinkRig(local: LinkRig.high)
        #expect(!rig.links.sendFile(outbound(bytes(10)), to: LinkRig.low))
        #expect(!rig.links.isFileInFlight(BlobHash(of: bytes(10)), to: LinkRig.low))
    }

    @Test func aFileWhoseBytesCannotBeReadEndsAtOnce() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        _ = rig.links.sendFile(outbound(bytes(10), readable: false), to: LinkRig.low)
        let tags = rig.radio.records(on: channel).map(\.tag).filter { $0 != .hello }
        #expect(tags == [.fileHeader, .fileEnd], "the receiver's hash check drops it, and keeps the link")
    }

    @Test func aClosedLinkDropsItsFilesWithoutCallingThemSent() {
        let rig = LinkRig(local: LinkRig.high, reportsFileWrites: true)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(10)
        _ = rig.links.sendFile(outbound(file), to: LinkRig.low)
        let closed = rig.handle(.closed(channel))
        #expect(!closed.contains(.fileSent(BlobHash(of: file), to: LinkRig.low)))
        #expect(rig.links.queuedFileCount == 0)
        #expect(rig.links.filesSent == 0)
    }
}
