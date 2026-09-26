import KnitStore
public import KnitWire

/// Frames parked because their sender's key was not pinned when they arrived (`PendingInbound.kt`), replayed
/// once the sender's profile pins, so a message that outran its sender's profile still lands.
///
/// A parked frame is unauthenticated until then, so it stays in memory only, and four bounds keep a flood of
/// forged sender ids cheap: a carrier's custody quota per claimed sender, 512 frames and 4 MiB in all, and two
/// minutes each, oldest evicted first. Times are on the monotonic clock.
///
/// The per-sender cap is the whole custody quota for one sender (knit-next ADR 2026-09.9xuu): a newcomer is
/// served a stranger's backlog in one burst, and every frame of it turned away here has already been marked
/// seen, so its re-serves are duplicates for the SeenSet's ten minutes. The byte budget keeps the larger cap
/// cheap.
public struct PendingInbound: Sendable {
    /// A parked frame.
    public struct Parked: Sendable, Equatable {
        /// The frame as it arrived, replayed verbatim.
        public var frame: InboundFrame
        /// When it was parked.
        public var parkedAt: Int64

        /// What holding it costs, near enough: the signed unit and its signature.
        public var bytes: Int { frame.wire.signed.count + frame.wire.sig.count }
    }

    /// How long a frame waits for its key (`HOLD_TTL_MS`).
    public static let defaultHoldMilliseconds: Int64 = 120_000
    /// The most frames parked at once (`MAX_FRAMES`), a bound beside the byte budget.
    public static let defaultCapacity = 512
    /// The most frames parked for one claimed sender (`MAX_PER_SENDER`): a carrier's custody quota for one
    /// sender, derived from it so the two cannot drift, so one served backlog parks whole.
    public static let defaultPerSender = CustodyLimits().maxPerSender
    /// The most bytes parked at once (`MAX_BYTES`, 4 MiB): the memory bound, since the sender id is only a claim.
    public static let defaultMaxBytes = 4_194_304

    private let holdMilliseconds: Int64
    private let capacity: Int
    private let perSender: Int
    private let maxBytes: Int
    /// Oldest first.
    private var parked: [Parked] = []
    /// The bytes `parked` holds, against `maxBytes`.
    private var parkedBytes = 0

    /// A buffer with knit-next's bounds unless told otherwise.
    public init(
        holdMilliseconds: Int64 = Self.defaultHoldMilliseconds,
        capacity: Int = Self.defaultCapacity,
        perSender: Int = Self.defaultPerSender,
        maxBytes: Int = Self.defaultMaxBytes
    ) {
        self.holdMilliseconds = holdMilliseconds
        self.capacity = capacity
        self.perSender = perSender
        self.maxBytes = maxBytes
    }

    /// How many frames are parked.
    public var count: Int { parked.count }

    /// Whether nothing is parked.
    public var isEmpty: Bool { parked.isEmpty }

    /// Parks a frame, and answers whether it did: not when its id is already parked, its sender already has its
    /// share, or it alone is over the byte budget. Past either global bound the oldest frames go.
    public mutating func hold(_ frame: InboundFrame, now: Int64) -> Bool {
        let id = ExactKey(frame.envelope.id)
        let sender = ExactKey(frame.envelope.senderId)
        let entry = Parked(frame: frame, parkedAt: now)
        guard !parked.contains(where: { ExactKey($0.frame.envelope.id) == id }),
            parked.count(where: { ExactKey($0.frame.envelope.senderId) == sender }) < perSender,
            entry.bytes <= maxBytes
        else {
            return false
        }
        parked.append(entry)
        parkedBytes += entry.bytes
        while parked.count > capacity || parkedBytes > maxBytes {
            parkedBytes -= parked.removeFirst().bytes
        }
        return true
    }

    /// Removes and answers every frame parked for `sender`, oldest first, to replay now that its key is pinned.
    public mutating func release(_ sender: NodeId) -> [Parked] {
        let key = ExactKey(sender.string)
        let released = parked.filter { ExactKey($0.frame.envelope.senderId) == key }
        parked.removeAll { ExactKey($0.frame.envelope.senderId) == key }
        parkedBytes -= released.reduce(0) { $0 + $1.bytes }
        return released
    }

    /// Drops every frame parked longer than the hold, and answers how many.
    @discardableResult
    public mutating func sweep(now: Int64) -> Int {
        let expired = parked.filter { now - $0.parkedAt > holdMilliseconds }
        parked.removeAll { now - $0.parkedAt > holdMilliseconds }
        parkedBytes -= expired.reduce(0) { $0 + $1.bytes }
        return expired.count
    }
}
