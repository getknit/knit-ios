import KnitSync

/// The threads the user accepted (`SettingsStore.acceptedConversations` in knit-next): a stranger's first DM is a
/// message request until then.
public protocol ConversationStore: AnyObject, Sendable {
    /// Every accepted conversation id.
    func acceptedConversations() -> Set<String>

    /// Accepts `conversationId`.
    func accept(_ conversationId: String)
}

/// A ``ConversationStore`` in memory.
public final class MemoryConversationStore: ConversationStore {
    private let accepted = Lock<Set<String>>([])

    /// An empty store.
    public init() {
        // Nothing to set up.
    }

    public func acceptedConversations() -> Set<String> {
        accepted.withLock { $0 }
    }

    public func accept(_ conversationId: String) {
        accepted.withLock { _ = $0.insert(conversationId) }
    }
}
