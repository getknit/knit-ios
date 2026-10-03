public import KnitStore
public import KnitWire

/// What a face shows for a person, a group or the Nearby room: a photo when its bytes are held, or else an initial
/// on the tint its key wears, a group's members, or a glyph (`Avatar`, `GroupAvatar` and `RoomAvatar` in knit-next).
/// View state carries a face's hash and never its image, so a view model's cached state stays small; the app decodes
/// the photo when it draws.
public struct Face: Sendable, Equatable {
    /// What the face stands for.
    public enum Kind: Sendable, Equatable {
        /// A person, by node id.
        case person
        /// A group, by group id.
        case group
        /// The Nearby room, which has no identity behind it and so no tint.
        case room
    }

    /// What the face stands for.
    public var kind: Kind
    /// The tint's key: a person's node id or a group's id, empty for the room.
    public var key: String
    /// The letter a person's face shows without a photo. Empty for a group and the room, which show glyphs.
    public var initial: String
    /// The photo, whose bytes the blob store holds, or `nil` for none. A hash whose bytes went missing draws as if it
    /// were `nil`.
    public var photo: BlobHash?
    /// A group without a photo shows its other members, one per cell of ``FaceCluster``: empty for a person, the
    /// room, and a group with too few others to cluster, which shows a glyph on its own tint.
    public var members: [Self]

    /// The face of `nodeId`, named `name` and showing `photo` when its bytes are held.
    public static func person(_ nodeId: String, name: String, photo: BlobHash?) -> Self {
        Self(kind: .person, key: nodeId, initial: Monogram.initial(of: name), photo: photo, members: [])
    }

    /// The face of group `groupId`, showing `photo` when there is one, or else `members` (``FaceCluster/pick(_:me:)``'s
    /// pick, already in cell order).
    public static func group(_ groupId: String, photo: BlobHash?, members: [Self]) -> Self {
        Self(kind: .group, key: groupId, initial: "", photo: photo, members: members)
    }

    /// The Nearby room's face.
    public static let room = Self(kind: .room, key: "", initial: "", photo: nil, members: [])

    /// The tint slot the face wears without a photo (``AvatarTint/slot(for:)``).
    public var tint: Int {
        AvatarTint.slot(for: key)
    }
}

/// The members a group's face shows without a photo, and the cells they take (`GroupFaces.kt` and `ClusterGeometry.kt`
/// in knit-next, its ADR 2026-09.zapp). The pick is ordered by node id rather than roster order, which differs from
/// phone to phone, so two phones that know a group draw the same face in the same cell, Android's included.
public enum FaceCluster {
    /// Fewer others than this, and the group shows a glyph instead: a cluster of one would read as that person's DM.
    public static let minimum = 2
    /// The most cells, a 2×2 grid. Anyone past it is left out, with no "+N" cell.
    public static let maximum = 4
    /// The square's midline, where every seam sits.
    private static let half = 0.5

    /// One cell, in fractions of the face's square: the circle around them is the view's.
    public struct Cell: Sendable, Equatable {
        /// The left edge.
        public var left: Double
        /// The top edge.
        public var top: Double
        /// The right edge.
        public var right: Double
        /// The bottom edge.
        public var bottom: Double

        /// The width.
        public var width: Double { right - left }
        /// The height.
        public var height: Double { bottom - top }
    }

    /// The ids of the members a group's face shows (`groupFaceIds`): `members` without `me`, each once, sorted by node
    /// id, the first ``maximum``, or none when fewer than ``minimum`` others remain. Ids compare by their bytes, as
    /// Kotlin compares strings (ADR 2026-09.jc2x); node ids are ASCII, so byte order is Kotlin's order.
    public static func pick(_ members: [String], me: String) -> [String] {
        var seen: Set<ExactKey> = [ExactKey(me)]
        let others = members.filter { seen.insert(ExactKey($0)).inserted }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return others.count < minimum ? [] : Array(others.prefix(maximum))
    }

    /// The cells for `count` faces, `gap` apart as a fraction of the face's side (`clusterCells`): two are left and
    /// right halves; three, the left half and the right half split; four, quadrants, read row by row. Face `i` takes
    /// cell `i`. Each interior edge gives up half the gap to either side, so the seam is exactly `gap` wide and the
    /// outer edges stay flush. A count outside ``minimum``...``maximum``, or a gap outside `0..<0.5`, has no cells,
    /// where Android's `require` throws.
    public static func cells(count: Int, gap: Double) -> [Cell] {
        guard (minimum...maximum).contains(count), (0..<half).contains(gap) else {
            return []
        }
        let shave = gap * half
        let left = Cell(left: 0, top: 0, right: half - shave, bottom: 1)
        let topRight = Cell(left: half + shave, top: 0, right: 1, bottom: half - shave)
        let bottomRight = Cell(left: half + shave, top: half + shave, right: 1, bottom: 1)
        switch count {
        case minimum:
            return [left, Cell(left: half + shave, top: 0, right: 1, bottom: 1)]
        case maximum:
            return [
                Cell(left: 0, top: 0, right: half - shave, bottom: half - shave),
                topRight,
                Cell(left: 0, top: half + shave, right: half - shave, bottom: 1),
                bottomRight,
            ]
        default:
            return [left, topRight, bottomRight]
        }
    }
}

extension Directory {
    /// The face of `nodeId`: their photo, or their label's initial on their tint. Our own id shows our photo.
    public func face(for nodeId: NodeId) -> Face {
        face(forMember: nodeId.string)
    }

    /// The face of a roster member, by the id the roster spells. One that is no node id still gets an initial.
    public func face(forMember id: String) -> Face {
        let nodeId = NodeId(id)
        let photo = nodeId == me ? myPhoto : nodeId.flatMap { peers[$0]?.avatarHash }
        return .person(id, name: labels.label(for: id).name, photo: photo)
    }

    /// The face of `group`, from our side: its other current members, or the glyph on its own tint. This port does not
    /// fetch group photos yet (ADR 2026-10.nh55), so no group shows one.
    public func face(of group: GroupRecord) -> Face {
        .group(group.id, photo: nil, members: FaceCluster.pick(group.members, me: me.string).map(face(forMember:)))
    }
}
