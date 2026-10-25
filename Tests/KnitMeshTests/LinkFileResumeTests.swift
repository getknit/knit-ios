import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// A holder serving a resuming asker its tail (knit-next ADR 2026-10.wtyc, `FramedLink.kt:796-860`): the header declares
/// the tail and its offset, only the tail goes on the air, the window and the meter count from the offset, and the sent
/// line and ``LinkManager/filesResumedOut`` say so. Twins of `FramedLinkTest`'s resume cases.
@Suite struct LinkFileResumeTests {
    private let channel = ChannelID(100)
    /// A HELLO that carries `CAP_BLOB_HAVE`: the peer reports a file's progress.
    private let reporting: Capabilities = 0x2FFF

    private func bytes(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }
    }

    private func outbound(_ file: [UInt8], from start: Int) -> OutboundFile {
        OutboundFile(kind: .attachment, hash: BlobHash(of: file), mime: "image/jpeg", size: file.count, start: start) { offset, count in
            Array(file[offset..<min(file.count, offset + count)])
        }
    }

    @Test func sendFileFromAnOffsetStreamsOnlyTheTailAndSaysSo() {
        // knit-next ADR 2026-10.wtyc (`FramedLinkTest.sendFileFromAnOffsetStreamsOnlyTheTailAndSaysSo`): the header
        // declares the tail and where it starts, only the tail goes on the air, and the line and the count say so.
        var configuration = LinkManager.Configuration()
        configuration.filePaceBudgetBytesPerSecond = 0
        let rig = LinkRig(local: LinkRig.high, reportsFileWrites: true, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(3000)
        let hash = BlobHash(of: file)
        #expect(rig.links.sendFile(outbound(file, from: 1000), to: LinkRig.low))
        var finished: [LinkManager.Event] = []
        for _ in 0..<4 {
            finished += rig.handle(.wroteFileRecord(channel))
        }
        let written = rig.radio.records(on: channel).filter { [.fileHeader, .fileChunk, .fileEnd].contains($0.tag) }
        #expect(written.map(\.tag) == [.fileHeader, .fileChunk, .fileEnd])
        #expect(
            written.first?.payload
                == LinkJSON.fileHeaderPayload(
                    FileHeader(kind: .attachment, key: hash.string, mime: "image/jpeg", size: 2000, offset: 1000)),
            "the size is the tail's, and the offset where it starts")
        #expect(written.filter { $0.tag == .fileChunk }.flatMap(\.payload) == Array(file[1000...]), "only the tail")
        #expect(finished == [.fileSent(hash, to: LinkRig.low)])
        #expect(rig.links.filesSent == 1)
        #expect(rig.links.filesResumedOut == 1)
        let key = hash.string.prefix(12)
        #expect(
            rig.log.all.contains("info link file ATTACHMENT \(key) to \(LinkRig.low): 2000 bytes in 0 ms resumed at 1000"),
            "the tail's bytes, and where it resumed last")
    }

    @Test func aCompletePrefixGetsAnEmptyTailAndEnds() {
        // `FramedLinkTest.aCompletePrefixGetsAnEmptyTailAndAnOffsetPastTheEndTheWholeFile`'s first half: an asker that
        // kept the whole blob gets a header of size 0, no chunk, and the END, gated on the radio's reports as any file.
        // An offset past the end is a whole file before it gets here (`OutboundFile.start(asked:size:)`).
        let rig = LinkRig(local: LinkRig.high, reportsFileWrites: true)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(3000)
        let hash = BlobHash(of: file)
        #expect(rig.links.sendFile(outbound(file, from: 3000), to: LinkRig.low))
        #expect(rig.links.filesSent == 0, "the END is written, not yet out")
        #expect(rig.handle(.wroteFileRecord(channel)) == [.fileSent(hash, to: LinkRig.low)], "the END is out")
        let written = rig.radio.records(on: channel).filter { [.fileHeader, .fileChunk, .fileEnd].contains($0.tag) }
        #expect(written.map(\.tag) == [.fileHeader, .fileEnd], "no chunk, just the end")
        #expect(
            written.first?.payload
                == LinkJSON.fileHeaderPayload(FileHeader(kind: .attachment, key: hash.string, mime: "image/jpeg", size: 0, offset: 3000)))
        #expect(rig.links.filesSent == 1)
        #expect(rig.links.filesResumedOut == 1)
        #expect(!rig.links.isFileInFlight(hash, to: LinkRig.low))
        let line = "info link file ATTACHMENT \(hash.string.prefix(12)) to \(LinkRig.low): 0 bytes in 0 ms"
        #expect(rig.log.all.contains { $0.hasPrefix(line) && $0.hasSuffix(" resumed at 3000") })
    }

    @Test func aResumedFeedsWindowAndMeterReadItsTailAsAWholeFileOfTheTailsLength() {
        // An Android asker reports what it holds of the whole blob, its prefix included (`FeedWindow.kt:210-226`): a
        // 40 KiB tail of 60 KiB, reported from the offset, is clocked and read as a whole 40 KiB file reported from 0.
        let tail = 40 * 1024
        let start = 20 * 1024
        func feed(_ file: [UInt8], from start: Int) -> (chunks: [[Int]], reading: FeedReading?) {
            let rig = LinkRig(local: LinkRig.high)
            _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
            let hash = BlobHash(of: file)
            _ = rig.links.sendFile(outbound(file, from: start), to: LinkRig.low)
            let chunks = { rig.radio.records(on: channel).filter { $0.tag == .fileChunk }.map(\.payload.count) }
            var seen = [chunks()]
            for (held, at) in [(0, 250), (8192, 500), (16_384, 750)] {
                _ = rig.advance(250)
                rig.links.fileProgressReported(from: LinkRig.low, hash: hash, held: Int64(start + held), milliseconds: Int64(at))
                seen.append(chunks())
            }
            return (seen, rig.links.fileFeed(of: hash, to: LinkRig.low))
        }
        let whole = feed(bytes(tail, seed: 2), from: 0)
        let resumed = feed(bytes(start, seed: 3) + bytes(tail, seed: 2), from: start)
        #expect(whole.chunks[0] == [4096, 4096], "the starting window")
        #expect(resumed.chunks == whole.chunks, "the prefix alone frees nothing, and each report frees what it would")
        #expect(resumed.reading != nil)
        #expect(resumed.reading == whole.reading, "what remains, and its ETA, are the tail's")
    }

    @Test func aResumedTailStartsAtItsOffsetOnTheAir() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        let file = bytes(60 * 1024)
        _ = rig.links.sendFile(outbound(file, from: 20 * 1024), to: LinkRig.low)
        let first = rig.radio.records(on: channel).first { $0.tag == .fileChunk }
        #expect(first?.payload == Array(file[20 * 1024..<24 * 1024]))
    }
}
