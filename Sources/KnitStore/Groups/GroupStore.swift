import KnitSync
public import KnitWire

/// One founding member of a group, as this node holds them.
public struct GroupMember: Sendable, Equatable {
    /// The member's node id, as the roster spelled it. It is compared by its bytes (ADR 2026-09.jc2x), and a member
    /// whose id does not parse is kept, since the group's id hashes it, but is never sealed to or named.
    public var nodeId: String
    /// Whether they left, by their own signed `groupleave`. Only that frame sets it, and only their own newer frame
    /// clears it.
    public var departed: Bool
    /// When they last left, by their frame's clock clamped to ours: a rejoin must be newer. Android reads it off the
    /// `leave:` status line's `sentAt`.
    public var leftAt: Int64?
    /// When they last came back, the same way: a leave must be newer. Android reads it off the `rejoin:` line.
    public var rejoinedAt: Int64?

    /// Makes a member, present and with no clocks unless told otherwise.
    public init(nodeId: String, departed: Bool = false, leftAt: Int64? = nil, rejoinedAt: Int64? = nil) {
        self.nodeId = nodeId
        self.departed = departed
        self.leftAt = leftAt
        self.rejoinedAt = rejoinedAt
    }
}

/// A group this node is in, or has left (`GroupEntity` in knit-next, ADR 2026-09.n393).
///
/// The founding roster never grows: the id is its hash. Members only depart by their own signed `groupleave`, and
/// come back by a frame of their own. The leave and rejoin clocks live here, beside the flag they guard, so one write
/// changes both. Android keeps them in status lines, a separate row.
public struct GroupRecord: Sendable, Equatable {
    /// `g-` and 24 hex digits (``GroupInfo/idPrefix``).
    public var id: String
    /// The name, or empty when the group has none and is titled after its members.
    public var name: String
    /// Who created it, as the latest accepted frame said. It is never checked against the roster.
    public var createdBy: String
    /// When it was created: our clock for a group we made, else the clock of the first frame we saw of it.
    public var createdAt: Int64
    /// The name's last-writer-wins clock.
    public var nameUpdatedAt: Int64
    /// We left it. The row stays, so a frame from it can never bring it back.
    public var hasLeft: Bool
    /// The photo's content hash, kept so our frames repeat it, though this port never fetches the photo.
    public var photoHash: String?
    /// The photo's own last-writer-wins clock.
    public var photoUpdatedAt: Int64?
    /// The founding members in roster order, those who left included.
    public var roster: [GroupMember]

    /// Makes a record.
    public init(
        id: String,
        name: String = "",
        createdBy: String,
        createdAt: Int64,
        nameUpdatedAt: Int64 = 0,
        hasLeft: Bool = false,
        photoHash: String? = nil,
        photoUpdatedAt: Int64? = nil,
        roster: [GroupMember]
    ) {
        self.id = id
        self.name = name
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.nameUpdatedAt = nameUpdatedAt
        self.hasLeft = hasLeft
        self.photoHash = photoHash
        self.photoUpdatedAt = photoUpdatedAt
        self.roster = roster
    }

    /// The effective members, in roster order: everyone who has not left.
    public var members: [String] { roster.filter { !$0.departed }.map(\.nodeId) }

    /// The members who left, in roster order.
    public var departed: [String] { roster.filter(\.departed).map(\.nodeId) }

    /// The roster as our frames carry it (`GroupEntity.toGroupInfo`, `GroupEntity.kt:63-73`): the name only when
    /// set, and the members who left only when there are any.
    public var info: GroupInfo {
        let gone = departed
        return GroupInfo(
            id: id,
            name: name.isEmpty ? nil : name,
            members: members,
            createdBy: createdBy,
            photoHash: photoHash,
            photoUpdatedAt: photoUpdatedAt,
            departed: gone.isEmpty ? nil : gone
        )
    }

    /// `nodeId`'s place on the roster, compared by bytes.
    public func member(_ nodeId: String) -> GroupMember? {
        let key = ExactKey(nodeId)
        return roster.first { ExactKey($0.nodeId) == key }
    }
}

/// The groups this node holds (`GroupDao` and `GroupRepository` in knit-next).
public protocol GroupStore: AnyObject, Sendable {
    /// The group `id`, or `nil`.
    func group(_ id: String) -> GroupRecord?

    /// Every group, left ones included, ordered by the bytes of their ids.
    func groups() -> [GroupRecord]

    /// Stores `group` whole, roster included, replacing any row with its id.
    func save(_ group: GroupRecord)
}

/// A ``GroupStore`` in memory, keyed by the ids' bytes (``ExactKey``) and safe to share across threads.
public final class MemoryGroupStore: GroupStore {
    private let rows = Lock<[ExactKey: GroupRecord]>([:])

    /// An empty store.
    public init() {
        // Nothing to set up.
    }

    public func group(_ id: String) -> GroupRecord? {
        rows.withLock { $0[ExactKey(id)] }
    }

    public func groups() -> [GroupRecord] {
        rows.withLock { rows in
            rows.sorted { $0.key.bytes.lexicographicallyPrecedes($1.key.bytes) }.map(\.value)
        }
    }

    public func save(_ group: GroupRecord) {
        rows.withLock { $0[ExactKey(group.id)] = group }
    }
}
