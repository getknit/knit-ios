/// Custody's cross-platform law (`ForwardRepository.kt` in knit-next): how long a frame is carried, and how many
/// frames each bucket holds.
///
/// Every node must bound its carried set exactly this way. If the iPhone kept a frame Android drops, or dropped
/// one Android keeps, the two would never agree on what the other lacks, and every 60-second digest exchange
/// would re-send the difference forever (`.agents/context/custody.md`). Change a value only in a test.
public struct CustodyLimits: Sendable, Equatable {
    /// A frame is carried until its `sentAt` plus this: 24 hours (`DEFAULT_TTL_MS`).
    public var ttlMilliseconds: Int64
    /// A Nearby room post is carried for 6 hours (`DEFAULT_BROADCAST_TTL_MS`). Room receipts, reactions and
    /// profiles share its addressing but keep the full TTL, so they never outlive what they describe too early.
    public var roomChatTTLMilliseconds: Int64
    /// The most frames carried in all (`DEFAULT_MAX_ROWS`).
    public var maxFrames: Int
    /// The most frames carried from one sender (`DEFAULT_MAX_PER_SENDER`); a node id costs nothing to mint.
    public var maxPerSender: Int
    /// The most frames carried for one group (`DEFAULT_MAX_PER_GROUP`).
    public var maxPerGroup: Int
    /// The most room posts carried (`DEFAULT_MAX_BROADCAST`), so ambient chatter cannot crowd out DMs.
    public var maxRoomChat: Int

    /// knit-next's values unless told otherwise: 24 h, 6 h, 1000, 200, 200 and 200.
    public init(
        ttlMilliseconds: Int64 = 86_400_000,
        roomChatTTLMilliseconds: Int64 = 21_600_000,
        maxFrames: Int = 1000,
        maxPerSender: Int = 200,
        maxPerGroup: Int = 200,
        maxRoomChat: Int = 200
    ) {
        self.ttlMilliseconds = ttlMilliseconds
        self.roomChatTTLMilliseconds = roomChatTTLMilliseconds
        self.maxFrames = maxFrames
        self.maxPerSender = maxPerSender
        self.maxPerGroup = maxPerGroup
        self.maxRoomChat = maxRoomChat
    }
}
