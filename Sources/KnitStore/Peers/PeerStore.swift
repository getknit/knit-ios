import KnitSync
public import KnitWire

/// A peer whose profile this node has pinned (`PeerEntity` in knit-next, the fields the MVP reads).
///
/// The key is pinned on the first profile whose key derives to the node id, and never changes after. The
/// presentation fields follow the newest profile, ordered by ``updatedAt``, and the prekey follows its own watermark,
/// ``prekeyProfileAt``.
public struct PeerRecord: Sendable, Equatable {
    /// The peer.
    public var nodeId: NodeId
    /// The display name, at most 32 UTF-16 units; empty shows the alias.
    public var name: String
    /// The status line, at most 100 UTF-16 units.
    public var status: String
    /// The pinned public key bundle, base64.
    public var publicKey: String
    /// The key-independent device tag, if the peer sent one.
    public var deviceTag: String?
    /// The peer's protocol version, from its profile.
    public var protocolVersion: Int?
    /// The peer's capability bits, from its signed profile: the copy that gates what we send.
    public var capabilities: Int64?
    /// The presentation watermark: the newest profile's `version`, or its `sentAt` when it has none, clamped to
    /// five minutes past our clock.
    public var updatedAt: Int64
    /// Whether the user compared safety numbers and marked the peer verified.
    public var verified: Bool
    /// Whether the peer invites DMs from people it has not met.
    public var openToChat: Bool
    /// The profile photo shown: one whose bytes are held (`PeerEntity.avatarHash`). It follows
    /// ``advertisedAvatarHash`` once those bytes land, so the photo never blanks while a new one travels.
    public var avatarHash: BlobHash?
    /// The photo the newest signed profile names, held or not: the one to fetch while it differs from
    /// ``avatarHash``. `nil` when that profile names none, or names a hash that is not one.
    public var advertisedAvatarHash: BlobHash?
    /// The peer's ratchet prekey (`PeerEntity.prekeyId`, `prekeyPub` and `prekeySig`), kept only once its signature
    /// verified against the key in the same profile, and its public value was 32 bytes (`InboundPipeline.kt:3353-3368`).
    /// `nil` when the newest profile on ``prekeyProfileAt`` carried none, or a bad one: that clears it.
    public var prekey: PrekeyInfo?
    /// The prekey's watermark (`PeerEntity.prekeyProfileAt`): the `version` of the profile that last set or cleared
    /// ``prekey``, clamped as ``updatedAt`` is, or 0 before any. It moves apart from ``updatedAt``, because a sealed
    /// profile update moves the presentation and carries no prekey (`InboundPipeline.kt:3276-3287`).
    public var prekeyProfileAt: Int64

    /// Makes a record.
    public init(
        nodeId: NodeId,
        name: String,
        status: String,
        publicKey: String,
        deviceTag: String? = nil,
        protocolVersion: Int? = nil,
        capabilities: Int64? = nil,
        updatedAt: Int64,
        verified: Bool = false,
        openToChat: Bool = false,
        avatarHash: BlobHash? = nil,
        advertisedAvatarHash: BlobHash? = nil,
        prekey: PrekeyInfo? = nil,
        prekeyProfileAt: Int64 = 0
    ) {
        self.nodeId = nodeId
        self.name = name
        self.status = status
        self.publicKey = publicKey
        self.deviceTag = deviceTag
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.updatedAt = updatedAt
        self.verified = verified
        self.openToChat = openToChat
        self.avatarHash = avatarHash
        self.advertisedAvatarHash = advertisedAvatarHash
        self.prekey = prekey
        self.prekeyProfileAt = prekeyProfileAt
    }
}

/// The pinned peers (`PeerRepository` in knit-next).
public protocol PeerStore: AnyObject, Sendable {
    /// The pinned peer, or `nil`.
    func peer(_ nodeId: NodeId) -> PeerRecord?

    /// Inserts or replaces a peer.
    func upsert(_ peer: PeerRecord)

    /// Every peer the user marked verified.
    func verifiedNodeIds() -> Set<NodeId>

    /// Every pinned peer, for the UI and diagnostics.
    func allPeers() -> [PeerRecord]

    /// Keeps `frame`, the signed `profile` frame `nodeId`'s key was just pinned from, as the proof of that key this
    /// node hands on (`PeerRepository.recordProfileFrame`, knit-next ADR 2026-09.g64k). A copy already held that is
    /// stamped `sentAt` or later stays, so the newest publish wins in any arrival order. The peer picks the stamp,
    /// so the caller clamps it first.
    func recordProfileFrame(_ frame: WireEnvelope, of nodeId: NodeId, sentAt: Int64)

    /// `nodeId`'s kept proof of key, its signed bytes verbatim in a point-to-point wrapper, or `nil`.
    func profileFrame(of nodeId: NodeId) -> WireEnvelope?
}

/// A ``PeerStore`` in memory, safe to share across threads.
public final class MemoryPeerStore: PeerStore {
    private let peers = Lock<[NodeId: PeerRecord]>([:])
    private let profiles = Lock<[NodeId: (frame: WireEnvelope, sentAt: Int64)]>([:])

    /// An empty store.
    public init() {
        // Nothing to set up.
    }

    public func peer(_ nodeId: NodeId) -> PeerRecord? {
        peers.withLock { $0[nodeId] }
    }

    public func upsert(_ peer: PeerRecord) {
        peers.withLock { $0[peer.nodeId] = peer }
    }

    public func verifiedNodeIds() -> Set<NodeId> {
        peers.withLock { Set($0.values.filter(\.verified).map(\.nodeId)) }
    }

    public func allPeers() -> [PeerRecord] {
        peers.withLock { $0.values.sorted { $0.nodeId < $1.nodeId } }
    }

    public func recordProfileFrame(_ frame: WireEnvelope, of nodeId: NodeId, sentAt: Int64) {
        profiles.withLock { profiles in
            if let held = profiles[nodeId], held.sentAt >= sentAt {
                return
            }
            profiles[nodeId] = (WireEnvelope(relay: false, sig: frame.sig, signed: frame.signed), sentAt)
        }
    }

    public func profileFrame(of nodeId: NodeId) -> WireEnvelope? {
        profiles.withLock { $0[nodeId]?.frame }
    }
}
