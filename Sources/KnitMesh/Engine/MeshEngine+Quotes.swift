import KnitStore
import KnitWire

/// A received quote judged against the original it names (`data/QuoteVerifier.kt` and `InboundPipeline.persistQuoted` at
/// knit-next `7439fd9cc`, knit-next ADR 2026-10.gpa3). A `ReplyRef` is its sender's claim: an id anyone can mint, an
/// author, and words. So a quote is only as good as the original this phone holds. ``MessageReply/settlement(of:against:attachmentLabel:)``
/// rebuilds a matching quote from it, refuses one that names the wrong author or thread, and gives the reply the
/// original's own verdict on its words.
///
/// Originals routinely land after their replies, since custody serves newest first, so a quote is judged by whichever of
/// the two lands second: before the reply's insert when its original is already held (``quoteOnArrival(_:)``), else
/// after either row commits (``settleQuotes(after:)``). Each side reads only after its own insert has committed, so
/// whichever commits second sees the other, and the store writes a settlement once (``MessageStore/settleQuote(_:_:)``).
/// ``settleQuoteBacklog()`` is the net under both. Our own replies are never judged or rewritten: we quoted a row we held,
/// and a re-seal sends the stored quote again.
extension MeshEngine {
    /// Replies read and settled per query (`QuoteVerifier.BACKLOG_BATCH`, `QuoteVerifier.kt:102`).
    static let quoteBatch = 200

    /// The most batches one start spends on the backlog (`BACKLOG_MAX_BATCHES`, `:105`): 10,000 replies, far past any real
    /// history's. The next start takes the rest.
    static let quoteBacklogBatches = 50

    /// Someone else's newly delivered `record` with its quote judged, before it is stored (`quoteOnArrival`,
    /// `InboundPipeline.kt:3159-3173`): settled against its original when this phone holds it. Otherwise the sender's words
    /// are all the bubble can show, so they wait for the content filter, as a body's do; the app screens them in the
    /// same scope as the body (ADR 2026-10.e4kz). It reads the message store and nothing else, so it runs inside a store
    /// unit.
    func quoteOnArrival(_ record: MessageRecord) -> MessageRecord {
        guard let quote = record.replyTo else {
            return record
        }
        if let original = stores.messages.message(quote.messageId) {
            return record.settled(with: settlement(of: record, against: original))
        }
        var waiting = record
        waiting.quoteModeration = TextLimits.isBlank(quote.snippet) ? .clear : .waiting
        return waiting
    }

    /// Runs once a newly delivered `record` has committed (`QuoteVerifier.settleAfterInsert`, `QuoteVerifier.kt:44-68`):
    /// judges its quote if its original landed since ``quoteOnArrival(_:)`` looked, then settles every reply that was
    /// waiting on it as an original. A reply judged before its insert takes its original's verdict again, in case the
    /// original's screen landed between that judging and the insert. `record` is the row as it was inserted. Answers the
    /// row as stored now, or `nil` when it cannot be read.
    func settleQuotes(after record: MessageRecord) -> MessageRecord? {
        if let quote = record.replyTo, record.senderId != nodeId {
            if record.replyCheck == .unchecked, let original = stores.messages.message(quote.messageId) {
                stores.messages.settleQuote(record.id, settlement(of: record, against: original))
            } else if record.replyCheck == .verified {
                stores.messages.refreshQuoteModeration(record.id)
            }
        }
        settleReplies(to: record)
        return stores.messages.message(record.id)
    }

    /// Settles the replies held whose original is too, once per start, after our profile is seeded
    /// (`QuoteVerifier.settleBacklog`, `QuoteVerifier.kt:71-87`, called at `MeshManager.kt:1050`): those stored before
    /// schema v20, and those whose settle a stop cut short. Each batch is one store unit, as Kotlin wraps each in `transact`,
    /// so a start commits once per batch rather than once per reply. Each batch leaves the set it was read from, so the loop
    /// ends; a batch that writes nothing, or a unit that fails, which only a failing store gives, ends it too.
    func settleQuoteBacklog() {
        var batches = 0
        var full: Bool
        repeat {
            // The body answers how many more batches it calls for: one when this batch was full and settled any.
            let unit = stores.transactor.atomically { () -> Int? in
                let replies = stores.messages.unsettledQuotes(me: nodeId, limit: Self.quoteBatch)
                let settled = replies.filter { reply in
                    reply.replyTo.flatMap { stores.messages.message($0.messageId) }
                        .map { stores.messages.settleQuote(reply.id, settlement(of: reply, against: $0)) } == true
                }
                return replies.count == Self.quoteBatch && !settled.isEmpty ? 1 : 0
            }
            batches += 1
            full = unit == .committed(1)
        } while full && batches < Self.quoteBacklogBatches
    }

    /// Settles every reply waiting on `original` (`settleRepliesTo`, `QuoteVerifier.kt:89-96`), a batch at a time until none
    /// is left, or a batch writes nothing.
    private func settleReplies(to original: MessageRecord) {
        var full: Bool
        repeat {
            let waiting = stores.messages.repliesAwaiting(original.id, me: nodeId, limit: Self.quoteBatch)
            let settled = waiting.filter { stores.messages.settleQuote($0.id, settlement(of: $0, against: original)) }
            full = waiting.count == Self.quoteBatch && !settled.isEmpty
        } while full
    }

    /// What `reply`'s quote becomes against `original`, with the reader's labels.
    private func settlement(of reply: MessageRecord, against original: MessageRecord) -> QuoteSettlement {
        MessageReply.settlement(of: reply, against: original, attachmentLabel: configuration.quoteLabel)
    }
}
