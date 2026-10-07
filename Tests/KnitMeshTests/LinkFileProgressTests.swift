import KnitCrypto
import KnitMesh
import KnitWire
import Testing

/// A file streaming in is reported back to its sender every two seconds of chunks (knit-next ADR 2026-10.nsr7, ADR
/// 2026-10.ds45), as `FramedLinkTest.aFileStreamingInIsReportedEveryTwoSecondsOfChunks` has Android's link report one.
@Suite struct LinkFileProgressTests {
    private let channel = ChannelID(100)
    private let other = ChannelID(101)

    private func bytes(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }
    }

    private func header(_ file: [UInt8], kind: FileHeader.Kind = .attachment) -> [UInt8] {
        let header = FileHeader(kind: kind, key: BlobHash(of: file).string, mime: "image/jpeg", size: file.count)
        return LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []
    }

    private func chunk(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        LinkRecord(.fileChunk, payload: Array(bytes)).encoded ?? []
    }

    @Test func aKeptFileStreamingInIsReportedEveryTwoSecondsOfChunks() {
        // How much is in, by our own clock since its header, after the chunk that crosses each two seconds. Nothing
        // arrives in a stall, so nothing is reported.
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(8192)
        let hash = BlobHash(of: file)
        rig.links.acceptFiles([hash])
        #expect(rig.handle(.received(channel, header(file))).isEmpty)
        #expect(rig.handle(.received(channel, chunk(file[0..<1024]))).isEmpty, "not yet two seconds in")
        rig.clock.advance(LinkManager.progressEveryMilliseconds)
        let first = rig.handle(.received(channel, chunk(file[1024..<2048])))
        #expect(first == [.fileProgress(FileProgress(from: LinkRig.low, hash: hash, held: 2048, milliseconds: 2000))])
        rig.clock.advance(1999)
        #expect(rig.handle(.received(channel, chunk(file[2048..<3072]))).isEmpty, "inside two seconds of the last report")
        rig.clock.advance(30_000)
        let late = rig.handle(.received(channel, chunk(file[3072..<4096])))
        #expect(late == [.fileProgress(FileProgress(from: LinkRig.low, hash: hash, held: 4096, milliseconds: 33_999))])
        rig.clock.advance(5000)
        let ended = rig.handle(.received(channel, (chunk(file[4096...]) + (LinkRecord(.fileEnd).encoded ?? []))))
        #expect(ended.count == 2, "the last chunk is reported, then the file lands")
        #expect(ended.last == .file(InboundFile(from: LinkRig.low, kind: .attachment, hash: hash, mime: "image/jpeg", bytes: file)))
    }

    @Test func aSkippedFileIsNeverReportedAndEachHeaderStartsItsOwnClock() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let unasked = bytes(4096, seed: 2)
        _ = rig.handle(.received(channel, header(unasked)))
        rig.clock.advance(5000)
        #expect(rig.handle(.received(channel, chunk(unasked[0..<1024]))).isEmpty, "nobody asked for it, so nothing is kept")
        let file = bytes(4096)
        rig.links.acceptFiles([BlobHash(of: file)])
        _ = rig.handle(.received(channel, header(file)))
        rig.clock.advance(1999)
        #expect(rig.handle(.received(channel, chunk(file[0..<1024]))).isEmpty, "counted from its own header")
        rig.clock.advance(1)
        let report = rig.handle(.received(channel, chunk(file[1024..<2048])))
        #expect(report == [.fileProgress(FileProgress(from: LinkRig.low, hash: BlobHash(of: file), held: 2048, milliseconds: 2000))])
        _ = rig.handle(.closed(channel))
        _ = rig.accept(LinkRig.low, on: other)
        rig.clock.advance(5000)
        #expect(rig.handle(.received(other, chunk(file[2048..<3072]))).isEmpty, "a torn link took its file and its clock")
    }
}
