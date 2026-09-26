public import KnitCrypto
public import KnitStore
public import KnitWire

/// This device's own identity, as the screens show it.
public struct OwnIdentity: Sendable, Equatable {
    /// The public keys this device publishes.
    public let bundle: PublicKeyBundle

    /// Wraps a bundle.
    public init(bundle: PublicKeyBundle) {
        self.bundle = bundle
    }

    /// This device's node id.
    public var nodeId: NodeId { bundle.nodeId }
    /// The alias every phone shows for this device until it has a name.
    public var alias: String { Alias.alias(for: nodeId.string) }
}

/// Every identity this device knows, with the labels they show under: the pinned peers and ourselves
/// (`PeerDirectory` in knit-next). One snapshot per change, so every surface names people the same way.
public struct Directory: Sendable {
    /// The pinned peers, by node id.
    public let peers: [NodeId: PeerRecord]
    /// The peers the user verified.
    public let verified: Set<NodeId>
    /// The collision-aware labels.
    public let labels: PeerLabelIndex

    /// The directory over `peers` and our own id and name.
    public init(peers: [PeerRecord], me: NodeId, myName: String) {
        self.peers = Dictionary(peers.map { ($0.nodeId, $0) }) { first, _ in first }
        verified = Set(peers.filter(\.verified).map(\.nodeId))
        labels = PeerLabelIndex(peers: peers.map { ($0.nodeId.string, $0.name) }, me: (me.string, myName))
    }

    /// The label for `nodeId`: a pinned peer's name, our own, or the alias of someone not pinned yet.
    public func label(for nodeId: NodeId) -> PeerLabel {
        labels.label(for: nodeId.string)
    }
}

/// A value rebuilt only when its key moves, for a view model whose getter runs on every redraw. It lives behind
/// `@ObservationIgnored`, so filling it never counts as a change: only the key's own reads are observed.
internal struct Cached<Key: Equatable, Value> {
    private var key: Key?
    private var value: Value?

    /// The value for `key`, rebuilt by `build` when the key changed.
    mutating func value(for key: Key, _ build: () -> Value) -> Value {
        if let value, self.key == key {
            return value
        }
        let fresh = build()
        self.key = key
        value = fresh
        return fresh
    }
}
