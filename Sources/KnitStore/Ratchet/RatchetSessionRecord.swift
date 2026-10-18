public import KnitWire

/// One DM ratchet session as a ``RatchetStore`` keeps it (`RatchetSessionEntity`, knit-next
/// `data/ratchet/RatchetEntities.kt:13-38`): the engine's `SessionState` field for field, as bytes, numbers and flags,
/// since KnitStore does not depend on KnitCrypto. `RatchetRecords` in KnitMesh is the one place that maps it to and from
/// the engine's type, and the field names are Kotlin's, so a column, a state digest and a vector read the same.
///
/// Two of the entity's columns are left out: `sendEpochExport`, the spool's half, which production never reads back and
/// this port does not derive (ADR 2026-10.5sk9, amended for P4b), and `updatedAt`, a stamp of the repository's clock that
/// nothing reads. Every other field must come back as it went in: the engine's `seal` answers `nil` for a session missing
/// its send chain or, unconfirmed, its init, so a field a store dropped would quietly turn every DM to v1.
public struct RatchetSessionRecord: Sendable, Equatable {
    /// The peer.
    public var peerId: NodeId
    /// Whether the peer has shown it holds this root.
    public var confirmed: Bool
    /// Whether we sent the init this root came from.
    public var weAreInitiator: Bool
    /// The session root. A secret.
    public var root: [UInt8]
    /// The root a resolution kept draining, read-only, until ``prevRootExpiresAt``. A secret.
    public var prevRoot: [UInt8]?
    /// Our role under ``prevRoot``.
    public var prevRootWeAreInitiator: Bool
    /// When ``prevRoot`` stops opening frames, on our clock.
    public var prevRootExpiresAt: Int64
    /// When the session started: our clock when we initiated, else the peer's `init.at`.
    public var establishedAt: Int64
    /// Our pending init's ephemeral.
    public var initEphPub: [UInt8]?
    /// The id of the peer's prekey our init names.
    public var initPkid: Int
    /// The peer init we last resolved, known by its ephemeral.
    public var peerInitEphPub: [UInt8]?
    /// The base we DH our next epoch against: the peer's newest epoch, or the prekey our init names at epoch 0 (#174).
    public var peerBasePub: [UInt8]?
    /// That epoch's number, 0 for none.
    public var peerBaseEpoch: Int
    /// Our send epoch's number, 0 before the first.
    public var sendEpoch: Int
    /// Our send epoch's public key.
    public var sendEpochPub: [UInt8]?
    /// The chain key the next seal spends. A secret.
    public var sendChainKey: [UInt8]?
    /// How many frames the send epoch has sealed.
    public var sendCount: Int
    /// When the send epoch started, on our clock.
    public var sendEpochStartedAt: Int64
    /// The peer epoch the send epoch is based on, 0 for the peer's prekey.
    public var sendEpochBaseEpoch: Int
    /// The highest of our epochs the peer has sealed against.
    public var highestPeAcked: Int
    /// When we last sealed a reset to this peer, on our clock. It survives a restart, which the session layer's floor in
    /// memory does not.
    public var lastResetSentAt: Int64

    /// A session row, every optional field defaulting as the engine's `SessionState` does.
    public init(
        peerId: NodeId,
        confirmed: Bool,
        weAreInitiator: Bool,
        root: [UInt8],
        prevRoot: [UInt8]? = nil,
        prevRootWeAreInitiator: Bool = false,
        prevRootExpiresAt: Int64 = 0,
        establishedAt: Int64,
        initEphPub: [UInt8]? = nil,
        initPkid: Int = 0,
        peerInitEphPub: [UInt8]? = nil,
        peerBasePub: [UInt8]? = nil,
        peerBaseEpoch: Int = 0,
        sendEpoch: Int = 0,
        sendEpochPub: [UInt8]? = nil,
        sendChainKey: [UInt8]? = nil,
        sendCount: Int = 0,
        sendEpochStartedAt: Int64 = 0,
        sendEpochBaseEpoch: Int = 0,
        highestPeAcked: Int = 0,
        lastResetSentAt: Int64 = 0
    ) {
        self.peerId = peerId
        self.confirmed = confirmed
        self.weAreInitiator = weAreInitiator
        self.root = root
        self.prevRoot = prevRoot
        self.prevRootWeAreInitiator = prevRootWeAreInitiator
        self.prevRootExpiresAt = prevRootExpiresAt
        self.establishedAt = establishedAt
        self.initEphPub = initEphPub
        self.initPkid = initPkid
        self.peerInitEphPub = peerInitEphPub
        self.peerBasePub = peerBasePub
        self.peerBaseEpoch = peerBaseEpoch
        self.sendEpoch = sendEpoch
        self.sendEpochPub = sendEpochPub
        self.sendChainKey = sendChainKey
        self.sendCount = sendCount
        self.sendEpochStartedAt = sendEpochStartedAt
        self.sendEpochBaseEpoch = sendEpochBaseEpoch
        self.highestPeAcked = highestPeAcked
        self.lastResetSentAt = lastResetSentAt
    }
}
