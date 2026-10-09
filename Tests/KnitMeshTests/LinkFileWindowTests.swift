import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// A file to a peer that reports is clocked by its reports (knit-next ADR 2026-10.5buf, ADR 2026-10.xwjc), as
/// `FramedLinkTest`'s window cases have Android's writer clocked: it holds at its window until a report frees it, is
/// paced while its receiver is silent or reports only every two seconds, and takes no share of the paced budget.
@Suite struct LinkFileWindowTests {
    private let channel = ChannelID(100)
    private let other = ChannelID(101)
    /// A HELLO that carries `CAP_BLOB_HAVE`: the peer reports a file's progress.
    private let reporting: Capabilities = 0x2FFF

    private func bytes(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }
    }

    private func outbound(_ file: [UInt8]) -> OutboundFile {
        OutboundFile(kind: .attachment, hash: BlobHash(of: file), mime: "image/jpeg", size: file.count) { offset, count in
            Array(file[offset..<min(file.count, offset + count)])
        }
    }

    private func chunkSizes(_ rig: LinkRig, on id: ChannelID) -> [Int] {
        rig.radio.records(on: id).filter { $0.tag == .fileChunk }.map(\.payload.count)
    }

    @Test func aWindowedFeedHoldsAtItsStartingWindowUntilAReportFreesIt() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        let file = bytes(40 * 1024)
        _ = rig.links.sendFile(outbound(file), to: LinkRig.low)
        #expect(chunkSizes(rig, on: channel) == [4096, 4096], "the starting window, in starting chunks")
        let now = rig.clock.monotonicMilliseconds()
        #expect(rig.links.nextDeadline == now + FeedWindow.reportWaitMilliseconds, "a look for silence, not a pace")
        rig.links.fileProgressReported(from: LinkRig.low, hash: BlobHash(of: bytes(10)), held: 8192, milliseconds: 500)
        #expect(chunkSizes(rig, on: channel).count == 2, "a report about another file frees nothing")
        rig.links.fileProgressReported(from: LinkRig.low, hash: BlobHash(of: file), held: 8192, milliseconds: 500)
        // 16 KB/s over the 50 ms floor of a round trip and the quarter second of queue: 8 KiB more, in quarter seconds of
        // the rate.
        #expect(chunkSizes(rig, on: channel) == [4096, 4096, 4096, 4096])
    }

    @Test func aReportFromAPeerWeFeedNothingChangesNothing() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        rig.links.fileProgressReported(from: LinkRig.low, hash: BlobHash(of: bytes(10)), held: 10, milliseconds: 500)
        rig.links.fileProgressReported(from: LinkRig.middle, hash: BlobHash(of: bytes(10)), held: 10, milliseconds: 500)
        #expect(chunkSizes(rig, on: channel).isEmpty)
        #expect(rig.links.queuedFileCount == 0)
    }

    @Test func theRadiosReportStillHoldsAWindowedChunkUntilTheLastIsOut() {
        let rig = LinkRig(local: LinkRig.high, reportsFileWrites: true)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        _ = rig.links.sendFile(outbound(bytes(40 * 1024)), to: LinkRig.low)
        #expect(chunkSizes(rig, on: channel) == [4096], "the window has room, but the chunk is in the radio's queue")
        _ = rig.handle(.wroteFileRecord(channel))
        #expect(chunkSizes(rig, on: channel) == [4096, 4096])
        _ = rig.handle(.wroteFileRecord(channel))
        #expect(chunkSizes(rig, on: channel).count == 2, "and now the window is full")
    }

    @Test func aSilentReceiverIsPacedAfterThreeSecondsAndWindowedAgainAtItsReport() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        let file = bytes(64 * 1024)
        let start = rig.clock.monotonicMilliseconds()
        _ = rig.links.sendFile(outbound(file), to: LinkRig.low)
        rig.run(until: start + FeedWindow.noReportMilliseconds - 1)
        #expect(chunkSizes(rig, on: channel) == [4096, 4096], "silent, but not yet for long")
        rig.run(until: start + FeedWindow.noReportMilliseconds)
        #expect(rig.log.all.contains("info link file window paced: receiver silent → \(LinkRig.low)"))
        #expect(chunkSizes(rig, on: channel) == [4096, 4096, 8192], "the base pace's chunk at once")
        rig.run(until: start + FeedWindow.noReportMilliseconds + 1999)
        #expect(chunkSizes(rig, on: channel).count == 3, "then two seconds of it")
        rig.links.fileProgressReported(from: LinkRig.low, hash: BlobHash(of: file), held: 16_384, milliseconds: 4000)
        #expect(rig.log.all.contains("info link file window back → \(LinkRig.low)"))
        #expect(chunkSizes(rig, on: channel).count > 3, "the window takes the report's room at once")
    }

    @Test func aTwoSecondReporterIsPacedInSmallChunksAndWinsItsWindowBack() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        let file = bytes(64 * 1024)
        let hash = BlobHash(of: file)
        let start = rig.clock.monotonicMilliseconds()
        func report(_ held: Int64, at milliseconds: Int64) {
            rig.run(until: start + milliseconds)
            rig.links.fileProgressReported(from: LinkRig.low, hash: hash, held: held, milliseconds: milliseconds)
        }
        func sent() -> Int64 {
            Int64(chunkSizes(rig, on: channel).reduce(0, +))
        }
        _ = rig.links.sendFile(outbound(file), to: LinkRig.low)
        // Two seconds apart, and the last two each covering several chunks: a receiver reporting every two seconds.
        report(4096, at: 2000)
        report(sent(), at: 4000)
        let latchedAt = sent()
        report(latchedAt, at: 6000)
        #expect(rig.log.all.contains("info link file window paced: two-second reporter → \(LinkRig.low)"))
        let pacedFrom = chunkSizes(rig, on: channel).count
        // Woken, it answers each small paced chunk half a second apart, and three on time give the window back.
        report(latchedAt + 2048, at: 6500)
        report(latchedAt + 4096, at: 7000)
        #expect(!rig.log.all.contains("info link file window back → \(LinkRig.low)"), "two on time are not yet three")
        report(latchedAt + 6144, at: 7500)
        #expect(rig.log.all.contains("info link file window back → \(LinkRig.low)"))
        #expect(chunkSizes(rig, on: channel)[pacedFrom..<(pacedFrom + 3)] == [2048, 2048, 2048], "paced in the smallest chunks")
    }

    @Test func aWindowedFeedTakesNoShareOfThePacedBudget() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        _ = rig.accept(LinkRig.middle, on: other)
        _ = rig.links.sendFile(outbound(bytes(40 * 1024)), to: LinkRig.low)
        _ = rig.links.sendFile(outbound(bytes(40 * 1024, seed: 2)), to: LinkRig.middle)
        #expect(chunkSizes(rig, on: other) == [8192], "the paced link has the whole base to itself")
        #expect(rig.log.all.contains("info link file pace budget=4096 feeding=1 share=4096 chunk=8192 → \(LinkRig.middle)"))
    }

    @Test func withTheSwitchOffAPeerThatReportsIsPaced() {
        var configuration = LinkManager.Configuration()
        configuration.feedWindow = false
        let rig = LinkRig(local: LinkRig.high, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        _ = rig.links.sendFile(outbound(bytes(40 * 1024)), to: LinkRig.low)
        #expect(chunkSizes(rig, on: channel) == [8192])
        #expect(rig.links.nextDeadline == rig.clock.monotonicMilliseconds() + 2000)
    }

    @Test func aWindowedFileEndsWithItsRateInTheLog() {
        let rig = LinkRig(local: LinkRig.high)
        _ = rig.accept(LinkRig.low, on: channel, capabilities: reporting)
        let file = bytes(8192)
        let hash = BlobHash(of: file)
        _ = rig.links.sendFile(outbound(file), to: LinkRig.low)
        rig.run(until: rig.clock.monotonicMilliseconds() + 500)
        rig.links.fileProgressReported(from: LinkRig.low, hash: hash, held: 8192, milliseconds: 500)
        #expect(rig.advance(0) == [.fileSent(hash, to: LinkRig.low)])
        let key = hash.string.prefix(12)
        #expect(rig.log.all.contains("info link file ATTACHMENT \(key) to \(LinkRig.low): 8192 bytes in 500 ms @16384 window"))
    }
}
