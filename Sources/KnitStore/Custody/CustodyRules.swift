public import KnitWire

/// The rules a custody store applies to every frame it is handed (`ForwardRepository.store` and `insertAndTrim`
/// in knit-next). They are pure, so every store implementation applies the same ones.
///
/// Every rule reads live frames only. A row past its expiry that has not been swept yet is per-node state (each
/// node sweeps on its own schedule), so letting one count toward a quota would evict different live frames on
/// different nodes (knit-next's work item #8).
public enum CustodyRules {
    /// What the quotas read of a carried frame.
    public struct Entry: Sendable, Equatable {
        /// The frame id.
        public var id: String
        /// The originator.
        public var senderId: String
        /// The group, for a group frame.
        public var groupId: String?
        /// Whether it is a room post (chat, no recipient, no group), the one class the room quota counts.
        public var isRoomChat: Bool
        /// The originator's clock: the eviction key, identical on every node.
        public var sentAt: Int64
        /// When custody ends, also identical on every node.
        public var expiresAt: Int64

        /// Makes an entry.
        public init(id: String, senderId: String, groupId: String?, isRoomChat: Bool, sentAt: Int64, expiresAt: Int64) {
            self.id = id
            self.senderId = senderId
            self.groupId = groupId
            self.isRoomChat = isRoomChat
            self.sentAt = sentAt
            self.expiresAt = expiresAt
        }

        /// The entry for an envelope that expires at `expiresAt`.
        public init(_ envelope: RelayEnvelope, expiresAt: Int64) {
            self.init(
                id: envelope.id,
                senderId: envelope.senderId,
                groupId: envelope.group?.id,
                isRoomChat: envelope.isRoomPost,
                sentAt: envelope.sentAt,
                expiresAt: expiresAt
            )
        }
    }

    /// When custody of a frame ends: its `sentAt` plus its TTL, so every node, originator and carriers alike,
    /// drops it at the same instant. `nil` when the frame must be refused: already past that instant (a
    /// skewed peer re-serving what everyone has swept, or a `sentAt` of 0), or dated more than five minutes
    /// ahead of `now`, which would make it unsweepable and the newest frame in every bucket.
    public static func expiry(of envelope: RelayEnvelope, now: Int64, limits: CustodyLimits) -> Int64? {
        let ttl = envelope.isRoomPost ? limits.roomChatTTLMilliseconds : limits.ttlMilliseconds
        // Kotlin's Long addition wraps, so a hostile sentAt near the top of the range lands in the past and is
        // refused. Wrapping here refuses it the same way instead of trapping.
        let expiresAt = envelope.sentAt &+ ttl
        guard expiresAt >= now, envelope.sentAt <= now + WireProtocol.maxFutureSkewMilliseconds else {
            return nil
        }
        return expiresAt
    }

    /// Whether `lhs` is evicted before `rhs`: the older `sentAt` first, then the id's bytes, which is how SQLite's
    /// BINARY collation orders `ORDER BY sentAt ASC, id ASC` (`ForwardDao.evictOldest`).
    public static func evictsBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        guard lhs.sentAt == rhs.sentAt else {
            return lhs.sentAt < rhs.sentAt
        }
        return lhs.id.utf8.lexicographicallyPrecedes(rhs.id.utf8)
    }

    /// The ids to evict once `inserted` has joined `live`, the live entries including it.
    ///
    /// Each over-quota bucket keeps its newest N, in the fixed order sender, group, room, then everything, and
    /// each count sees the evictions before it. A frame older than its bucket's newest N is evicted the moment it
    /// arrives, which is right: every node converges on the same newest N whatever order frames arrive in.
    public static func evictions(after inserted: Entry, among live: [Entry], limits: CustodyLimits) -> [String] {
        var remaining = live
        var evicted: [String] = []
        func trim(to quota: Int, _ inBucket: (Entry) -> Bool) {
            let bucket = remaining.filter(inBucket).sorted(by: evictsBefore)
            guard bucket.count > quota else {
                return
            }
            let doomed = bucket.prefix(bucket.count - quota).map(\.id)
            evicted += doomed
            let doomedSet = Set(doomed)
            remaining.removeAll { doomedSet.contains($0.id) }
        }
        trim(to: limits.maxPerSender) { $0.senderId == inserted.senderId }
        if let group = inserted.groupId {
            trim(to: limits.maxPerGroup) { $0.groupId == group }
        }
        if inserted.isRoomChat {
            trim(to: limits.maxRoomChat, \.isRoomChat)
        }
        trim(to: limits.maxFrames) { _ in true }
        return evicted
    }
}
