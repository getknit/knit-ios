import KnitMesh
import KnitWire

/// What the engine wrote, decoded.
struct Written {
    var wire: WireEnvelope
    var envelope: RelayEnvelope
    var to: NodeId?
}

/// A transport that records every write.
final class RecordingTransport: MeshTransport {
    var neighbors: [Neighbor] = []
    private(set) var written: [Written] = []
    private(set) var digests: [(ids: [String], to: NodeId)] = []
    /// Every file streamed, in order. A file to a peer that is not a neighbour goes nowhere, as on a link.
    private(set) var files: [SentFile] = []
    /// The attachments the engine last said to keep.
    private(set) var accepted: Set<BlobHash> = []
    /// What a link would say is streaming in, as a test sets it.
    var arrivingFileKeys: Set<BlobHash> = []
    /// The files a link would say are still on their way, by hash and peer, as a test sets them.
    var inFlight: [(hash: BlobHash, to: NodeId)] = []
    /// The files a link would say are queued and not yet streaming, by hash and peer, as a test sets them. A withdrawal
    /// takes one off, and off ``inFlight`` too.
    var queued: [(hash: BlobHash, to: NodeId)] = []
    /// Every queued file a withdrawal took off, in order.
    private(set) var withdrawn: [(hash: BlobHash, to: NodeId)] = []
    /// The neighbours a link would say are streaming a file to us, as a test sets them.
    var arrivingFrom: Set<NodeId> = []
    /// How many files a link would say it is streaming out, as a test sets it.
    var feedingLoad = 0
    /// Every file the engine said it took, in order.
    private(set) var taken: [(from: NodeId, hash: BlobHash)] = []
    /// Every progress report the engine handed the links, in order.
    private(set) var progressReports: [FileProgress] = []

    func send(_ wire: WireEnvelope, to peer: NodeId?) {
        guard let envelope = try? RelayEnvelope(decoding: wire.signed) else {
            fatalError("the engine wrote a frame that does not decode")
        }
        written.append(Written(wire: wire, envelope: envelope, to: peer))
    }

    func sendDigest(_ ids: [String], to peer: NodeId) {
        digests.append((ids, peer))
    }

    func sendFile(_ file: OutboundFile, to peer: NodeId) -> Bool {
        guard isLinked(peer) else {
            return false
        }
        files.append(SentFile(kind: file.kind, hash: file.hash, mime: file.mime, bytes: file.read(0, file.size) ?? [], to: peer))
        return true
    }

    func isFileInFlight(_ hash: BlobHash, to peer: NodeId) -> Bool {
        inFlight.contains { $0.hash == hash && $0.to == peer }
    }

    func cancelQueuedFile(_ hash: BlobHash, to peer: NodeId) -> Bool {
        guard let index = queued.firstIndex(where: { $0.hash == hash && $0.to == peer }) else {
            return false
        }
        queued.remove(at: index)
        inFlight.removeAll { $0.hash == hash && $0.to == peer }
        withdrawn.append((hash, peer))
        return true
    }

    func acceptFiles(_ keys: Set<BlobHash>) {
        accepted = keys
    }

    func fileTaken(from peer: NodeId, hash: BlobHash) {
        taken.append((peer, hash))
    }

    func fileProgressReported(from peer: NodeId, hash: BlobHash, held: Int64, milliseconds: Int64) {
        progressReports.append(FileProgress(from: peer, hash: hash, held: held, milliseconds: milliseconds))
    }

    func isFileArriving(from peer: NodeId) -> Bool {
        arrivingFrom.contains(peer)
    }

    /// Forgets what was written so far.
    func clear() {
        written.removeAll()
        digests.removeAll()
        files.removeAll()
    }

    /// The writes of one frame type.
    func written(_ type: FrameType) -> [Written] {
        written.filter { $0.envelope.type == type }
    }
}
