public import KnitWire

/// The status lines a group thread shows for an event (`StatusNotices.kt` in knit-next): "Alice left the chat".
///
/// Every field follows Android's convention. The id is fixed by the event, so a re-served frame updates the same row
/// rather than adding a second line. The sender is the event's subject, not an author. The clock comes off the frame,
/// so two phones order a thread alike. Only a kind, a subject and the one name live state cannot give are stored; the
/// words are the catalog's, so each phone shows the line in its own language.
public enum StatusNotices {
    /// `groupId` was created by `creator` at `createdAt` (`groupCreated`). The creator writes it at creation and
    /// every other member at first sight, so its id names no one and both paths land on one row.
    public static func groupCreated(_ groupId: String, by creator: NodeId, at createdAt: Int64) -> MessageRecord {
        notice(id: "created:\(groupId)", subject: creator, in: groupId, at: createdAt, kind: .groupCreated)
    }

    /// `member` left `groupId` by a frame stamped `leftAt` (`memberLeft`).
    public static func memberLeft(_ groupId: String, member: NodeId, at leftAt: Int64) -> MessageRecord {
        notice(id: "leave:\(groupId):\(member)", subject: member, in: groupId, at: leftAt, kind: .memberLeft)
    }

    /// `member`, who had left `groupId`, came back by a frame stamped `rejoinedAt` (`memberRejoined`).
    public static func memberRejoined(_ groupId: String, member: NodeId, at rejoinedAt: Int64) -> MessageRecord {
        notice(id: "rejoin:\(groupId):\(member)", subject: member, in: groupId, at: rejoinedAt, kind: .memberRejoined)
    }

    /// `renamer` renamed `groupId` to `name` by a frame stamped `sentAt` (`groupRenamed`). The new name is stored,
    /// because the old one is gone from live state once the rename applies.
    public static func groupRenamed(_ groupId: String, by renamer: NodeId, to name: String, at sentAt: Int64) -> MessageRecord {
        notice(id: "grename:\(groupId):\(sentAt)", subject: renamer, in: groupId, at: sentAt, kind: .groupRenamed, body: name)
    }

    private static func notice(
        id: String,
        subject: NodeId,
        in groupId: String,
        at sentAt: Int64,
        kind: MessageKind,
        body: String = ""
    ) -> MessageRecord {
        MessageRecord(id: id, senderId: subject, recipientId: nil, conversationId: groupId, body: body, sentAt: sentAt, kind: kind)
    }
}
