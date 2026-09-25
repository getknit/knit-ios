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
}

extension MeshTransport {
    /// Whether this node holds a live link to `nodeId`.
    public func isLinked(_ nodeId: NodeId) -> Bool {
        neighbors.contains { $0.nodeId == nodeId }
    }
}
