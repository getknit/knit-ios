import KnitCrypto
import KnitMesh
import KnitWire
import Testing

/// A copy its asker withdrew comes off the link before its header goes (knit-next ADR 2026-10.nsr7, ADR 2026-10.ds45), as
/// `FramedLinkTest.aQueuedFileThePeerWithdrawsIsSkippedButAStreamingOneIsNot` has Android's writer skip one.
@Suite struct LinkFileCancelTests {
    private let channel = ChannelID(100)

    private func outbound(_ file: [UInt8]) -> OutboundFile {
        OutboundFile(kind: .attachment, hash: BlobHash(of: file), mime: "image/jpeg", size: file.count) { offset, count in
            Array(file[offset..<min(file.count, offset + count)])
        }
    }

    @Test func aQueuedCopyThePeerWithdrawsIsSkippedButAStreamingOneIsNot() {
        var configuration = LinkManager.Configuration()
        configuration.filePaceBytesPerSecond = 0
        let rig = LinkRig(local: LinkRig.high, reportsFileWrites: true, configuration: configuration)
        _ = rig.accept(LinkRig.low, on: channel)
        let first = BlobHash(of: Array("streaming".utf8))
        let second = BlobHash(of: Array("waiting".utf8))
        _ = rig.links.sendFile(outbound(Array("streaming".utf8)), to: LinkRig.low)
        _ = rig.links.sendFile(outbound(Array("waiting".utf8)), to: LinkRig.low)
        #expect(!rig.links.cancelQueuedFile(first, to: LinkRig.low), "its header is out: it goes on")
        #expect(!rig.links.cancelQueuedFile(second, to: LinkRig.middle), "no link to that peer")
        #expect(rig.links.cancelQueuedFile(second, to: LinkRig.low))
        #expect(!rig.links.isFileInFlight(second, to: LinkRig.low), "so a fresh ask queues it again")
        #expect(!rig.links.cancelQueuedFile(second, to: LinkRig.low), "one copy, withdrawn once")
        #expect(rig.links.queuedFileCount == 1)
        _ = rig.handle(.wroteFileRecord(channel))
        #expect(rig.handle(.wroteFileRecord(channel)) == [.fileSent(first, to: LinkRig.low)])
        let headers = rig.radio.records(on: channel).filter { $0.tag == .fileHeader }
        #expect(headers.count == 1, "the withdrawn copy's header never goes")
        #expect(rig.links.queuedFileCount == 0)
    }
}
