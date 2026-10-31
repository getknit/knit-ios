/// Custody's cross-platform law (`ForwardRepository.kt` in knit-next): how long a frame is carried, how many frames
/// each bucket holds, and how long one frame's `signed` bytes may be.
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
    /// The longest `signed` custody carries, in bytes: 60 KiB (`DEFAULT_MAX_SIGNED_BYTES`, knit-next #227). A longer
    /// frame is refused, and the sweep deletes one a build without the cap stored. Only `signed` is counted, never `sig`.
    /// With it the row cap bounds what custody holds on disk and re-serves: 1000 rows of 60 KiB, where any size went
    /// before. No honest build of either platform authors a longer frame.
    public var maxSignedBytes: Int
    /// The longest `signed` custody carries for a profile frame, in bytes: 8 KiB. A longer profile is refused, and the sweep
    /// deletes one a build without this cap stored. Only `signed` is counted, never `sig`, as for ``maxSignedBytes``, which
    /// binds first, so a profile over both is refused as oversize. The largest profile an honest build authors is 949 bytes
    /// of `signed` here and 1,017 on Android, so the cap leaves room for every field both send, and it equals Android's
    /// frame ceiling on its fast and LoRa links. The engine refuses the same profiles before it reads them, and it reads this
    /// value from the store, so a rig that lowers one lowers both.
    public var maxProfileSignedBytes: Int

    /// knit-next's values unless told otherwise: 24 h, 6 h, 1000, 200, 200, 200, 61,440 bytes and 8,192 bytes.
    public init(
        ttlMilliseconds: Int64 = 86_400_000,
        roomChatTTLMilliseconds: Int64 = 21_600_000,
        maxFrames: Int = 1000,
        maxPerSender: Int = 200,
        maxPerGroup: Int = 200,
        maxRoomChat: Int = 200,
        maxSignedBytes: Int = 61_440,
        maxProfileSignedBytes: Int = 8192
    ) {
        self.ttlMilliseconds = ttlMilliseconds
        self.roomChatTTLMilliseconds = roomChatTTLMilliseconds
        self.maxFrames = maxFrames
        self.maxPerSender = maxPerSender
        self.maxPerGroup = maxPerGroup
        self.maxRoomChat = maxRoomChat
        self.maxSignedBytes = maxSignedBytes
        self.maxProfileSignedBytes = maxProfileSignedBytes
    }
}
