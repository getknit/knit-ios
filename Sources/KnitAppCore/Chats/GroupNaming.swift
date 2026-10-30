public import KnitStore
public import KnitWire

/// How a group is titled and how its status lines read (`GroupNaming.kt` and `statusNoticeText` in knit-next).
public enum GroupNaming {
    /// A group's title: its name, or else the other members' labels in roster order, "Sam, Priya & Theo", or else
    /// "Group". Each phone titles an unnamed group from its own side, leaving itself out. The name is cleaned here, at
    /// display, and kept raw in the store, because the frames we send carry it (knit-next #228). A cleaned name whose
    /// ``NameKey`` is empty, such as U+3164 or a run of controls alone, titles the group as an unnamed one, though it is
    /// still a name on the wire (contract revision 2).
    public static func title(of group: GroupRecord, me: NodeId, directory: Directory) -> String {
        shown(group.name) ?? membersTitle(of: group, me: me, directory: directory)
    }

    /// An unnamed group's title, from the other members' labels.
    private static func membersTitle(of group: GroupRecord, me: NodeId, directory: Directory) -> String {
        let others = group.members.filter { ExactKey($0) != ExactKey(me.string) }.map { directory.labels.label(for: $0).text }
        return Copy.Groups.names(others) ?? Copy.Groups.unnamed
    }

    /// A received group name as a person reads it, one line with no controls and at most ``TextLimits/groupName`` units,
    /// or `nil` when that is display-blank (``NameKey/isBlankName(_:)``).
    private static func shown(_ name: String) -> String? {
        let cleaned = TextLimits.cleanReceived(name, limit: TextLimits.groupName)
        return NameKey.isBlankName(cleaned) ? nil : cleaned
    }

    /// Who started `group`, as a request names them: its creator when that is someone else on its roster, else the
    /// first other member.
    public static func starter(of group: GroupRecord, me: NodeId, directory: Directory) -> String {
        let others = group.roster.map(\.nodeId).filter { ExactKey($0) != ExactKey(me.string) }
        let creator = others.first { ExactKey($0) == ExactKey(group.createdBy) } ?? others.first
        return creator.map { directory.labels.label(for: $0).text } ?? Copy.Groups.unnamed
    }

    /// A status line's row in `group`'s thread, or `nil` for a kind this build has no words for.
    static func row(of message: MessageRecord, in group: GroupRecord?, me: NodeId, directory: Directory) -> ChatMessage? {
        notice(message, in: group, me: me, directory: directory).map { words in
            ChatMessage(id: message.id, body: "", sentAt: message.sentAt, isMine: false, author: message.senderId, notice: words)
        }
    }

    /// The words of a status line in `group`'s thread, or `nil` for a kind this build has none for, which a thread leaves
    /// out. A rename to a display-blank name reads as the title an unnamed `group` takes.
    public static func notice(_ message: MessageRecord, in group: GroupRecord?, me: NodeId, directory: Directory) -> String? {
        let subject = message.senderId == me ? Copy.Common.you : directory.label(for: message.senderId).text
        switch message.kind {
        case .groupCreated:
            return message.senderId == me ? Copy.Groups.createdByYou : Copy.Groups.created(by: subject)
        case .memberLeft:
            return Copy.Groups.left(subject)
        case .memberRejoined:
            return Copy.Groups.rejoined(subject)
        case .groupRenamed:
            let unnamed = group.map { membersTitle(of: $0, me: me, directory: directory) } ?? Copy.Groups.unnamed
            return Copy.Groups.renamed(by: subject, to: shown(message.body) ?? unnamed)
        default:
            return nil
        }
    }
}
