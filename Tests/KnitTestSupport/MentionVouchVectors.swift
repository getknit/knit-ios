/// knit-next's mention contract, `vectors/mention-vouch-v1.json` (knit-next #247, knit-ios #36), copied into
/// `Tests/Vectors/` by `scripts/sync-vectors.py`: directories of people with the label each id must get, and received
/// rows with the entries a bubble keeps and the spans it lights. Every port checks its own labels and rule against it.
public enum MentionVouchVectors {
    /// The file's name, here and in knit-next's `vectors/`.
    public static let fileName = "mention-vouch-v1.json"

    /// The file's shape.
    public struct File: Decodable, Sendable {
        /// The most alias tokens a label may spend.
        public let maxTokens: Int
        /// The `@everyone` token's name.
        public let everyone: String
        /// How many counted rows a thread's window holds.
        public let window: Int
        /// Us, the reader.
        public let me: Person
        /// The directories, by name, read with the content filter off.
        public let directories: [String: Directory]
        /// The rows.
        public let cases: [Case]
        /// Threads, with the counted rows that fall outside their window.
        public let windows: [Window]
    }

    /// A node id and a name; `""` for a blank name. A mention has the same shape.
    public struct Person: Decodable, Sendable {
        /// The node id.
        public let nodeId: String
        /// The name.
        public let name: String
    }

    /// The people one reader knows, and the label each id gets there.
    public struct Directory: Decodable, Sendable {
        /// The peers, besides us.
        public let peers: [Person]
        /// Ids outside the directory whose labels are pinned too.
        public let unknown: [String]
        /// The label text for every peer, us and every unknown id.
        public let labels: [String: String]
    }

    /// One received row and what its bubble shows.
    public struct Case: Decodable, Sendable {
        /// Why the case is there.
        public let label: String
        /// The directory's name.
        public let directory: String
        /// `direct`, `room` or `group`.
        public let thread: String
        /// The group's members; `nil` outside a group.
        public let roster: [String]?
        /// The sender's node id.
        public let sender: String
        /// The words.
        public let body: String
        /// The row's mentions, as received.
        public let mentions: [Person]
        /// Indexes into `mentions` of the entries kept.
        public let kept: [Int]
        /// `[start, end]` pairs in UTF-16 code units, sorted by start.
        public let spans: [[Int]]
        /// Whether the row is inside its thread's window.
        public let inWindow: Bool
    }

    /// A thread's stored rows, and which counted ones its window leaves out.
    public struct Window: Decodable, Sendable {
        /// Why the case is there.
        public let label: String
        /// The rows.
        public let rows: [WindowRow]
        /// The senders on our block list, whose rows don't count.
        public let blocked: [String]
        /// The ids of the counted rows outside the window.
        public let outside: [String]
    }

    /// What a window reads of a row.
    public struct WindowRow: Decodable, Sendable {
        /// The message id.
        public let id: String
        /// The sender's node id.
        public let sender: String
        /// When it was sent, as stored.
        public let sentAt: Int64
        /// How many entries its mention list holds.
        public let mentions: Int
    }

    /// The file, read once.
    public static let file = VectorFile.read(fileName, as: File.self)
}
