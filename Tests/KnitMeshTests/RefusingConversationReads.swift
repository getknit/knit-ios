import KnitStore
import KnitSync

/// A conversation store whose read of the accepted threads can fail, as a database that cannot read its file fails it:
/// told to, ``acceptedConversations()`` fails the store unit it runs in and answers none, the store's fallback, and an
/// accept goes to the store it wraps. `refuse` is how the unit fails, as ``RefusingMessageStore``'s is (``StoreKind``).
/// Outside a unit only the fallback is left, which reads as no thread accepted, so a sweep reads it inside its unit
/// (knit-ios #21).
final class RefusingConversationReads: ConversationStore {
    let held: any ConversationStore
    private let refuse: @Sendable () -> Void
    private let failing = Lock(false)

    init(_ held: any ConversationStore, refuse: @escaping @Sendable () -> Void) {
        self.held = held
        self.refuse = refuse
    }

    /// Whether a read of the accepted threads fails now.
    var failsReads: Bool {
        get { failing.withLock { $0 } }
        set { failing.withLock { $0 = newValue } }
    }

    func acceptedConversations() -> Set<String> {
        guard failsReads else {
            return held.acceptedConversations()
        }
        refuse()
        return []
    }

    func accept(_ conversationId: String) { held.accept(conversationId) }
}
