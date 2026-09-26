public import KnitMesh
public import KnitStore
public import KnitWire

/// Every thread at once, as the list screens read it: each thread's newest message, and whether it is a stranger's
/// message request (`ConversationTable` in knit-next). One read per change, never a whole thread.
public struct ThreadTable: Sendable {
    /// Each thread's newest message, newest thread first.
    public let heads: [MessageRecord]
    private let accepted: Set<String>
    private let authored: Set<String>
    private let verified: Set<NodeId>

    /// The table over what `stores` hold, from `me`'s side.
    public init(stores: MeshStores, me: NodeId, verified: Set<NodeId>) {
        heads = stores.messages.threadHeads()
        accepted = stores.conversations.acceptedConversations()
        authored = stores.messages.conversations(authoredBy: me)
        self.verified = verified
    }

    /// Whether `conversationId` is a stranger's message request: the same predicate that keeps a request from
    /// notifying (``Conversations/isAccepted(_:accepted:verified:authored:)``). The room never is.
    public func isRequest(_ conversationId: String) -> Bool {
        !Conversations.isAccepted(conversationId, accepted: accepted, verified: verified, authored: authored)
    }

    /// The requests' newest messages, newest first.
    public var requests: [MessageRecord] {
        heads.filter { isRequest($0.conversationId) }
    }
}
