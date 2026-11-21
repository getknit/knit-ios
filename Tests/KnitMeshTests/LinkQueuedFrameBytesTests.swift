import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// What waits on a link that is not a file's (`queuedFrameBytes(to:)`, the `custody-carry-policy` contract, §2's
/// "Unwritten"): custody compares it to release a round, so a photo streaming to the peer never holds the answer off.
/// The radio's level is set by hand on the fake, as a real radio's queue would read: here 1,000 bytes written before the
/// file's first chunk, the HELLO and the file's header among them.
@Suite struct LinkQueuedFrameBytesTests {
    private let channel = ChannelID(60)
    private let before: Int64 = 1000

    private func outbound(_ file: [UInt8]) -> OutboundFile {
        OutboundFile(kind: .attachment, hash: BlobHash(of: file), mime: "image/jpeg", size: file.count) { offset, count in
            Array(file[offset..<min(file.count, offset + count)])
        }
    }

    private func bytes(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed }
    }

    /// A rig streaming a file, and its first chunk's record length.
    private struct Streaming {
        let rig: LinkRig
        let file: [UInt8]
        let chunk: Int
    }

    /// A link to `LinkRig.low` streaming a 40 KiB file, unpaced, with its first chunk handed over at `before` written.
    private func streaming(reportsFileWrites: Bool = true) -> Streaming {
        var configuration = LinkManager.Configuration()
        configuration.filePaceBudgetBytesPerSecond = 0
        let rig = LinkRig(local: LinkRig.high, reportsFileWrites: reportsFileWrites, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        rig.radio.setLevel(OutboxLevel(queuedBytes: 0, writtenBytes: before), on: channel)
        let file = bytes(40 * 1024)
        _ = rig.links.sendFile(outbound(file), to: LinkRig.low)
        return Streaming(rig: rig, file: file, chunk: lastChunk(rig))
    }

    private func lastChunk(_ rig: LinkRig) -> Int {
        rig.radio.records(on: channel).last { $0.tag == .fileChunk }.map { LinkRecord.headerBytes + $0.payload.count } ?? 0
    }

    @Test func aChunkUnwrittenIsLeftOutAndTheFramesBehindItCount() {
        let streamed = streaming()
        let rig = streamed.rig
        let chunk = streamed.chunk
        #expect(chunk > CustodySync.roundBytes, "a whole chunk would hold the answer off by itself")
        rig.links.send(LinkRig.signedFrame("behind"), to: LinkRig.low)
        rig.radio.setLevel(OutboxLevel(queuedBytes: chunk + 500, writtenBytes: before), on: channel)
        #expect(rig.links.queuedBytes(to: LinkRig.low) == chunk + 500)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 500, "the frame queued behind the chunk")
        rig.radio.setLevel(OutboxLevel(queuedBytes: chunk - 8192 + 500, writtenBytes: before + 8192), on: channel)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 500, "half the chunk out")
        rig.radio.setLevel(OutboxLevel(queuedBytes: 500, writtenBytes: before + Int64(chunk)), on: channel)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 500, "the chunk out, its report not yet in")
    }

    @Test func theNextChunkIsLeftOutFromWhereItEnds() {
        let streamed = streaming()
        let rig = streamed.rig
        let first = streamed.chunk
        let written = before + Int64(first)
        // The radio counts the next chunk as the report hands it over, behind 500 bytes of frames.
        let second = first
        rig.radio.setLevel(OutboxLevel(queuedBytes: 500 + second, writtenBytes: written), on: channel)
        _ = rig.handle(.wroteFileRecord(channel))
        #expect(lastChunk(rig) == second)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 500)
        rig.radio.setLevel(OutboxLevel(queuedBytes: second, writtenBytes: written + 500), on: channel)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 0, "the frames ahead of it out")
    }

    @Test func nothingIsLeftOutOnceTheStreamEnds() {
        let streamed = streaming()
        let rig = streamed.rig
        let file = streamed.file
        var finished: [LinkManager.Event] = []
        for _ in 0..<8 where finished.isEmpty {
            finished = rig.handle(.wroteFileRecord(channel))
        }
        #expect(finished == [.fileSent(BlobHash(of: file), to: LinkRig.low)])
        #expect(rig.links.feeds[channel]?.streaming == nil)
        rig.radio.setLevel(OutboxLevel(queuedBytes: 700, writtenBytes: 90_000), on: channel)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 700)
    }

    @Test func aWithdrawnCopyLeavesTheStreamingOnesCountAndAddsNone() {
        let streamed = streaming()
        let rig = streamed.rig
        let file = streamed.file
        let chunk = streamed.chunk
        let waiting = bytes(30 * 1024, seed: 9)
        _ = rig.links.sendFile(outbound(waiting), to: LinkRig.low)
        #expect(rig.links.cancelQueuedFile(BlobHash(of: waiting), to: LinkRig.low))
        rig.radio.setLevel(OutboxLevel(queuedBytes: chunk + 500, writtenBytes: before), on: channel)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 500, "the streaming copy goes on, and is still left out")
        var finished: [LinkManager.Event] = []
        for _ in 0..<8 where finished.isEmpty {
            finished = rig.handle(.wroteFileRecord(channel))
        }
        #expect(finished == [.fileSent(BlobHash(of: file), to: LinkRig.low)])
        #expect(rig.links.feeds[channel]?.streaming == nil, "the withdrawn copy never starts")
        rig.radio.setLevel(OutboxLevel(queuedBytes: 500, writtenBytes: before + 90_000), on: channel)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 500, "once its records are sent, nothing is left out")
    }

    @Test func aClosedLinkTakesItsRecordsWithItAndALinkReplacingItStartsAtNone() {
        let streamed = streaming()
        let rig = streamed.rig
        let chunk = streamed.chunk
        rig.radio.setLevel(OutboxLevel(queuedBytes: chunk, writtenBytes: before), on: channel)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 0)
        _ = rig.handle(.closed(channel))
        #expect(rig.links.feeds[channel] == nil)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 0, "unlinked")
        let next = ChannelID(61)
        _ = rig.accept(LinkRig.low, on: next)
        rig.radio.setLevel(OutboxLevel(queuedBytes: chunk, writtenBytes: before), on: next)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == chunk, "the old link's chunk is not this one's")
    }

    @Test func aStopTakesEveryLinksRecords() {
        let streamed = streaming()
        let rig = streamed.rig
        _ = rig.links.stop()
        #expect(rig.links.feeds.isEmpty)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 0)
    }

    @Test func neverBelowZero() {
        let streamed = streaming()
        let rig = streamed.rig
        let chunk = streamed.chunk
        rig.radio.setLevel(OutboxLevel(queuedBytes: 300, writtenBytes: before), on: channel)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 0, "less queued than the chunk left: none of it frames")
        rig.radio.setLevel(OutboxLevel(), on: channel)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 0)
        #expect(chunk > 300)
    }

    @Test func aReportWithNothingOutLeavesTheLevelWhole() {
        var configuration = LinkManager.Configuration()
        configuration.filePaceBudgetBytesPerSecond = 0
        let rig = LinkRig(local: LinkRig.high, reportsFileWrites: true, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        rig.radio.setLevel(OutboxLevel(queuedBytes: 900, writtenBytes: before), on: channel)
        _ = rig.handle(.wroteFileRecord(channel))
        _ = rig.handle(.wroteFileRecord(channel))
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 900)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.middle) == 0, "unlinked")
    }

    /// A radio that reports no FILE writes has no queue of its own and reads nothing queued (``Radio/outboxLevel(on:)``'s
    /// default), so there is no file window in its count to leave out, and the read is the level's.
    @Test func aRadioThatReportsNoWritesLeavesNothingOut() {
        let streamed = streaming(reportsFileWrites: false)
        let rig = streamed.rig
        let chunk = streamed.chunk
        #expect(rig.links.feeds[channel]?.unwritten.records.isEmpty ?? true, "no record is kept unreported")
        rig.radio.setLevel(OutboxLevel(queuedBytes: chunk, writtenBytes: before), on: channel)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == chunk)
    }

    @Test func aTransportThatStreamsNoFilesAnswersItsQueuedBytes() {
        let transport = RecordingTransport()
        transport.unwritten[LinkRig.low] = 4321
        #expect(transport.queuedFrameBytes(to: LinkRig.low) == 4321)
        #expect(transport.queuedFrameBytes(to: LinkRig.high) == 0)
    }

    // MARK: The buffer below the link

    @Test func whatTheSocketHoldsCountsAndAChunkInItStaysAFiles() {
        let streamed = streaming()
        let rig = streamed.rig
        let chunk = streamed.chunk
        let written = before + Int64(chunk)
        rig.radio.setLevel(OutboxLevel(queuedBytes: 500, writtenBytes: written, belowBytes: chunk + 200), on: channel)
        #expect(rig.links.queuedBytes(to: LinkRig.low) == chunk + 700, "the queue and the socket")
        // The socket holds 200 bytes of frames written before the chunk, then all of the chunk.
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 700)
        rig.radio.setLevel(OutboxLevel(queuedBytes: 0, writtenBytes: written + 500, belowBytes: 500), on: channel)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 500, "the chunk sent, the frames behind it in the socket")
    }

    @Test func withNoFileStreamingTheSocketsBytesAreFrames() {
        var configuration = LinkManager.Configuration()
        configuration.filePaceBudgetBytesPerSecond = 0
        let rig = LinkRig(local: LinkRig.high, reportsFileWrites: true, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        rig.radio.setLevel(OutboxLevel(queuedBytes: 100, writtenBytes: before, belowBytes: 900), on: channel)
        #expect(rig.links.queuedBytes(to: LinkRig.low) == 1000)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 1000)
    }

    @Test func aChunkReportedWhileTheSocketHoldsItStaysAFilesPastTheStreamsEnd() {
        let streamed = streaming()
        let rig = streamed.rig
        var written = before
        var finished: [LinkManager.Event] = []
        for _ in 0..<8 where finished.isEmpty {
            // Each record taken whole by the socket, and still all there as it is reported.
            let record = lastRecord(rig)
            written += Int64(record)
            rig.radio.setLevel(OutboxLevel(queuedBytes: 0, writtenBytes: written, belowBytes: Int(written - before)), on: channel)
            #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 0, "the socket holds only the file")
            finished = rig.handle(.wroteFileRecord(channel))
        }
        #expect(finished == [.fileSent(BlobHash(of: streamed.file), to: LinkRig.low)])
        rig.radio.setLevel(OutboxLevel(queuedBytes: 0, writtenBytes: written, belowBytes: Int(written - before)), on: channel)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 0, "its last records are still the file's after its END")
        rig.radio.setLevel(OutboxLevel(queuedBytes: 0, writtenBytes: written + 400, belowBytes: 400), on: channel)
        #expect(rig.links.queuedFrameBytes(to: LinkRig.low) == 400, "the file sent, the frames behind it in the socket")
    }

    private func lastRecord(_ rig: LinkRig) -> Int {
        rig.radio.records(on: channel).last { $0.tag == .fileChunk || $0.tag == .fileEnd }.map { LinkRecord.headerBytes + $0.payload.count }
            ?? 0
    }
}
