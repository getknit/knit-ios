/// A group's roster, carried in the clear on a group frame (`GroupInfo` in knit-next's `Wire.kt`).
///
/// The MVP has no groups; it decodes rosters so it can carry and relay group frames for others, and so the
/// custody rule that serves a group frame only to its members can run.
public struct GroupInfo: CBORRepresentable, Equatable {
    /// The group id, `g-` plus 24 hex characters: the hash of the member set.
    public var id: String
    /// The group's name, if set.
    public var name: String?
    /// The members' node ids.
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
