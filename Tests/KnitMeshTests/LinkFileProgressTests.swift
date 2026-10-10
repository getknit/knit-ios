import KnitCrypto
import KnitMesh
import KnitWire
import Testing

/// A file streaming in is reported back to its sender (knit-next ADR 2026-10.nsr7, ADR 2026-10.ds45): at the window's
/// cadence, as `FramedLinkTest.aWindowedSenderIsReportedToOnceMoreAfterChunksThatAllLandedInsideOneInterval` and
/// `aSendersSmallestChunkLandedIsReportedOnTheChunkThatCompletesIt` have Android's link report one (knit-next ADR
/// 2026-10.5buf, ADR 2026-10.xwjc), or with the switch off every two seconds of chunks, as
/// `aFileStreamingInIsReportedEveryReportIntervalOfChunks` does.
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

    /// A link manager with the window's switch off, which reports every two seconds.
    private func pacedRig() -> LinkRig {
        var configuration = LinkManager.Configuration()
        configuration.feedWindow = false
        return LinkRig(local: LinkRig.high, configuration: configuration)
    }

    private func progress(_ file: [UInt8], held: Int64, at milliseconds: Int64) -> LinkManager.Event {
        .fileProgress(FileProgress(from: LinkRig.low, hash: BlobHash(of: file), held: held, milliseconds: milliseconds))
    }

    // MARK: The window's cadence

    @Test func aChunkThatBringsASendersSmallestChunkIsReportedAtOnce() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(8192)
        rig.links.acceptFiles([BlobHash(of: file)])
        _ = rig.handle(.received(channel, header(file)))
        rig.clock.advance(100)
        #expect(rig.handle(.received(channel, chunk(file[0..<1024]))).isEmpty, "half a smallest chunk, and inside half a second")
        #expect(rig.handle(.received(channel, chunk(file[1024..<2048]))) == [progress(file, held: 2048, at: 100)])
        #expect(rig.handle(.received(channel, chunk(file[2048..<6144]))) == [progress(file, held: 6144, at: 100)], "and on each one")
    }

    @Test func chunksThatAllLandedInsideOneIntervalAreReportedOnceMoreAfterIt() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(8192)
        rig.links.acceptFiles([BlobHash(of: file)])
        _ = rig.handle(.received(channel, header(file)))
        let start = rig.clock.monotonicMilliseconds()
        rig.clock.advance(100)
        #expect(rig.handle(.received(channel, chunk(file[0..<1024]))).isEmpty)
        #expect(rig.links.nextDeadline == start + LinkManager.windowedProgressEveryMilliseconds, "the trailing report")
        #expect(rig.advance(400) == [progress(file, held: 1024, at: 500)])
        #expect(rig.links.nextDeadline == start + 1000, "armed again while it could owe one")
        #expect(rig.advance(500).isEmpty, "a stall sends nothing")
        #expect(rig.links.nextDeadline == nil, "and nothing more is armed")
        rig.clock.advance(100)
        #expect(rig.handle(.received(channel, chunk(file[1024..<1536]))) == [progress(file, held: 1536, at: 1100)], "half a second since")
    }

    @Test func aTrailingReportWaitsOutHalfASecondFromTheLastReport() {
        // A report on a chunk moves the clock the armed trailing report counts from (`RxReports.trail`'s `left`).
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let file = bytes(8192)
        rig.links.acceptFiles([BlobHash(of: file)])
        _ = rig.handle(.received(channel, header(file)))
        let start = rig.clock.monotonicMilliseconds()
        rig.clock.advance(100)
        _ = rig.handle(.received(channel, chunk(file[0..<1024])))
        rig.clock.advance(200)
        #expect(rig.handle(.received(channel, chunk(file[1024..<3072]))) == [progress(file, held: 3072, at: 300)])
        rig.clock.advance(100)
        #expect(rig.handle(.received(channel, chunk(file[3072..<3584]))).isEmpty)
        #expect(rig.advance(100).isEmpty, "armed at 500, but the last report was at 300")
        #expect(rig.links.nextDeadline == start + 800)
        #expect(rig.advance(300) == [progress(file, held: 3584, at: 800)])
    }

    @Test func trailingReportsDueOnTwoLinksAtOnceGoInChannelOrder() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        _ = rig.accept(LinkRig.middle, on: other)
        let first = bytes(4096)
        let second = bytes(4096, seed: 3)
        rig.links.acceptFiles([BlobHash(of: first), BlobHash(of: second)])
        // The later channel first: the order is the channels', not the files'.
        _ = rig.handle(.received(other, header(second)))
        _ = rig.handle(.received(channel, header(first)))
        _ = rig.handle(.received(other, chunk(second[0..<1024])))
        _ = rig.handle(.received(channel, chunk(first[0..<1024])))
        let reports = rig.advance(LinkManager.windowedProgressEveryMilliseconds)
        #expect(
            reports == [
                progress(first, held: 1024, at: 500),
                .fileProgress(FileProgress(from: LinkRig.middle, hash: BlobHash(of: second), held: 1024, milliseconds: 500)),
            ])
    }

    @Test func aNewHeaderStartsItsOwnClockAndDropsTheTrailingReport() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let first = bytes(4096)
        let second = bytes(4096, seed: 3)
        rig.links.acceptFiles([BlobHash(of: first), BlobHash(of: second)])
        _ = rig.handle(.received(channel, header(first)))
        _ = rig.handle(.received(channel, chunk(first[0..<1024])))
        _ = rig.handle(.received(channel, header(second)))
        #expect(rig.links.nextDeadline == nil, "the first file's trailing report went with it")
        rig.clock.advance(600)
        #expect(rig.handle(.received(channel, chunk(second[0..<1024]))) == [progress(second, held: 1024, at: 600)])
    }

    // MARK: A skipped file (ADR 2026-10.ds45's amendment of 2026-10-10)

    @Test func aSkippedFileIsReportedAtTheWindowsCadenceToItsEnd() {
        // A windowed sender then runs at the windowed rate rather than its 4 KiB/s fallback (`FeedWindow.kt:367`, `:474`).
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let unasked = bytes(8192, seed: 4)
        _ = rig.handle(.received(channel, header(unasked)))
        rig.clock.advance(100)
        #expect(rig.handle(.received(channel, chunk(unasked[0..<1024]))).isEmpty, "half a smallest chunk")
        #expect(rig.handle(.received(channel, chunk(unasked[1024..<2048]))) == [progress(unasked, held: 2048, at: 100)])
        #expect(rig.handle(.received(channel, chunk(unasked[2048..<2560]))).isEmpty)
        #expect(rig.advance(500) == [progress(unasked, held: 2560, at: 600)], "the trailing report, half a second on")
        _ = rig.handle(.received(channel, LinkRecord(.fileEnd).encoded ?? []))
        #expect(rig.advance(500).isEmpty, "a skipped file's END ends its reports")
        #expect(rig.links.isFileArriving(from: LinkRig.low) == false)
    }

    @Test func aFileDroppedPastThisPortsLimitIsReadOn() {
        // Android keeps a file to its 8 MiB and 64 KiB ceiling. This port's own limits are lower, and a file it drops for
        // one is read on as a skipped one; past the ceiling, `FileIntakeTests` has it go silent, as Android's `abort` does.
        var configuration = LinkManager.Configuration()
        configuration.maxAvatarFileBytes = 1024
        let rig = LinkRig(local: LinkRig.high, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        let avatar = bytes(4096, seed: 5)
        _ = rig.handle(.received(channel, header(avatar, kind: .avatar)))
        #expect(rig.handle(.received(channel, chunk(avatar[0..<2048]))) == [progress(avatar, held: 2048, at: 0)], "past its limit")
        #expect(rig.handle(.received(channel, chunk(avatar[2048..<4096]))) == [progress(avatar, held: 4096, at: 0)])
    }

    @Test func aMalformedKeyIsNeitherKeptNorReported() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let header = FileHeader(kind: .attachment, key: String(repeating: "Z", count: 64), mime: "image/jpeg", size: 4096)
        _ = rig.handle(.received(channel, LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(header)).encoded ?? []))
        #expect(rig.handle(.received(channel, chunk(bytes(4096)[0..<4096]))).isEmpty)
    }

    @Test func aStreamsTimeLeftIsItsDeclaredRestAtItsRateSoFarKeptOrSkipped() {
        // `FramedLink.rxEtaMs`: what an asker weighs before it waits out the stream (knit-next 79f38d3d).
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel)
        let unasked = bytes(8192, seed: 6)
        #expect(rig.links.fileArrivingLeftMilliseconds(from: LinkRig.low) == nil, "nothing streaming")
        _ = rig.handle(.received(channel, header(unasked)))
        #expect(rig.links.fileArrivingLeftMilliseconds(from: LinkRig.low) == nil, "before a byte of it")
        rig.clock.advance(1000)
        _ = rig.handle(.received(channel, chunk(unasked[0..<2048])))
        #expect(rig.links.fileArrivingLeftMilliseconds(from: LinkRig.low) == 3000, "6 KiB more at 2 KiB a second")
        let undeclared = FileHeader(kind: .attachment, key: BlobHash(of: unasked).string, mime: "image/jpeg", size: nil)
        _ = rig.handle(.received(channel, LinkRecord(.fileHeader, payload: LinkJSON.fileHeaderPayload(undeclared)).encoded ?? []))
        rig.clock.advance(1000)
        _ = rig.handle(.received(channel, chunk(unasked[0..<2048])))
        #expect(rig.links.fileArrivingLeftMilliseconds(from: LinkRig.low) == nil, "no size declared")
    }

    // MARK: The switch off

    @Test func aKeptFileStreamingInIsReportedEveryTwoSecondsOfChunks() {
        // How much is in, by our own clock since its header, after the chunk that crosses each two seconds. Nothing
        // arrives in a stall, so nothing is reported.
        let rig = pacedRig()
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

    @Test func aSkippedFileIsReportedAsItIsReadAndEachHeaderStartsItsOwnClock() {
        // Android keeps every file whose header decodes and reports it (`FileIntake.kt:124-131`, `RxReports.kt:48-70`).
        let rig = pacedRig()
        _ = rig.accept(LinkRig.low, on: channel)
        let unasked = bytes(4096, seed: 2)
        _ = rig.handle(.received(channel, header(unasked)))
        rig.clock.advance(5000)
        let skipped = rig.handle(.received(channel, chunk(unasked[0..<1024])))
        #expect(skipped == [.fileProgress(FileProgress(from: LinkRig.low, hash: BlobHash(of: unasked), held: 1024, milliseconds: 5000))])
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
