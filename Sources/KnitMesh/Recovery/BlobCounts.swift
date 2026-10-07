/// What the blob holder query has done so far (`BlobExchange.BlobEvent` in knit-next, ADR 2026-10.6e5t there), and the
/// progress reports and withdrawals beside it (ADR 2026-10.nsr7 there), named as Android's debug bridge names them,
/// less its `blob` prefix.
public struct BlobCounts: Sendable, Equatable {
    /// Holder queries sent, one per frame.
    public var queriesSent: Int
    /// Holder queries answered.
    public var queriesAnswered: Int
    /// Holder queries left unanswered, their sender's budget spent.
    public var queriesRefused: Int
    /// Answers that named a blob we still wanted, from a neighbour queried for it this cycle.
    public var answersTaken: Int
    /// Answers that named nothing we still asked that neighbour about.
    public var answersIgnored: Int
    /// Asks of a holder that said it holds the blob.
    public var fetches: Int
    /// Holders queried again once their ask's grace ran out.
    public var confirms: Int
    /// Holders passed over for the next one.
    public var fallbacks: Int
    /// Rounds of asks of neighbours that cannot be queried: a first ask, or a widening.
    public var blindAsks: Int
    /// Neighbours that lack a blob asked to pull it through.
    public var pullThroughs: Int
    /// Progress reports sent back to the sender of a file streaming in.
    public var progressSent: Int
    /// Progress reports taken from the receiver of a file we feed.
    public var progressTaken: Int
    /// Asks of ours withdrawn from the neighbours they were on.
    public var cancelsSent: Int
    /// Withdrawals that took a copy queued for their asker off its link.
    public var cancelsTaken: Int

    /// Bundles the counts.
    public init(
        queriesSent: Int = 0,
        queriesAnswered: Int = 0,
        queriesRefused: Int = 0,
        answersTaken: Int = 0,
        answersIgnored: Int = 0,
        fetches: Int = 0,
        confirms: Int = 0,
        fallbacks: Int = 0,
        blindAsks: Int = 0,
        pullThroughs: Int = 0,
        progressSent: Int = 0,
        progressTaken: Int = 0,
        cancelsSent: Int = 0,
        cancelsTaken: Int = 0
    ) {
        self.queriesSent = queriesSent
        self.queriesAnswered = queriesAnswered
        self.queriesRefused = queriesRefused
        self.answersTaken = answersTaken
        self.answersIgnored = answersIgnored
        self.fetches = fetches
        self.confirms = confirms
        self.fallbacks = fallbacks
        self.blindAsks = blindAsks
        self.pullThroughs = pullThroughs
        self.progressSent = progressSent
        self.progressTaken = progressTaken
        self.cancelsSent = cancelsSent
        self.cancelsTaken = cancelsTaken
    }
}
