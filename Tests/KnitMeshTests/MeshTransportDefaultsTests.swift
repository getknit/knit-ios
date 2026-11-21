import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A transport that streams no files and states only what it has queued: every other requirement answers nothing.
private final class QueueOnlyTransport: MeshTransport {
    let queued: Int

    init(queued: Int) {
        self.queued = queued
    }

    var neighbors: [Neighbor] { [] }
    var arrivingFileKeys: Set<BlobHash> { [] }
    var feedingLoad: Int { 0 }

    func send(_: WireEnvelope, to _: NodeId?) {
        // Nothing is linked.
    }

    func sendDigest(_: [String], to _: NodeId) {
        // Nothing is linked.
    }

    func queuedBytes(to _: NodeId) -> Int { queued }
    func hasCrossed(_: String, to _: NodeId) -> Bool { false }
    func sendFile(_: OutboundFile, to _: NodeId) -> Bool { false }
    func isFileInFlight(_: BlobHash, to _: NodeId) -> Bool { false }
    func cancelQueuedFile(_: BlobHash, to _: NodeId) -> Bool { false }

    func fileProgressReported(from _: NodeId, hash _: BlobHash, held _: Int64, milliseconds _: Int64) {
        // No file streams.
    }

    func fileTaken(from _: NodeId, hash _: BlobHash) {
        // No file arrives.
    }

    func isFileArriving(from _: NodeId) -> Bool { false }
    func fileArrivingLeftMilliseconds(from _: NodeId) -> Int64? { nil }
    func fileFeed(of _: BlobHash, to _: NodeId) -> FeedReading? { nil }
    func expectedFileRate(to _: NodeId) -> Int64 { 0 }

    func acceptFiles(_: Set<BlobHash>, resumable _: Set<BlobHash>, photoOnly _: Set<BlobHash>) {
        // No file arrives.
    }

    func filesWaiting(to _: NodeId) -> Int { 0 }

    func peerProvesItself(_: NodeId) {
        // No link to prove.
    }

    func listPresenceKeys(_: [NodeId: [PresenceKey]]) {
        // No advert.
    }

    func sendOverProvenLink(_: WireEnvelope, to _: NodeId) -> Bool { false }
    func hasProvenLink(to _: NodeId) -> Bool { false }
}

/// What ``MeshTransport``'s defaults answer for a transport that leaves them be.
@Suite struct MeshTransportDefaultsTests {
    @Test func aTransportThatStreamsNoFilesCountsEveryQueuedByteAsFrames() {
        let transport = QueueOnlyTransport(queued: 4242)
        #expect(transport.queuedFrameBytes(to: fixtureNodeId(2)) == 4242)
    }

    @Test func aTransportWithNoStreamClockReadsAnArrivingFileAsLiveOnlyWhileOneArrives() {
        // `RecordingTransport` states its own liveness, so the default is read here.
        #expect(!QueueOnlyTransport(queued: 0).isFileArrivingLive(from: fixtureNodeId(2)))
    }
}
