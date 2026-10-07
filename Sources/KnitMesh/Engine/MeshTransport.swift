public import KnitWire

/// A peer this node holds a live link to (`Peer` in knit-next's `MeshTransport.kt`).
///
/// The version and capabilities are what the peer's HELLO claimed: an unauthenticated routing hint. The signed
/// copy in its profile is the one that gates anything.
public struct Neighbor: Sendable, Hashable {
    /// The peer.
    public var nodeId: NodeId
    /// The protocol version its HELLO claimed.
    public var protocolVersion: Int
    /// The capability bits its HELLO claimed.
    public var capabilities: Capabilities

    /// Makes a neighbour.
    public init(nodeId: NodeId, protocolVersion: Int = WireProtocol.version, capabilities: Capabilities = .local) {
        self.nodeId = nodeId
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

/// What the mesh engine sends through (`MeshTransport` in knit-next): the live links, and a way to write to them.
///
/// Everything above the radio talks only to this. ``LinkManager`` is the production transport; a test hands
/// the engine a recording one. Writes never block and never fail loudly: a link that dies mid-write reports
/// itself down, and custody re-serves whatever it missed.
public protocol MeshTransport: AnyObject {
    /// The neighbours linked now, in the order their links came up.
    var neighbors: [Neighbor] { get }

    /// Writes `wire` to one neighbour, or to every neighbour when `peer` is `nil`. A frame already crossing a link,
    /// in either direction, is not written to it again.
    func send(_ wire: WireEnvelope, to peer: NodeId?)

    /// Writes a custody digest, the ids of every live carried frame, to one neighbour.
    func sendDigest(_ ids: [String], to peer: NodeId)

    /// Streams `file` to one neighbour as FILE records, behind any file already queued or streaming to it, and answers
    /// whether a link took it (`MeshTransport.sendFile`). A file already queued or streaming to that neighbour is not
    /// queued again.
    func sendFile(_ file: OutboundFile, to peer: NodeId) -> Bool

    /// Whether `hash` is queued or streaming to `peer` (`MeshTransport.fileInFlightTo`): a blob request for it then
    /// ships nothing (knit-next ADR 2026-09.4tx5).
    func isFileInFlight(_ hash: BlobHash, to peer: NodeId) -> Bool

    /// `peer` withdrew its ask for `hash` (`MeshTransport.cancelQueuedFile`, knit-next ADR 2026-10.nsr7): a copy queued to
    /// it and not yet streaming is taken off its link. Answers whether one was. A copy already streaming goes on.
    func cancelQueuedFile(_ hash: BlobHash, to peer: NodeId) -> Bool

    /// The files on their way in (`MeshTransport.arrivingFiles`): streaming in on some link, or past their END and not
    /// yet taken by the engine (``fileTaken(from:hash:)``). A blob arriving is neither asked for nor asked again, and a
    /// holder query about it answers FETCHING (knit-next ADRs 2026-09.4tx5 and 2026-10.6e5t).
    var arrivingFileKeys: Set<BlobHash> { get }

    /// The engine has taken a whole file `peer` sent, stored or refused (`MeshTransport.fileTaken`), so it is no longer
    /// on its way.
    func fileTaken(from peer: NodeId, hash: BlobHash)

    /// Whether a file from `peer` is streaming in now (`MeshTransport.fileArrivingFrom`, knit-next ADR 2026-10.nxfb). A
    /// link delivers in order, so whatever that peer has already sent us waits behind it: the peer, not the hash.
    func isFileArriving(from peer: NodeId) -> Bool

    /// How many files this node is streaming out now (`MeshTransport.feedingLoad`), the `load` a holder query's answer
    /// carries.
    var feedingLoad: Int { get }

    /// The attachments worth keeping when their bytes stream in: the blobs this node wants. Any other ATTACHMENT file
    /// is dropped as it streams by. A peer's own AVATAR push is kept whatever this says.
    func acceptFiles(_ keys: Set<BlobHash>)
}

/// A file to stream on a link: its header's fields, its size, and a reader for its bytes, so a file waiting behind
/// another costs its header, not its bytes.
public struct OutboundFile {
    /// What the file is: our own photo pushed, or any blob served (`FileKind`).
    public var kind: FileHeader.Kind
    /// The blob's hash, which the header's key carries.
    public var hash: BlobHash
    /// The blob's type.
    public var mime: String
    /// The blob's length in bytes.
    public var size: Int
    /// Reads at most `count` bytes from `offset`, or `nil` when the blob is gone or cannot be read.
    public var read: (_ offset: Int, _ count: Int) -> [UInt8]?

    /// A file to stream.
    public init(kind: FileHeader.Kind, hash: BlobHash, mime: String, size: Int, read: @escaping (_ offset: Int, _ count: Int) -> [UInt8]?) {
        self.kind = kind
        self.hash = hash
        self.mime = mime
        self.size = size
        self.read = read
    }

    /// The header this file streams under. Its size lets the receiver draw how far the file has got, as Android's
    /// `streamFile` declares it (`FramedLink.kt:332-337`, knit-next ADR 2026-10.y9qh).
    public var header: FileHeader {
        FileHeader(kind: kind, key: hash.string, mime: mime, size: size)
    }
}

/// How far a file streaming in from a neighbour has got (`FileProgress` in knit-next's `MeshTransport.kt`, its ADR
/// 2026-10.nsr7): noted every couple of seconds of chunks, and sent back to the sender as a `blobprog`.
public struct FileProgress: Sendable, Equatable {
    /// The neighbour whose link is streaming it.
    public var from: NodeId
    /// The hash its header's key named.
    public var hash: BlobHash
    /// The bytes held so far.
    public var held: Int64
    /// The milliseconds since its header arrived, on the monotonic clock.
    public var milliseconds: Int64

    /// A note on a file streaming in.
    public init(from: NodeId, hash: BlobHash, held: Int64, milliseconds: Int64) {
        self.from = from
        self.hash = hash
        self.held = held
        self.milliseconds = milliseconds
    }
}

/// A whole file a neighbour streamed to us. Its bytes are not yet checked against its hash: the engine does that
/// (`MeshBlobStore.saveIncoming`).
public struct InboundFile: Sendable, Equatable {
    /// The neighbour whose link carried it, as its HELLO named it.
    public var from: NodeId
    /// What the sender said the file is.
    public var kind: FileHeader.Kind
    /// The hash the header's key named.
    public var hash: BlobHash
    /// The type the header named.
    public var mime: String
    /// The bytes, as they arrived.
    public var bytes: [UInt8]

    /// A file that arrived.
    public init(from: NodeId, kind: FileHeader.Kind, hash: BlobHash, mime: String, bytes: [UInt8]) {
        self.from = from
        self.kind = kind
        self.hash = hash
        self.mime = mime
        self.bytes = bytes
    }
}

extension MeshTransport {
    /// Whether this node holds a live link to `nodeId`.
    public func isLinked(_ nodeId: NodeId) -> Bool {
        neighbors.contains { $0.nodeId == nodeId }
    }
}

/// What the links did with FILE records so far.
public struct FileCounts: Sendable, Equatable {
    /// Whole files that arrived, before their hashes were checked.
    public var received: Int
    /// Files dropped as they streamed in: unwanted, malformed, too large, or cut off by another header.
    public var refused: Int
    /// Files that left the radio whole.
    public var sent: Int

    /// Bundles the counts.
    public init(received: Int = 0, refused: Int = 0, sent: Int = 0) {
        self.received = received
        self.refused = refused
        self.sent = sent
    }
}
