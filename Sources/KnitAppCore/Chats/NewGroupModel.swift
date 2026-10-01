import Foundation
import KnitMesh
import KnitStore
public import KnitWire
public import Observation

/// Someone a new group can take.
public struct GroupCandidate: Sendable, Equatable, Identifiable {
    /// Their node id.
    public var id: NodeId
    /// Their label.
    public var label: String
    /// Whether they are linked now.
    public var isLinked: Bool
    /// Whether the user verified them.
    public var isVerified: Bool
}

/// The new-group picker's view model (`ContactsViewModel` and `ContactUniverse` in knit-next): pick 2 to 7 of the
/// people we know, and start a group with them.
@preconcurrency
@MainActor
@Observable
public final class NewGroupModel {
    /// The most others a group holds: eight with us (`MAX_OTHER_MEMBERS`).
    public static let maxOthers = GroupInfo.maxMembers - 1
    /// The fewest others a group starts with from here; one other is a DM (`ContactsScreen.kt:142`).
    public static let minOthers = 2

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private var cache = Cached<PickerKey, [GroupCandidate]>()
    /// Who is picked, in the order they were picked, which becomes the roster's order.
    public private(set) var picked: [NodeId] = []
    /// Whether the last pick was refused for the cap, so the picker can say why.
    public private(set) var isFull = false

    private struct PickerKey: Equatable {
        var revision: Int
        var linked: Set<NodeId>
    }

    /// The picker over `session`.
    public init(session: AppSession) {
        self.session = session
    }

    /// Who can be picked: people with an accepted DM, members of accepted groups, and verified peers, never us
    /// (`ContactUniverse.kt:21-40`). Linked people come first, then everyone by name.
    public var candidates: [GroupCandidate] {
        let linked = Set(session.neighbors.map(\.nodeId))
        return cache.value(for: PickerKey(revision: session.revision, linked: linked)) { build(linked: linked) }
    }

    /// Whether `id` is picked.
    public func isPicked(_ id: NodeId) -> Bool {
        picked.contains(id)
    }

    /// Picks `id`, or puts them back. A pick past the cap is refused, and says so.
    public func toggle(_ id: NodeId) {
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
            isFull = false
        } else if picked.count < Self.maxOthers {
            picked.append(id)
        } else {
            isFull = true
        }
    }

    /// Whether Start group would start one.
    public var canCreate: Bool {
        picked.count >= Self.minOthers
    }

    /// Starts the group, or opens the one these people already share. Answers its id, for the thread to open.
    public func create() async -> String? {
        guard canCreate else {
            return nil
        }
        return await session.createGroup(with: picked)?.id
    }

    private func build(linked: Set<NodeId>) -> [GroupCandidate] {
        let me = session.identity.nodeId
        let directory = session.directory
        let threads = session.threads()
        var people = threads.heads.compactMap { NodeId($0.conversationId) }.filter { !threads.isRequest($0.string) }
        people += session.stores.conversations.acceptedConversations().compactMap(NodeId.init)
        for group in threads.groups where !threads.isRequest(group.id) {
            people += group.members.compactMap(NodeId.init)
        }
        people += directory.verified
        var seen: Set<NodeId> = [me]
        let found = people.filter { seen.insert($0).inserted }.map { peer in
            GroupCandidate(
                id: peer,
                label: directory.label(for: peer).text,
                isLinked: linked.contains(peer),
                isVerified: directory.verified.contains(peer)
            )
        }
        return found.sorted { first, second in
            if first.isLinked != second.isLinked {
                return first.isLinked
            }
            let order = first.label.localizedCaseInsensitiveCompare(second.label)
            return order == .orderedSame ? first.id < second.id : order == .orderedAscending
        }
    }
}
