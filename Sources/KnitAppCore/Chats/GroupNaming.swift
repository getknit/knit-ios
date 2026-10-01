public import KnitStore
public import KnitWire

/// How a group is titled and how its status lines read (`GroupNaming.kt` and `statusNoticeText` in knit-next).
public enum GroupNaming {
    /// A group's title: its name, or else the other members' labels in roster order, "Sam, Priya & Theo", or else
    /// "Group". Each phone titles an unnamed group from its own side, leaving itself out.
    public static func title(of group: GroupRecord, me: NodeId, directory: Directory) -> String {
        if !TextLimits.isBlank(group.name) {
            return group.name
        }
        let others = group.members.filter { ExactKey($0) != ExactKey(me.string) }.map { directory.labels.label(for: $0).text }
        return Copy.Groups.names(others) ?? Copy.Groups.unnamed
    }

    /// Who started `group`, as a request names them: its creator when that is someone else on its roster, else the
    /// first other member.
    public static func starter(of group: GroupRecord, me: NodeId, directory: Directory) -> String {
        let others = group.roster.map(\.nodeId).filter { ExactKey($0) != ExactKey(me.string) }
        let creator = others.first { ExactKey($0) == ExactKey(group.createdBy) } ?? others.first
        return creator.map { directory.labels.label(for: $0).text } ?? Copy.Groups.unnamed
    }

    /// The words of a status line, or `nil` for a kind this build has none for, which a thread leaves out.
    public static func notice(_ message: MessageRecord, me: NodeId, directory: Directory) -> String? {
        let subject = message.senderId == me ? Copy.Common.you : directory.label(for: message.senderId).text
        switch message.kind {
        case .groupCreated:
            return message.senderId == me ? Copy.Groups.createdByYou : Copy.Groups.created(by: subject)
        case .memberLeft:
            return Copy.Groups.left(subject)
        case .memberRejoined:
            return Copy.Groups.rejoined(subject)
        case .groupRenamed:
            return Copy.Groups.renamed(by: subject, to: message.body)
        default:
            return nil
        }
    }
}
