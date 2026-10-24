/// A cleartext delivery receipt's payload (`ReceiptContent` in knit-next's `Wire.kt`).
public struct ReceiptContent: CBORRepresentable, Equatable {
    /// The frame id being acknowledged.
    public var ackId: String

    /// Makes a receipt.
    public init(ackId: String) {
        self.ackId = ackId
    }

    /// Reads a receipt from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "ReceiptContent")
        ackId = try fields.required("ackId", .text)
    }

    /// The receipt as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("ackId", ackId)
        return writer.cbor
    }
}

/// A cleartext reaction's payload (`ReactionContent`), and the sealed reaction's `rp` payload
/// (`ReactionPayload`), which knit-next keeps field-compatible on purpose.
public struct ReactionContent: CBORRepresentable, Equatable {
    /// The frame id reacted to.
    public var messageId: String
    /// The emoji, or `nil` to retract a reaction.
    public var emoji: String?

    /// Makes a reaction; a `nil` emoji retracts.
    public init(messageId: String, emoji: String? = nil) {
        self.messageId = messageId
        self.emoji = emoji
    }

    /// Reads a reaction from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "ReactionContent")
        messageId = try fields.required("messageId", .text)
        emoji = try fields.nullable("emoji", .text)
    }

    /// The reaction as an item, a retraction's emoji omitted.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("messageId", messageId)
        writer.text("emoji", optional: emoji)
        return writer.cbor
    }
}

/// A member leaving a group (`GroupLeaveContent` in knit-next's `Wire.kt`).
public struct GroupLeaveContent: CBORRepresentable, Equatable {
    /// The group being left.
    public var groupId: String

    /// Makes a leave.
    public init(groupId: String) {
        self.groupId = groupId
    }

    /// Reads a leave from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "GroupLeaveContent")
        groupId = try fields.required("groupId", .text)
    }

    /// The leave as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("groupId", groupId)
        return writer.cbor
    }
}

/// A request for the profiles of senders whose keys are missing (`KeyReqContent` in knit-next's `Wire.kt`).
public struct KeyRequestContent: CBORRepresentable, Equatable {
    /// The node ids whose profiles are wanted.
    public var nodeIds: [String]

    /// Makes a key request.
    public init(nodeIds: [String]) {
        self.nodeIds = nodeIds
    }

    /// Reads a key request from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "KeyReqContent")
        nodeIds = try fields.required("nodeIds", .texts)
    }

    /// The request as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.texts("nodeIds", nodeIds)
        return writer.cbor
    }
}

/// An unsigned request for a blob by its content hash (`BlobReqContent` in knit-next's `Wire.kt`).
public struct BlobRequestContent: CBORRepresentable, Equatable {
    /// The blob's content hash, 64 lowercase hex characters.
    public var hash: String
    /// How many bytes of the blob the asker kept from a cut transfer, so a holder streams only the rest (knit-next ADR
    /// 2026-10.wtyc, `Wire.kt:300-304`). Omitted when `nil`, so a plain ask is the bytes every build has sent. This
    /// port reads it and never sends it: a holder here serves the whole file, the older holder's answer that knit-next's
    /// resume falls back on (knit-ios #2).
    public var offset: Int64?
    /// How many phones deep this ask may still pull the blob through, the receiver counted (knit-next ADR 2026-10.2drc,
    /// `Wire.kt:368-375`, ADR 2026-10.8hek). A receiver that lacks the blob wants it with one less and asks its own
    /// neighbours with that; asked with 0, it serves the blob if it holds it and makes no want. Absent reads as 1, a fetch
    /// only, which is what a build before the field sends. Read as a Kotlin `Int` and kept as a Swift `Int`, so one less
    /// than the smallest never wraps.
    public var pull: Int?
    /// Until when the asker's root pulls the blob through, epoch ms on the frame's own clock (a DM's `sentAt` plus
    /// custody's day): past it nobody pulls it through or wants it for someone else. `nil` for no deadline.
    public var until: Int64?

    /// Makes a blob request. A field left `nil` is left out, so a plain ask is the bytes it always was.
    public init(hash: String, offset: Int64? = nil, pull: Int? = nil, until: Int64? = nil) {
        self.hash = hash
        self.offset = offset
        self.pull = pull
        self.until = until
    }

    /// Reads a blob request from a decoded item. Android's `fastOnly` is not modelled and is skipped (knit-ios #8); a
    /// `pull` outside 32 bits refuses the request, as an out-of-range `ttl` or `ctl` does.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "BlobReqContent")
        hash = try fields.required("hash", .text)
        offset = try fields.nullable("offset", .int64)
        pull = try fields.nullable("pull", .int32)
        until = try fields.nullable("until", .int64)
    }

    /// The request as an item, in Kotlin's declaration order less the `fastOnly` it does not model.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("hash", hash)
        writer.long("offset", optional: offset)
        writer.int("pull", optional: pull)
        writer.long("until", optional: until)
        return writer.cbor
    }
}

/// A one-hop typing cue (`TypingContent` in knit-next's `Wire.kt`); a DM cue carries no group.
public struct TypingContent: CBORRepresentable, Equatable {
    /// The group being typed in, or `nil` for a DM or the room.
    public var groupId: String?

    /// Makes a typing cue.
    public init(groupId: String? = nil) {
        self.groupId = groupId
    }

    /// Reads a typing cue from a decoded item.
    public init(cbor: CBOR) throws(WireDecodingError) {
        let fields = try CBORFields(cbor, type: "TypingContent")
        groupId = try fields.nullable("groupId", .text)
    }

    /// The cue as an item.
    public var cbor: CBOR {
        var writer = CBORFieldWriter()
        writer.text("groupId", optional: groupId)
        return writer.cbor
    }
}
