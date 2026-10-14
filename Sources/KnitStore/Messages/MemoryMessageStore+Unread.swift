import KnitSync
public import KnitWire

// Unread, apart from the class only to keep its file inside the lint's length.
extension MemoryMessageStore {
    /// Reads every message of `conversationId` (``MessageStore/markRead(in:)``).
    @discardableResult
    public func markRead(in conversationId: String) -> Bool {
        let thread = ExactKey(conversationId)
        return state.withLock { state in
            var changed = false
            for (key, row) in state.rows where row.unread && ExactKey(row.record.conversationId) == thread {
                state.rows[key]?.unread = false
                changed = true
            }
            return changed
        }
    }

    /// How many unread messages each thread holds (``MessageStore/unreadCounts(excludingSenders:)``).
    public func unreadCounts(excludingSenders blocked: Set<NodeId>) -> [ExactKey: Int] {
        state.withLock { state in
            var counts: [ExactKey: Int] = [:]
            for row in state.rows.values where row.unread && !blocked.contains(row.record.senderId) {
                counts[ExactKey(row.record.conversationId), default: 0] += 1
            }
            return counts
        }
    }
}
