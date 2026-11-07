import KnitCrypto
import KnitMesh
import KnitWire

/// What the engine wrote, decoded.
struct Written {
    var wire: WireEnvelope
    var envelope: RelayEnvelope
    var to: NodeId?
}

/// A copy a link would say it feeds, and how it reads.
struct FedCopy {
    let hash: BlobHash
    let to: NodeId
    let reading: FeedReading

    init(_ hash: BlobHash, _ to: NodeId, _ reading: FeedReading) {
        self.hash = hash
        self.to = to
        self.reading = reading
    }
}

/// A transport that records every write.
final class RecordingTransport: MeshTransport {
    /// Every listing ``listPresenceKeys(_:)`` was handed.
    var presenceKeyListings: [[NodeId: [PresenceKey]]] = []
    /// One write, a frame or a file.
    enum Write {
        case frame(Written)
        case file(SentFile)
    }

    var neighbors: [Neighbor] = []
    private(set) var written: [Written] = []
    /// Every frame and file written, in one sequence, in the order the engine wrote them: the order a link queues them in.
    private(set) var sequence: [Write] = []
    private(set) var digests: [(ids: [String], to: NodeId)] = []
    /// Every file streamed, in order. A file to a peer that is not a neighbour goes nowhere, as on a link.
    private(set) var files: [SentFile] = []
    /// The attachments the engine last said to keep, of those the ones a cut would leave a prefix of, and the ones kept
    /// only to the photo's ceiling.
    private(set) var accepted: Set<BlobHash> = []
    private(set) var resumable: Set<BlobHash> = []
    private(set) var photoOnly: Set<BlobHash> = []
    /// Every `acceptFiles` call, in order: what it accepted and what it made resumable.
    private(set) var acceptCalls: [(keys: Set<BlobHash>, resumable: Set<BlobHash>)] = []
    /// How many files a link would say wait on each neighbour's link, as a test sets it.
    var waiting: [NodeId: Int] = [:]
    /// What a link would say is streaming in, as a test sets it.
    var arrivingFileKeys: Set<BlobHash> = []
    /// Whether a file taken leaves ``arrivingFileKeys``, as a landed file leaves a real link's.
    var takenLeavesArriving = false
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
    /// The feeds a link would read, by hash and peer, as a test sets them (`fileFeed`).
    var feeds: [FedCopy] = []
    /// The rate a link would expect a file to each neighbour to go at, as a test sets it.
    var rates: [NodeId: Int64] = [:]
    /// How long each neighbour's stream to us has left, as a test sets it.
    var arrivingLeft: [NodeId: Int64] = [:]
    /// Every peer the engine said now proves itself, its stored profile having gained the link-proof bit, in order.
    private(set) var provesItself: [NodeId] = []

    func send(_ wire: WireEnvelope, to peer: NodeId?) {
        guard let envelope = try? RelayEnvelope(decoding: wire.signed) else {
            fatalError("the engine wrote a frame that does not decode")
        }
        let frame = Written(wire: wire, envelope: envelope, to: peer)
        written.append(frame)
        sequence.append(.frame(frame))
    }

    func sendDigest(_ ids: [String], to peer: NodeId) {
        digests.append((ids, peer))
    }

    /// What a link would say waits unwritten to each neighbour, as a test sets it: 0 unless set.
    var unwritten: [NodeId: Int] = [:]
    /// The frame keys a link would say crossed to each neighbour, either way, as a test sets them: none unless set.
    var crossed: [NodeId: Set<String>] = [:]

    func queuedBytes(to peer: NodeId) -> Int {
        unwritten[peer] ?? 0
    }

    func hasCrossed(_ key: String, to peer: NodeId) -> Bool {
        crossed[peer]?.contains(key) ?? false
    }

    func sendFile(_ file: OutboundFile, to peer: NodeId) -> Bool {
        guard isLinked(peer) else {
            return false
        }
        let bytes = file.read(file.start, file.size - file.start) ?? []
        let sent = SentFile(kind: file.kind, hash: file.hash, mime: file.mime, bytes: bytes, to: peer, start: file.start)
        files.append(sent)
        sequence.append(.file(sent))
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

    func acceptFiles(_ keys: Set<BlobHash>, resumable: Set<BlobHash>, photoOnly: Set<BlobHash>) {
        accepted = keys
        self.resumable = resumable
        self.photoOnly = photoOnly
        acceptCalls.append((keys, resumable))
    }

    func filesWaiting(to peer: NodeId) -> Int {
        waiting[peer] ?? 0
    }

    func peerProvesItself(_ peer: NodeId) {
        provesItself.append(peer)
    }

    func listPresenceKeys(_ listing: [NodeId: [PresenceKey]]) {
        presenceKeyListings.append(listing)
    }

    func fileTaken(from peer: NodeId, hash: BlobHash) {
        taken.append((peer, hash))
        if takenLeavesArriving {
            arrivingFileKeys.remove(hash)
        }
    }

    func fileProgressReported(from peer: NodeId, hash: BlobHash, held: Int64, milliseconds: Int64) {
        progressReports.append(FileProgress(from: peer, hash: hash, held: held, milliseconds: milliseconds))
    }

    func isFileArriving(from peer: NodeId) -> Bool {
        arrivingFrom.contains(peer)
    }

    func fileArrivingLeftMilliseconds(from peer: NodeId) -> Int64? {
        arrivingLeft[peer]
    }

    func fileFeed(of hash: BlobHash, to peer: NodeId) -> FeedReading? {
        feeds.last { $0.hash == hash && $0.to == peer }?.reading
    }

    func expectedFileRate(to peer: NodeId) -> Int64 {
        rates[peer] ?? 0
    }

    /// Forgets what was written so far.
    func clear() {
        written.removeAll()
        sequence.removeAll()
        digests.removeAll()
        files.removeAll()
    }

    /// The writes of one frame type.
    func written(_ type: FrameType) -> [Written] {
        written.filter { $0.envelope.type == type }
    }
}
