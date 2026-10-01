public import KnitMesh
public import KnitStore
public import KnitWire

/// Every thread at once, as the list screens read it: each thread's newest message, the groups we are in, and which
/// threads are a stranger's message requests (`ConversationTable` in knit-next). One read per change, never a whole
/// thread.
public struct ThreadTable: Sendable {
    /// A thread waiting as a request: a stranger's DM, or a group nobody we know has written in.
    public struct Request: Sendable, Equatable {
        /// The thread's conversation id.
        public var id: String
        /// Its newest message, or `nil` for a group of nothing but status lines.
        public var head: MessageRecord?
        /// The group it is, if it is one.
        public var group: GroupRecord?

        /// When it last moved: its newest message, or a group's creation.
        public var lastActivity: Int64 { head?.sentAt ?? group?.createdAt ?? 0 }
    }

    /// Each thread's newest message, newest thread first.
    public let heads: [MessageRecord]
    /// The groups we are in, never one we left, by the bytes of their ids.
    public let groups: [GroupRecord]
    private let accepted: Set<String>
    private let authored: Set<String>
    private let verified: Set<NodeId>
    private let senders: [ExactKey: Set<NodeId>]

    /// The table over what `stores` hold, from `me`'s side.
    public init(stores: MeshStores, me: NodeId, verified: Set<NodeId>) {
        heads = stores.messages.threadHeads()
        groups = stores.groups.groups().filter { !$0.hasLeft }
        accepted = stores.conversations.acceptedConversations()
        authored = stores.messages.conversations(authoredBy: me)
        self.verified = verified
        senders = Dictionary(groups.map { (ExactKey($0.id), stores.messages.senders(in: $0.id)) }) { first, _ in first }
    }

    /// The group `id`, if we are in it.
    public func group(_ id: String) -> GroupRecord? {
        let key = ExactKey(id)
        return groups.first { ExactKey($0.id) == key }
    }

    /// Whether `conversationId` is a stranger's message request: the same predicate that keeps a request from
    /// notifying (``Conversations/isAccepted(_:accepted:verified:authored:groupSenders:)``). The room never is.
    public func isRequest(_ conversationId: String) -> Bool {
        let groupSenders = senders[ExactKey(conversationId)] ?? []
        return !Conversations.isAccepted(
            conversationId, accepted: accepted, verified: verified, authored: authored, groupSenders: groupSenders)
    }

    /// The requests, newest first: a stranger's DMs, and every group that waits, even one of nothing but status lines,
    /// as Android lists it (`ConversationTable.kt:23`).
    public var requests: [Request] {
        let directs = heads.filter { NodeId($0.conversationId) != nil && isRequest($0.conversationId) }
            .map { Request(id: $0.conversationId, head: $0, group: nil) }
        let waiting = groups.filter { isRequest($0.id) }.map { group in
            Request(id: group.id, head: heads.first { ExactKey($0.conversationId) == ExactKey(group.id) }, group: group)
        }
        // Newest first, a tie keeping the order the table read them in.
        return (directs + waiting).enumerated()
            .sorted { ($1.element.lastActivity, $0.offset) < ($0.element.lastActivity, $1.offset) }
            .map(\.element)
    }
}
