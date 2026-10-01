/// A group's roster, carried in the clear on every group `chat` and `groupupdate` (`GroupInfo` in knit-next's
/// `Wire.kt`, ADR 2026-09.n393).
///
/// A sender rebuilds it from its own row for every frame, so a frame always says what its sender holds: the effective
/// members, the members who left, the name and the photo. Custody also reads it, to serve a group frame only to its
/// members.
public struct GroupInfo: CBORRepresentable, Equatable {
    /// What every group id starts with (`GROUP_ID_PREFIX`). A base32 node id never has a hyphen, so no group id can
    /// be mistaken for one, or for the `nearby` room.
    public static let idPrefix = "g-"
    /// At most this many founding members, the creator included (`GroupInfo.MAX_MEMBERS`, `Wire.kt:382`).
    public static let maxMembers = 8

    /// The group id, `g-` plus 24 hex characters: the hash of the member set.
    public var id: String
    /// The group's name, if set.
    public var name: String?
    /// The effective members: the founding set less those who left, in roster order. The id hashes these together
    /// with ``departed``.
    public var members: [String]
    /// The founder's node id.
    public var createdBy: String
    /// The group photo's content hash, if set.
    public var photoHash: String?
    /// When the photo last changed, in epoch milliseconds.
    public var photoUpdatedAt: Int64?
    /// Members who left, when the sender knows of any.
    public var departed: [String]?

    /// Makes a roster.
    public init(
        id: String,
        name: String? = nil,
        members: [String],
        createdBy: String,
        photoHash: String? = nil,
        photoUpdatedAt: Int64? = nil,
        departed: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.members = members
        self.createdBy = createdBy
        self.photoHash = photoHash
        self.photoUpdatedAt = photoUpdatedAt
        self.departed = departed
    }

    /// Reads a roster from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "GroupInfo")
        id = try fields.required("id", .text)
        name = try fields.nullable("name", .text)
        members = try fields.required("members", .texts)
        createdBy = try fields.required("createdBy", .text)
        photoHash = try fields.nullable("photoHash", .text)
        photoUpdatedAt = try fields.nullable("photoUpdatedAt", .int64)
        departed = try fields.nullable("departed", .texts)
    }

    /// The roster as an item, defaults omitted.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("id", id)
        writer.text("name", optional: name)
        writer.texts("members", members)
        writer.text("createdBy", createdBy)
        writer.text("photoHash", optional: photoHash)
        writer.long("photoUpdatedAt", optional: photoUpdatedAt)
        writer.texts("departed", optional: departed)
        return writer.cbor
    }
}
