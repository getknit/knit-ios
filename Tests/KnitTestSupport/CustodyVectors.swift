/// knit-next's custody contract, `vectors/custody-v1.json` (knit-next ADR 2026-10.7mqm and 2026-10.mqzv), copied into
/// `Tests/Vectors/` by `scripts/sync-vectors.py`: small limits, frames stored one at a time, and after each the store's
/// answer, the live ids its write evicted and the live set it holds. Every port replays the steps through its own
/// stores.
public enum CustodyVectors {
    /// The file's shape.
    public struct File: Decodable, Sendable {
        /// The rule, in the file's words.
        public let about: String
        /// The limits every step runs under.
        public let limits: Limits
        /// The frames, in the order they are stored.
        public let steps: [Step]
    }

    /// The store's limits, in Kotlin's names.
    public struct Limits: Decodable, Sendable {
        /// The global cap (`maxRows`).
        public let maxRows: Int
        /// The sender quota.
        public let maxPerSender: Int
        /// The group quota.
        public let maxPerGroup: Int
        /// The room quota (`maxBroadcast`).
        public let maxBroadcast: Int
        /// The TTL of everything but room posts.
        public let ttlMs: Int64
        /// A room post's TTL.
        public let broadcastTtlMs: Int64
        /// The future window.
        public let maxFutureSkewMs: Int64
        /// The byte cap on a frame's `signed` (knit-next ADR 2026-10.mqzv).
        public let maxSignedBytes: Int
        /// The cap on a profile's `signed` (knit-next ADR 2026-10.jgeg, ADR 2026-10.r88m).
        public let maxProfileSignedBytes: Int
    }

    /// One store and what it must answer.
    public struct Step: Decodable, Sendable {
        /// Why the step is there.
        public let note: String
        /// The store's clock for this step.
        public let now: Int64
        /// The frame stored.
        public let frame: Frame
        /// The length of the `signed` bytes the store is handed, checked before the step replays, so a padded frame that
        /// encodes differently fails as that and not as a custody disagreement.
        public let signedBytes: Int
        /// Whether the frame is a room post.
        public let isRoomChat: Bool
        /// When custody of the frame ends, refused or not.
        public let expiresAt: Int64
        /// Whether the store holds the frame after its own write.
        public let kept: Bool
        /// The live ids the write removed, sorted.
        public let evicted: [String]
        /// The live ids after the write, sorted.
        public let held: [String]
    }

    /// A frame's envelope fields, as the file states them.
    public struct Frame: Decodable, Sendable {
        /// The frame id.
        public let id: String
        /// The frame type's wire name.
        public let type: String
        /// The originator.
        public let senderId: String
        /// A DM's recipient.
        public let recipientId: String?
        /// A group frame's roster.
        public let group: Group?
        /// The originator's clock.
        public let sentAt: Int64
        /// The length of the chat body of "x"s that pads the frame, absent for an empty body (knit-next ADR
        /// 2026-10.mqzv).
        public let bodyLength: Int?
    }

    /// A group frame's roster: its id, its members and who departed.
    public struct Group: Decodable, Sendable {
        /// The group id.
        public let id: String
        /// The members left.
        public let members: [String]
        /// Who departed, absent before 2.3.0.
        public let departed: [String]?
    }

    /// The file's name, here and in knit-next's `vectors/`.
    public static let fileName = "custody-v1.json"

    /// The file, read once.
    public static let file = VectorFile.read(fileName, as: File.self)
}
