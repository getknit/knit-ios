public import KnitCrypto
public import KnitStore
public import KnitWire

/// One peer's DM ratchet state as the reset path sees it, for the control surface's `ratchet` reply
/// (`RatchetPeerState`, knit-next `mesh/MeshController.kt:220-250`, and `MeshManager.ratchetState`, `MeshManager.kt:906-927`,
/// at `ac491f4c`). Every gate in the recovery path returns silently, so a peer we hold no prekey for and a peer whose
/// heuristic has not fired look alike from outside; each field here is one of those gates.
///
/// It carries no secret: the root goes out only as ``rootHash``, which two devices compare to tell whether they share
/// an era.
public struct RatchetPeerState: Sendable, Equatable {
    /// How many hex digits of the root's SHA-256 ``rootHash`` keeps (`ROOT_HASH_HEX_CHARS`, `MeshManager.kt:3447`).
    public static let rootHashLength = 8

    /// The peer.
    public let peer: NodeId
    /// The name its profile gave.
    public let name: String
    /// Whether its pinned profile carries `CAP_RATCHET`: without it no reset can start from this side.
    public let capRatchet: Bool
    /// The id of the prekey pinned for it, or `nil`.
    public let peerPrekeyId: Int?
    /// Whether a prekey is pinned for it.
    public let peerPrekeyPinned: Bool
    /// Whether we hold a session with it.
    public let hasSession: Bool
    /// Whether that session is confirmed.
    public let confirmed: Bool
    /// Our send epoch's number.
    public let sendEpoch: Int
    /// When we last sealed a reset to it, from the session row: the anchor of our six-hour floor.
    public let lastResetSentAt: Int64
    /// The era stamp both sides converge on.
    public let establishedAt: Int64
    /// Whether we initiated the session.
    public let weAreInitiator: Bool
    /// The highest of our epochs it has sealed against.
    public let highestPeAcked: Int
    /// The first ``rootHashLength`` hex digits of SHA-256 of the root, or `nil` with no session: comparable across devices
    /// without exposing the root.
    public let rootHash: String?
    /// When the previous root stops draining.
    public let prevRootExpiresAt: Int64
    /// Whether the resolved-init anchor is set (`peerInitEphPub`).
    public let hasPeerInitAnchor: Bool
    /// Our surviving epochs for it, the most recently minted first: the ground truth for an `EPOCH_GONE` diagnosis.
    public let localEpochs: [LocalEpoch]

    /// One of our epochs as the diagnosis names it: its number and when it was minted, `"epoch@createdAt"` on Android's
    /// bridge.
    public struct LocalEpoch: Sendable, Equatable {
        /// The number.
        public let epoch: Int
        /// When it was minted, on our clock.
        public let createdAt: Int64
    }

    /// `peer`'s state from its pinned row, the session held with it, if any, and our epochs for it.
    public init(peer: PeerRecord, session: RatchetEngine.SessionState?, localEpochs: [(epoch: Int, createdAt: Int64)]) {
        self.peer = peer.nodeId
        name = peer.name
        capRatchet = Capabilities(rawValue: peer.capabilities ?? 0).contains(.ratchet)
        peerPrekeyId = peer.prekey?.id
        peerPrekeyPinned = peer.prekey != nil
        hasSession = session != nil
        confirmed = session?.confirmed ?? false
        sendEpoch = session?.sendEpoch ?? 0
        lastResetSentAt = session?.lastResetSentAt ?? 0
        establishedAt = session?.establishedAt ?? 0
        weAreInitiator = session?.weAreInitiator ?? false
        highestPeAcked = session?.highestPeAcked ?? 0
        // `sha256Hex(root).take(8)`: `BlobHash(of:)` is SHA-256 as lowercase hex, what knit-next's `sha256Hex` writes.
        rootHash = session.map { String(BlobHash(of: $0.root).string.prefix(Self.rootHashLength)) }
        prevRootExpiresAt = session?.prevRootExpiresAt ?? 0
        hasPeerInitAnchor = session?.peerInitEphPub != nil
        self.localEpochs = localEpochs.map { LocalEpoch(epoch: $0.epoch, createdAt: $0.createdAt) }
    }
}
