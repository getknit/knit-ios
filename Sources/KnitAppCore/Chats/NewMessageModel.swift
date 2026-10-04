import Foundation
import KnitMesh
import KnitStore
public import KnitWire
public import Observation

/// Someone New message can pick.
public struct Contact: Sendable, Equatable, Identifiable {
    /// Their node id.
    public var id: NodeId
    /// Their label.
    public var label: String
    /// Whether they are linked now.
    public var isLinked: Bool
    /// Whether the user verified them.
    public var isVerified: Bool
    /// Their face.
    public var face: Face
}

/// New message's view model (`ContactsViewModel` and `ContactUniverse` in knit-next): pick one of the people we know
/// for a DM, or 2 to 7 of them for a group (`ContactsScreen.kt:142`).
@preconcurrency
@MainActor
@Observable
public final class NewMessageModel {
    /// The most others a group holds: eight with us (`MAX_OTHER_MEMBERS`).
    public static let maxOthers = GroupInfo.maxMembers - 1

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private var cache = Cached<PickerKey, [Contact]>()
    /// The rows' order since the picker first drew them, which holds while it is open.
    @ObservationIgnored private var order: [NodeId] = []
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
    /// (`ContactUniverse.kt:21-40`). The first read puts linked people first, then everyone by name. After that the
    /// order holds while the picker is open, though each row's marks stay current: Android re-sorts as people link,
    /// which moves a row under a finger reaching for it.
    public var candidates: [Contact] {
        let linked = Set(session.neighbors.map(\.nodeId))
        return cache.value(for: PickerKey(revision: session.revision, linked: linked)) { holdingOrder(build(linked: linked)) }
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

    /// Whether Start chat would open a thread.
    public var canStart: Bool {
        !picked.isEmpty
    }

    /// The thread to open: one pick's DM, whose id is their node id, or the group the picks make, which is the one
    /// they already share if there is one. A DM is not accepted here, as Android's `onPickSingle` and the profile's
    /// Message leave it. Answers `nil` for no pick, or a group the mesh refuses.
    public func start() async -> String? {
        guard let first = picked.first else {
            return nil
        }
        guard picked.count > 1 else {
            return first.string
        }
        return await session.createGroup(with: picked)?.id
    }

    /// `fresh` in the order the rows already have, with anyone new after them in `fresh`'s order. Anyone gone drops
    /// out, and joins the end if they come back.
    private func holdingOrder(_ fresh: [Contact]) -> [Contact] {
        let byId = Dictionary(fresh.map { ($0.id, $0) }) { first, _ in first }
        let known = Set(order)
        let arranged = order.compactMap { byId[$0] } + fresh.filter { !known.contains($0.id) }
        order = arranged.map(\.id)
        return arranged
    }

    private func build(linked: Set<NodeId>) -> [Contact] {
        let me = session.identity.nodeId
        let directory = session.directory
        let threads = session.threads()
        var people = threads.heads.compactMap { NodeId($0.conversationId) }.filter { !threads.isRequest($0.string) }
        people += session.stores.conversations.acceptedConversations().compactMap(NodeId.init)
        for group in threads.groups where !threads.isRequest(group.id) {
            people += group.members.compactMap(NodeId.init)
        }
        people += directory.verified
        // Blocked people are nobody's contacts (`ContactUniverse.kt:75`), until they are unblocked.
        var seen: Set<NodeId> = directory.blocked.union([me])
        let found = people.filter { seen.insert($0).inserted }.map { peer in
            Contact(
                id: peer,
                label: directory.label(for: peer).text,
                isLinked: linked.contains(peer),
                isVerified: directory.verified.contains(peer),
                face: directory.face(for: peer)
            )
        }
        return found.sorted { first, second in
            if first.isLinked != second.isLinked {
                return first.isLinked
            }
            let byName = first.label.localizedCaseInsensitiveCompare(second.label)
            return byName == .orderedSame ? first.id < second.id : byName == .orderedAscending
        }
    }
}
