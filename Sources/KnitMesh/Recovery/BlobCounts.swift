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
    /// Withdrawals that took a copy queued for their asker off its link, or its parked ask off the book.
    public var cancelsTaken: Int
    /// Asks parked behind another copy's feed of the same blob (`blobAsksParked`, knit-next ADR 2026-10.g24x).
    public var asksParked: Int
    /// Asks for a blob we lack that made no want here, allowing no budget or past their deadline (`blobEchoesDeclined`,
    /// knit-next ADR 2026-10.2drc), and, this port's alone, past the echo budget or a want set full of our own
    /// (knit-ios #20).
    public var echoesDeclined: Int
    /// Cycles that would have asked their NONE neighbours to pull a blob through and asked nobody, the want past its
    /// deadline or with no budget left (`blobPullsWithheld`).
    public var pullsWithheld: Int
    /// Files spliced onto a prefix we kept that failed their hash, so the prefix went and the blob was asked for from byte
    /// 0 (`onSpliceRefused`, knit-ios #2). Anything but 0 is a holder or a prefix that was wrong.
    public var splicesRefused: Int
    /// Steps of an echo, a want made for an asker, that asked nobody because the echo budget was spent, once a cycle
    /// (knit-ios #20). This port's alone.
    public var echoFetchesHeld: Int
    /// Whole files refused on landing because they were fetched for an asker alone and the echo budget had no room for
    /// them (knit-ios #20).
    public var echoFilesRefused: Int
    /// Asks for a held blob not queued because ``BlobExchange/maxWaitingServes`` files already wait on the asker's link
    /// (knit-ios #20). The asker asks again at its floor.
    public var servesRefused: Int
    /// Holders whose copy of a blob wanted only as a profile photo streamed past the photo's ceiling or claimed a size over
    /// it, each passed over for that blob this session, or the blob refused when the holder was its author (ADR
    /// 2026-10.r88m).
    public var photosOverCeiling: Int

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
        cancelsTaken: Int = 0,
        asksParked: Int = 0,
        echoesDeclined: Int = 0,
        pullsWithheld: Int = 0,
        splicesRefused: Int = 0,
        echoFetchesHeld: Int = 0,
        echoFilesRefused: Int = 0,
        servesRefused: Int = 0,
        photosOverCeiling: Int = 0
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
        self.asksParked = asksParked
        self.echoesDeclined = echoesDeclined
        self.pullsWithheld = pullsWithheld
        self.splicesRefused = splicesRefused
        self.echoFetchesHeld = echoFetchesHeld
        self.echoFilesRefused = echoFilesRefused
        self.servesRefused = servesRefused
        self.photosOverCeiling = photosOverCeiling
    }
}
