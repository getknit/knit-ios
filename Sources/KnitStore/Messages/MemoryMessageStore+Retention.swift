import KnitSync
import KnitWire

// Retention, apart from the class only to keep its file inside the lint's length.
extension MemoryMessageStore {
    /// The rows of threads `conversationIds` as retention weighs them (``MessageStore/retentionRows(in:)``).
    public func retentionRows(in conversationIds: Set<String>) -> [RetentionRow] {
        let threads = Set(conversationIds.map(ExactKey.init))
        return state.withLock { state in
            state.rows.values.map(\.record).filter { threads.contains(ExactKey($0.conversationId)) }.map { record in
                RetentionRow(
                    id: record.id,
                    conversationId: record.conversationId,
                    senderId: record.senderId,
                    sentAt: record.sentAt,
                    kind: record.kind
                )
            }
        }
    }

    /// Removes rows `ids` and tombstones those a carrier could still re-serve (``MessageStore/trimMessages(_:at:)``).
    @discardableResult
    public func trimMessages(_ ids: [String], at now: Int64) -> [MessageRecord] {
        state.withLock { state in
            ids.compactMap { id in
                let key = ExactKey(id)
                guard let record = state.rows.removeValue(forKey: key)?.record else {
                    return nil
                }
                let expiry = DeletedMessages.trimmedExpiry(
                    sentAt: record.sentAt, kind: record.kind, conversationId: record.conversationId, at: now)
                if let expiry {
                    let held = state.deleted[key]
                    state.deleted[key] = Deleted(id: id, expiresAt: max(held?.expiresAt ?? expiry, expiry), attachment: held?.attachment)
                }
                return record
            }
        }
    }
}
