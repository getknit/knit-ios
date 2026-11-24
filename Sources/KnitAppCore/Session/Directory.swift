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
    /// The people the user blocked, pinned or not (ADR 2026-10.5wgg).
    public let blocked: Set<NodeId>
    /// The collision-aware labels.
    public let labels: PeerLabelIndex
    /// The strangers whose name clash has faded (``LabelFade``): they give way in ``labels``, and keep a label of their own.
    public let stale: Set<NodeId>
    /// Our own node id.
    public let me: NodeId
    /// Our own photo, or `nil` for none.
    public let myPhoto: BlobHash?
    private let person: NamePresenter
    private let group: NamePresenter

    /// The directory over `peers`, the people blocked, and our own id, name and photo. With `names`, the content filter
    /// is on: someone else's name, status or group name that the name screen flags draws blank (knit-next ADR
    /// 2026-11.y4pc). Without it, everything draws as it is stored. The peers in `stale` give way in the labels (ADR
    /// 2026-11.58yk); we never do.
    public init(
        peers: [PeerRecord], blocked: Set<NodeId> = [], me: NodeId, myName: String, myPhoto: BlobHash? = nil,
        names: ShownNames? = nil, stale: Set<NodeId> = []
    ) {
        self.peers = Dictionary(peers.map { ($0.nodeId, $0) }) { first, _ in first }
        verified = Set(peers.filter(\.verified).map(\.nodeId))
        self.blocked = blocked
        person = names?.person ?? .asStored
        group = names?.group ?? .asStored
        self.stale = stale.subtracting([me])
        labels = PeerLabelIndex(
            peers: peers.map { ($0.nodeId.string, $0.name) },
            me: (me.string, myName),
            presenter: person,
            stale: Set(self.stale.map(\.string))
        )
        self.me = me
        self.myPhoto = myPhoto
    }

    /// The label for `nodeId`: a pinned peer's name, our own, or the alias of someone not pinned yet.
    public func label(for nodeId: NodeId) -> PeerLabel {
        labels.label(for: nodeId.string)
    }

    /// Someone else's name or status as strangers may see it, or blank when the content filter hides it. Our own never
    /// comes here: it is drawn as we set it.
    public func shown(_ text: String) -> String {
        person(text)
    }

    /// A group's name as its members see it, or blank when the content filter hides a slur in it.
    public func shownGroup(_ name: String) -> String {
        group(name)
    }

    /// The name `nodeId` set, when the content filter draws them by their alias instead, for a report, which carries
    /// what the filter hid (ADR 2026-10.f6kf); `nil` when their name shows, or they have none.
    public func hiddenName(of nodeId: NodeId) -> String? {
        guard nodeId != me, let name = peers[nodeId]?.name, !NameKey.isBlankName(name), NameKey.isBlankName(person(name)) else {
            return nil
        }
        return name
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
