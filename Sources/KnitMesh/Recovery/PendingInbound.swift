public import KnitWire

/// Frames parked because their sender's key was not pinned when they arrived (`PendingInbound.kt`), replayed
/// once the sender's profile pins, so a message that outran its sender's profile still lands.
///
/// A parked frame is unauthenticated until then, so it stays in memory only, and three bounds keep a flood of
/// forged sender ids cheap: 16 frames per claimed sender, 128 in all, and two minutes each, oldest evicted
/// first. Times are on the monotonic clock.
public struct PendingInbound: Sendable {
    /// A parked frame.
    public struct Parked: Sendable, Equatable {
        /// The frame as it arrived, replayed verbatim.
        public var frame: InboundFrame
        /// When it was parked.
        public var parkedAt: Int64
    }

    /// How long a frame waits for its key (`HOLD_TTL_MS`).
    public static let defaultHoldMilliseconds: Int64 = 120_000
    /// The most frames parked at once (`MAX_FRAMES`): the real bound, since the sender id is only a claim.
    public static let defaultCapacity = 128
    /// The most frames parked for one claimed sender (`MAX_PER_SENDER`).
    public static let defaultPerSender = 16

    private let holdMilliseconds: Int64
    private let capacity: Int
    private let perSender: Int
    /// Oldest first.
    private var parked: [Parked] = []

    /// A buffer with knit-next's bounds unless told otherwise.
    public init(
        holdMilliseconds: Int64 = Self.defaultHoldMilliseconds,
        capacity: Int = Self.defaultCapacity,
        perSender: Int = Self.defaultPerSender
    ) {
        self.holdMilliseconds = holdMilliseconds
        self.capacity = capacity
        self.perSender = perSender
    }

    /// How many frames are parked.
    public var count: Int { parked.count }

    /// Whether nothing is parked.
    public var isEmpty: Bool { parked.isEmpty }

    /// Parks a frame, and answers whether it did: not when its id is already parked, or its sender already has
    /// its share. Past the global cap the oldest frame goes.
    public mutating func hold(_ frame: InboundFrame, now: Int64) -> Bool {
        let id = ExactKey(frame.envelope.id)
        let sender = ExactKey(frame.envelope.senderId)
        guard !parked.contains(where: { ExactKey($0.frame.envelope.id) == id }),
            parked.count(where: { ExactKey($0.frame.envelope.senderId) == sender }) < perSender
        else {
            return false
        }
        parked.append(Parked(frame: frame, parkedAt: now))
        if parked.count > capacity {
            parked.removeFirst()
        }
        return true
    }

    /// Removes and answers every frame parked for `sender`, oldest first, to replay now that its key is pinned.
    public mutating func release(_ sender: NodeId) -> [Parked] {
        let key = ExactKey(sender.string)
        let released = parked.filter { ExactKey($0.frame.envelope.senderId) == key }
        parked.removeAll { ExactKey($0.frame.envelope.senderId) == key }
        return released
    }

    /// Drops every frame parked longer than the hold, and answers how many.
    @discardableResult
    public mutating func sweep(now: Int64) -> Int {
        let before = parked.count
        parked.removeAll { now - $0.parkedAt > holdMilliseconds }
        return before - parked.count
    }
}
