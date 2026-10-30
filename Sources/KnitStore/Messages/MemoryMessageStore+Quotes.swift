import KnitSync
public import KnitWire

// A reply's quote checked against its original (knit-next ADR 2026-10.gpa3), apart so the store stays inside the lint's
// length.
extension MemoryMessageStore {
    /// Records the filter's verdict on reply `id`'s unchecked quote (``MessageStore/setQuoteModeration(_:to:)``).
    @discardableResult
    public func setQuoteModeration(_ id: String, to moderation: MessageModeration) -> Bool {
        state.withLock { state in
            let key = ExactKey(id)
            guard let row = state.rows[key], row.record.quoteAwaitsScreening, moderation != .waiting else {
                return false
            }
            state.rows[key]?.record.quoteModeration = moderation
            return true
        }
    }

    /// Writes reply `id`'s settled quote, once (``MessageStore/settleQuote(_:_:)``).
    @discardableResult
    public func settleQuote(_ id: String, _ settlement: QuoteSettlement) -> Bool {
        state.withLock { state in
            let key = ExactKey(id)
            guard let row = state.rows[key], let quote = row.record.replyTo, row.record.replyCheck == .unchecked else {
                return false
            }
            var settlement = settlement
            if settlement.check == .verified {
                settlement.moderation = state.rows[ExactKey(quote.messageId)]?.record.moderation.ofQuote ?? settlement.moderation
            }
            state.rows[key]?.record = row.record.settled(with: settlement)
            return true
        }
    }

    /// Gives verified reply `id` its original's verdict (``MessageStore/refreshQuoteModeration(_:)``).
    @discardableResult
    public func refreshQuoteModeration(_ id: String) -> Bool {
        state.withLock { state in
            let key = ExactKey(id)
            guard let row = state.rows[key], let quote = row.record.replyTo, row.record.replyCheck == .verified,
                row.record.quoteModeration == .waiting,
                let verdict = state.rows[ExactKey(quote.messageId)]?.record.moderation.ofQuote, verdict != .waiting
            else {
                return false
            }
            state.rows[key]?.record.quoteModeration = verdict
            return true
        }
    }

    /// The unchecked replies quoting `originalId` (``MessageStore/repliesAwaiting(_:me:limit:)``).
    public func repliesAwaiting(_ originalId: String, me: NodeId, limit: Int) -> [MessageRecord] {
        let original = ExactKey(originalId)
        return state.withLock { state in
            state.rows.values.filter { row in
                row.record.replyCheck == .unchecked && row.record.senderId != me
                    && row.record.replyTo.map { ExactKey($0.messageId) == original } == true
            }.sorted { $0.order < $1.order }.prefix(limit).map(\.record)
        }
    }

    /// The start's backlog (``MessageStore/unsettledQuotes(me:limit:)``).
    public func unsettledQuotes(me: NodeId, limit: Int) -> [MessageRecord] {
        state.withLock { state in
            state.rows.values.filter { row in
                row.record.replyCheck == .unchecked && row.record.senderId != me
                    && row.record.replyTo.map { state.rows[ExactKey($0.messageId)] != nil } == true
            }.sorted { $0.order < $1.order }.prefix(limit).map(\.record)
        }
    }
}

extension MemoryMessageStore.State {
    /// Gives every reply whose quote of the row `original` was verified `verdict`, that row's as a quote carries it: the
    /// second half of ``MemoryMessageStore/setModeration(_:to:)``, under the same lock.
    mutating func passQuoteModeration(_ verdict: MessageModeration, of original: ExactKey) {
        for (key, row) in rows
        where row.record.replyCheck == .verified && row.record.replyTo.map({ ExactKey($0.messageId) == original }) == true {
            rows[key]?.record.quoteModeration = verdict
        }
    }
}
