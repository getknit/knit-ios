public import KnitStore
public import KnitWire

/// The people whose name clash never fades (`labelAnchors` in knit-next's `LabelAnchors.kt`, ADR 2026-10.k8ge there):
/// whoever a DM we accepted or wrote in is with, and every member of a group we have not left, accepted or not. The
/// caller adds the verified peers and ourselves. Only a stranger's clash fades: a contact that went quiet beside a fresh
/// namesake would otherwise read suffixed while the newcomer read plain, which is the look-alike's best case.
///
/// Wider than what makes a thread accepted (``Conversations/isAccepted(_:accepted:verified:authored:groupSenders:)``) on
/// purpose. An extra anchor only keeps a clash as it is today; a missing one is the dangerous case.
public enum LabelAnchors {
    /// The anchors among `accepted` and `authored`, conversation ids, of which a DM's is its peer's node id, and the
    /// members of every group in `groups` we have not left. A group's or the room's id anchors nobody, and neither does a
    /// member who left.
    public static func of(accepted: Set<String>, authored: Set<String>, groups: [GroupRecord]) -> Set<NodeId> {
        var anchors = Set(accepted.union(authored).lazy.filter { !Conversations.isGroup($0) }.compactMap(NodeId.init))
        for group in groups where !group.hasLeft {
            anchors.formUnion(group.members.lazy.compactMap(NodeId.init))
        }
        return anchors
    }
}
