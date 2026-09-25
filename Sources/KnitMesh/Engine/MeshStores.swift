public import KnitStore

/// Every repository the mesh reads and writes.
public struct MeshStores: Sendable {
    /// The frames carried for store-and-forward.
    public var custody: any CustodyStore
    /// The pinned peers.
    public var peers: any PeerStore
    /// The message threads.
    public var messages: any MessageStore
    /// The accepted conversations.
    public var conversations: any ConversationStore
    /// This node's own profile and its clocks.
    public var ownProfile: any OwnProfileStore

    /// Bundles the repositories.
    public init(
        custody: any CustodyStore,
        peers: any PeerStore,
        messages: any MessageStore,
        conversations: any ConversationStore,
        ownProfile: any OwnProfileStore
    ) {
        self.custody = custody
        self.peers = peers
        self.messages = messages
        self.conversations = conversations
        self.ownProfile = ownProfile
    }

    /// Fresh in-memory repositories, for the Linux peer and the tests.
    public static func inMemory(ownProfile: OwnProfile = OwnProfile(), custodyLimits: CustodyLimits = CustodyLimits()) -> Self {
        Self(
            custody: MemoryCustodyStore(limits: custodyLimits),
            peers: MemoryPeerStore(),
            messages: MemoryMessageStore(),
            conversations: MemoryConversationStore(),
            ownProfile: MemoryOwnProfileStore(ownProfile)
        )
    }
}

/// The engine's cadences (`MeshManager` and `MeshService` in knit-next).
public struct MeshConfiguration: Sendable {
    /// The router's tunables.
    public var router: Router.Configuration
    /// How often every linked neighbour gets our digest again, and any keys or ticks it is owed
    /// (`NEIGHBOR_REOFFER_INTERVAL_MS`). A Bluetooth link stays up, so this is its anti-entropy.
    public var reofferMilliseconds: Int64
    /// How often expired custody, parked frames and stale key wants are swept (`FORWARD_SWEEP_INTERVAL_MS`).
    public var sweepMilliseconds: Int64
    /// How often the heal pass re-asks for missing keys and republishes a stale profile (`MeshService`'s
    /// heartbeat).
    public var healMilliseconds: Int64
    /// How old our profile's publish stamp may grow before a republish, inside custody's 24 hours
    /// (`PROFILE_REPUBLISH_MS`).
    public var republishMilliseconds: Int64

    /// knit-next's cadences unless told otherwise: 60 s, 10 min, 15 min and 12 h.
    public init(
        router: Router.Configuration = Router.Configuration(),
        reofferMilliseconds: Int64 = 60_000,
        sweepMilliseconds: Int64 = 600_000,
        healMilliseconds: Int64 = 900_000,
        republishMilliseconds: Int64 = 43_200_000
    ) {
        self.router = router
        self.reofferMilliseconds = reofferMilliseconds
        self.sweepMilliseconds = sweepMilliseconds
        self.healMilliseconds = healMilliseconds
        self.republishMilliseconds = republishMilliseconds
    }
}
