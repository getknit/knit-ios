import Foundation
import KnitMesh
import KnitStore
public import KnitWire
public import Observation

/// One member as group info lists them.
public struct GroupMemberRow: Sendable, Equatable, Identifiable {
    /// The member's node id, as the roster spells it.
    public var id: String
    /// Their label, or "You".
    public var label: String
    /// Whether this is us.
    public var isMe: Bool
    /// The profile a tap opens: `nil` for us, and for an id that is no node id.
    public var peer: NodeId?
    /// Whether they are linked now.
    public var isLinked: Bool
    /// Whether the user verified them.
    public var isVerified: Bool
}

/// Group info, as one value.
public struct GroupInfoState: Sendable, Equatable {
    /// The group's title.
    public var title: String
    /// How many people are in it, us included.
    public var memberCount: Int
    /// The members: us first, then those linked now, then the rest by name (`GroupDetailsViewModel.kt:125-131`).
    public var members: [GroupMemberRow]
    /// Whether the group is still ours: `false` once we left it, when its screens close.
    public var exists: Bool
}

/// Group info's view model: the members, renaming and leaving (`GroupDetailsViewModel` in knit-next, less the photo).
@preconcurrency
@MainActor
@Observable
public final class GroupInfoModel {
    /// The group's id.
    public let groupId: String
    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private var cache = Cached<InfoKey, GroupInfoState>()
    private var name = ""

    private struct InfoKey: Equatable {
        var revision: Int
        var linked: Set<NodeId>
    }

    /// Group `groupId`'s info over `session`.
    public init(groupId: String, session: AppSession) {
        self.groupId = groupId
        self.session = session
    }

    /// The group, rebuilt only when something changed.
    public var state: GroupInfoState {
        let linked = Set(session.neighbors.map(\.nodeId))
        return cache.value(for: InfoKey(revision: session.revision, linked: linked)) { build(linked: linked) }
    }

    /// What the rename field holds, cut at the name limit as it is typed.
    public var draftName: String {
        get { name }
        set { name = TextLimits.truncated(newValue, toUTF16: TextLimits.groupName) }
    }

    /// Whether Rename would rename: a name that is blank once normalized is no name.
    public var canRename: Bool {
        TextLimits.outgoingGroupName(name) != nil
    }

    /// Starts a rename from the group's title, as Android's dialog does.
    public func beginRename() {
        draftName = state.title
    }

    /// Renames the group, and tells its members. Answers whether it did.
    @discardableResult
    public func rename() async -> Bool {
        await session.renameGroup(groupId, to: name) != nil
    }

    /// Leaves the group: its members hear of it, and its thread goes.
    public func leave() async {
        await session.leaveGroup(groupId)
    }

    private func build(linked: Set<NodeId>) -> GroupInfoState {
        let me = session.identity.nodeId
        let directory = session.directory
        guard let group = session.threads().group(groupId) else {
            return GroupInfoState(title: Copy.Groups.unnamed, memberCount: 0, members: [], exists: false)
        }
        let rows = group.members.map { id in
            let isMe = ExactKey(id) == ExactKey(me.string)
            let peer = isMe ? nil : NodeId(id)
            return GroupMemberRow(
                id: id,
                label: isMe ? Copy.Common.you : directory.labels.label(for: id).text,
                isMe: isMe,
                peer: peer,
                isLinked: peer.map(linked.contains) ?? false,
                isVerified: peer.map(directory.verified.contains) ?? false
            )
        }
        let ordered = rows.sorted { first, second in
            if first.isMe != second.isMe {
                return first.isMe
            }
            if first.isLinked != second.isLinked {
                return first.isLinked
            }
            let order = first.label.localizedCaseInsensitiveCompare(second.label)
            return order == .orderedSame ? first.id.utf8.lexicographicallyPrecedes(second.id.utf8) : order == .orderedAscending
        }
        return GroupInfoState(
            title: GroupNaming.title(of: group, me: me, directory: directory),
            memberCount: rows.count,
            members: ordered,
            exists: true
        )
    }
}
