public import KnitStore
public import KnitWire

/// Every repository the mesh reads and writes, and the store unit they commit in.
///
/// The repositories are fixed once bundled, because ``transactor`` was made over these: a store swapped in later would
/// keep its writes when a unit is undone.
public struct MeshStores: Sendable {
    /// The frames carried for store-and-forward.
    public let custody: any CustodyStore
    /// The pinned peers.
    public let peers: any PeerStore
    /// The message threads.
    public let messages: any MessageStore
    /// The accepted conversations.
    public let conversations: any ConversationStore
    /// The people the user blocked: read on the delivery path only, never by custody or relaying (ADR 2026-10.5wgg).
    public let blocks: any BlockStore
    /// The groups we are in, or left.
    public let groups: any GroupStore
    /// This node's own profile and its clocks.
    public let ownProfile: any OwnProfileStore
    /// The photos held: ours, other people's, and the ones carried for others.
    public let blobs: any BlobStore
    /// The DM ratchet's sessions, our epochs, receive chains and skipped keys (ADR 2026-10.5sk9), which ``RatchetSessions``
    /// alone writes, inside ``transactor``'s units.
    public let ratchet: any RatchetStore
    /// The group form's chains, skipped keys and seed outbox (ADR 2026-10.5sk9, phase P6a1), which ``GroupRatchetSessions``
    /// alone writes, inside ``transactor``'s units. Nothing reads or writes it with the switch off.
    public let groupRatchet: any GroupRatchetStore
    /// The store unit a ratchet change commits in with everything it carries, or not at all (ADR 2026-10.5sk9): the
    /// database itself under the SQL stores, or a ``MemoryTransactor`` over the memory ones.
    public let transactor: any StoreTransactor

    /// Bundles the repositories with the unit they commit in, which must cover every one of them.
    public init(
        custody: any CustodyStore,
        peers: any PeerStore,
        messages: any MessageStore,
        conversations: any ConversationStore,
        blocks: any BlockStore,
        groups: any GroupStore,
        ownProfile: any OwnProfileStore,
        blobs: any BlobStore,
        ratchet: any RatchetStore,
        groupRatchet: any GroupRatchetStore,
        transactor: any StoreTransactor
    ) {
        self.custody = custody
        self.peers = peers
        self.messages = messages
        self.conversations = conversations
        self.blocks = blocks
        self.groups = groups
        self.ownProfile = ownProfile
        self.blobs = blobs
        self.ratchet = ratchet
        self.groupRatchet = groupRatchet
        self.transactor = transactor
    }

    /// Fresh in-memory repositories under one ``MemoryTransactor``, for the tests and the demo.
    public static func inMemory(ownProfile: OwnProfile = OwnProfile(), custodyLimits: CustodyLimits = CustodyLimits()) -> Self {
        inMemory(ownProfileStore: MemoryOwnProfileStore(ownProfile), custodyLimits: custodyLimits)
    }

    /// Fresh in-memory repositories around `ownProfileStore`, the Linux peer's file or a test's double, under one
    /// ``MemoryTransactor`` that covers it with the rest.
    public static func inMemory(
        ownProfileStore: some OwnProfileStore & Checkpointing,
        custodyLimits: CustodyLimits = CustodyLimits()
    ) -> Self {
        let memoryCustody = MemoryCustodyStore(limits: custodyLimits)
        let memoryPeers = MemoryPeerStore()
        let memoryMessages = MemoryMessageStore()
        let memoryConversations = MemoryConversationStore()
        let memoryBlocks = MemoryBlockStore()
        let memoryGroups = MemoryGroupStore()
        let memoryBlobs = MemoryBlobStore()
        let memoryRatchet = MemoryRatchetStore()
        let memoryGroupRatchet = MemoryGroupRatchetStore()
        return Self(
            custody: memoryCustody,
            peers: memoryPeers,
            messages: memoryMessages,
            conversations: memoryConversations,
            blocks: memoryBlocks,
            groups: memoryGroups,
            ownProfile: ownProfileStore,
            blobs: memoryBlobs,
            ratchet: memoryRatchet,
            groupRatchet: memoryGroupRatchet,
            transactor: MemoryTransactor(stores: [
                memoryCustody, memoryPeers, memoryMessages, memoryConversations, memoryBlocks, memoryGroups, ownProfileStore, memoryBlobs,
                memoryRatchet, memoryGroupRatchet,
            ])
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
    /// Whether a fetch queries the neighbours that answer one before it asks for a blob (`BuildConfig.BLOB_QUERY`,
    /// knit-next ADR 2026-10.6e5t): on in the app, in every build, and in the Linux peer. Off, the default tests start
    /// from, every neighbour gets the blind round. Answering a query is on whatever this says.
    public var queriesBlobHolders: Bool
    /// How long someone's typing cue shows after it lands, unless another pushes it out (`TYPING_TTL_MS`,
    /// `TypingTracker.kt:111`).
    public var typingLifetimeMilliseconds: Int64
    /// How long after one of our typing cues the next may go to the same thread (`TYPING_SEND_INTERVAL_MS`,
    /// `ChatViewModel.kt:2542`): the first keystroke after a quiet spell sends one at once, and the rest wait it out.
    public var typingIntervalMilliseconds: Int64
    /// The forward-secrecy ratchet's switch (ADR 2026-10.5sk9): on in the app, in every build, and in the Linux peer; off,
    /// the default tests start from, and through a debug build's `-ratchet off` or the peer's `--no-ratchet`. On, our signed
    /// profile carries our prekey and ``capabilities``' three ratchet bits, kept and rotated in the identity's store, and
    /// DMs and groups seal and open with the ratchet toward peers whose profiles claim it. Off, the profile is what it was
    /// before the ratchet, and nothing seals with it. The HELLO and the advert carry ``Capabilities/local`` either way,
    /// since Android reads these bits from the pinned profile alone (`CryptoScheme.kt:11-13`). Taking peers' prekeys runs
    /// either way, since it sends nothing.
    public var ratchet: Bool

    /// What our signed profile advertises while it carries our prekey: ``Capabilities/local`` (`0x15F`) with the switch
    /// on, and without ``Capabilities/ratchetSuite`` (`0xF`) with it off.
    public var capabilities: Capabilities {
        ratchet ? .local : Capabilities.local.subtracting(.ratchetSuite)
    }

    /// knit-next's cadences unless told otherwise: 60 s, 10 min, 15 min and 12 h, and typing's 12 s and 8 s. The ratchet
    /// is off unless asked for, as the blob query is: the app and the peer ask, and a test starts from the build before it.
    public init(
        router: Router.Configuration = Router.Configuration(),
        reofferMilliseconds: Int64 = 60_000,
        sweepMilliseconds: Int64 = 600_000,
        healMilliseconds: Int64 = 900_000,
        republishMilliseconds: Int64 = 43_200_000,
        queriesBlobHolders: Bool = false,
        typingLifetimeMilliseconds: Int64 = 12_000,
        typingIntervalMilliseconds: Int64 = 8000,
        ratchet: Bool = false
    ) {
        self.router = router
        self.reofferMilliseconds = reofferMilliseconds
        self.sweepMilliseconds = sweepMilliseconds
        self.healMilliseconds = healMilliseconds
        self.republishMilliseconds = republishMilliseconds
        self.queriesBlobHolders = queriesBlobHolders
        self.typingLifetimeMilliseconds = typingLifetimeMilliseconds
        self.typingIntervalMilliseconds = typingIntervalMilliseconds
        self.ratchet = ratchet
    }
}
