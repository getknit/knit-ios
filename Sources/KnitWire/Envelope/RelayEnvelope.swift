/// Layer 2, the signed routing envelope (`RelayEnvelope` in knit-next's `Wire.kt`).
///
/// It carries only what a relay or a carrier needs in the clear: the type, the id, the sender, the
/// timestamp, and the addressing. A DM sets ``recipientId``, a group message sets ``group``, and a Nearby
/// room post sets neither. The per-type content is the opaque ``payload``.
public struct RelayEnvelope: CBORRepresentable, Equatable {
    /// The frame type, a plain string so a type this build does not know still decodes and relays.
    public var type: FrameType
    /// The frame id: the dedup key, and the id a receipt acknowledges.
    public var id: String
    /// The originator's node id.
    public var senderId: String
    /// The originator's wall clock in epoch milliseconds, signed. Custody expires relative to it.
    public var sentAt: Int64
    /// The recipient's node id, for a DM.
    public var recipientId: String?
    /// The roster, for a group message.
    public var group: GroupInfo?
    /// The per-type content, opaque to relays.
    public var payload: [UInt8]

    /// Makes an envelope.
    public init(
        type: FrameType,
        id: String,
        senderId: String,
        sentAt: Int64 = 0,
        recipientId: String? = nil,
        group: GroupInfo? = nil,
        payload: [UInt8]
    ) {
        self.type = type
        self.id = id
        self.senderId = senderId
        self.sentAt = sentAt
        self.recipientId = recipientId
        self.group = group
        self.payload = payload
    }

    /// Reads an envelope from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "RelayEnvelope")
        type = FrameType(rawValue: try fields.required("type", .text))
        id = try fields.required("id", .text)
        senderId = try fields.required("senderId", .text)
        sentAt = try fields.optional("sentAt", .int64) ?? 0
        recipientId = try fields.nullable("recipientId", .text)
        group = try fields.nullable("group", .object(GroupInfo.self))
        payload = try fields.required("payload", .bytes)
    }

    /// The envelope as an item, defaults omitted.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("type", type.rawValue)
        writer.text("id", id)
        writer.text("senderId", senderId)
        writer.long("sentAt", sentAt, default: 0)
        writer.text("recipientId", optional: recipientId)
        writer.object("group", optional: group)
        writer.bytes("payload", payload)
        return writer.cbor
    }

    /// Whether this is a Nearby room post: a chat with no recipient and no group.
    public var isRoomPost: Bool { type == .chat && recipientId == nil && group == nil }

    /// Whether this is a DM-form frame: a chat addressed to one node and not to a group.
    public var isDirect: Bool { type == .chat && recipientId != nil && group == nil }
}
