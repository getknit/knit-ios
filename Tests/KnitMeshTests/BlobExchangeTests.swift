import KnitWire
import Testing

@testable import KnitMesh

/// The blob exchange's books, ported from knit-next's `BlobExchangeTest` and `BlobHolderQueryTest`: a blob is wanted
/// once, the wants, the serve memo and the queries are bounded and age out, an answer is budgeted, and timers due
/// together step together.
@Suite struct BlobExchangeTests {
    private let alice = TestPeer(seed: 1).nodeId
    private let bob = TestPeer(seed: 2).nodeId

    private func hash(_ index: Int) -> BlobHash {
        BlobHash(digest: (0..<32).map { UInt8(truncatingIfNeeded: index >> ($0 % 4 * 8)) }) ?? .empty
    }

    private func want(_ exchange: inout BlobExchange, _ index: Int, now: Int64) {
        _ = exchange.recordWant(hash(index), now: now, author: nil, via: nil, asker: nil)
    }

    @Test func aBlobIsWantedOnceAndARefreshKeepsItsPlaceAndItsFirstHints() {
        var exchange = BlobExchange(queriesHolders: false)
        _ = exchange.recordWant(hash(1), now: 0, author: alice, via: nil, asker: nil)
        want(&exchange, 2, now: 0)
        _ = exchange.recordWant(hash(1), now: 5, author: bob, via: bob, asker: nil)
        #expect(exchange.wanted == [hash(1), hash(2)], "a refresh keeps the order it was first wanted in")
        #expect(exchange.wants[hash(1)]?.author == alice, "the first want to name an author wins")
        #expect(exchange.wants[hash(1)]?.via == bob, "a hint the want lacked is filled in")
        #expect(exchange.wants[hash(1)]?.wantedAt == 5)
        exchange.forget(hash(1))
        #expect(exchange.wanted == [hash(2)])
        #expect(!exchange.isWanted(hash(1)))
    }

    @Test func theOldestWantGoesWhenTheSetIsFull() {
        var exchange = BlobExchange(queriesHolders: false)
        for index in 0...BlobExchange.maxWanted {
            want(&exchange, index, now: Int64(index))
        }
        #expect(exchange.wanted.count == BlobExchange.maxWanted)
        #expect(exchange.wants.count == BlobExchange.maxWanted)
        #expect(!exchange.isWanted(hash(0)))
        #expect(exchange.isWanted(hash(BlobExchange.maxWanted)))
    }

    @Test func aWantNobodyRefreshedAgesOut() {
        var exchange = BlobExchange(queriesHolders: false)
        want(&exchange, 1, now: 0)
        want(&exchange, 2, now: 0)
        want(&exchange, 2, now: 600_000)
        let early = exchange.sweep(now: BlobExchange.wantMilliseconds)
        let late = exchange.sweep(now: BlobExchange.wantMilliseconds + 1)
        #expect(early == 0, "only past the TTL")
        #expect(late == 1)
        #expect(exchange.wanted == [hash(2)])
    }

    @Test func aServeHoldsOffASecondCopyToThatNeighbourForTheMemo() {
        var exchange = BlobExchange(queriesHolders: false)
        let first = exchange.shouldServe(hash(1), to: bob, now: 0)
        let inside = exchange.shouldServe(hash(1), to: bob, now: BlobExchange.serveMemoMilliseconds - 1)
        let otherPeer = exchange.shouldServe(hash(1), to: alice, now: 1)
        let otherBlob = exchange.shouldServe(hash(2), to: bob, now: 1)
        let after = exchange.shouldServe(hash(1), to: bob, now: BlobExchange.serveMemoMilliseconds)
        #expect(first)
        #expect(!inside)
        #expect(otherPeer, "another neighbour is another serve")
        #expect(otherBlob, "another blob is another serve")
        #expect(after, "the memo is shorter than the 60 s re-ask")
    }

    @Test func aServeThatNeverWentOutIsForgotten() {
        var exchange = BlobExchange(queriesHolders: false)
        let first = exchange.shouldServe(hash(1), to: bob, now: 0)
        exchange.forgetServe(hash(1), to: bob)
        let again = exchange.shouldServe(hash(1), to: bob, now: 1)
        #expect(first && again)
    }

    @Test func theServeMemoIsBounded() {
        var exchange = BlobExchange(queriesHolders: false)
        for index in 0...BlobExchange.maxServeMemo {
            _ = exchange.shouldServe(hash(index), to: bob, now: 0)
        }
        #expect(exchange.servedCount == BlobExchange.maxServeMemo)
        let oldest = exchange.shouldServe(hash(0), to: bob, now: 0)
        #expect(oldest, "the oldest serve was forgotten")
    }

    @Test func aQueryPeeksAtTheMemoWithoutStampingIt() {
        var exchange = BlobExchange(queriesHolders: false)
        #expect(!exchange.memoHolds(hash(1), for: bob, now: 0))
        #expect(!exchange.memoHolds(hash(1), for: bob, now: 0), "a peek stamps nothing")
        _ = exchange.shouldServe(hash(1), to: bob, now: 0)
        #expect(exchange.memoHolds(hash(1), for: bob, now: BlobExchange.serveMemoMilliseconds - 1))
        #expect(!exchange.memoHolds(hash(1), for: alice, now: 1))
        #expect(!exchange.memoHolds(hash(1), for: bob, now: BlobExchange.serveMemoMilliseconds))
    }

    @Test func aHashNotWantedGetsAnEmptyPlan() {
        var exchange = BlobExchange(queriesHolders: true)
        let plan = exchange.decide(hash(9), among: [BlobExchange.Candidate(id: bob, streaming: false, capable: true)], now: 0)
        #expect(plan.query.isEmpty && plan.asks.isEmpty && plan.wake == nil)
        #expect(exchange.takeQueries().isEmpty)
    }

    @Test func aStateAndAnAnswerReadInTheLogAsAndroidWritesThem() {
        #expect(BlobExchange.label(BlobHolding.partial) == "state 4")
        #expect(BlobExchange.label(BlobHasItem(hash: "0123456789", state: .have, size: 7)) == "01234567 HAVE 7B")
        #expect(BlobExchange.label(BlobHasItem(hash: "0123456789", state: .notHeld)) == "01234567 NONE")
    }

    @Test func aNeighbourDroppedFromTheBudgetsComesBackWithAFullOne() {
        var exchange = BlobExchange(queriesHolders: false)
        for _ in 0..<16 {
            _ = exchange.admitQuery(from: bob, now: 0)
        }
        let spent = exchange.admitQuery(from: bob, now: 0)
        for seed in 10..<(10 + AnswerBudget.maxPeers) {
            _ = exchange.admitQuery(from: TestPeer(seed: seed).nodeId, now: 0)
        }
        let forgotten = exchange.admitQuery(from: bob, now: 0)
        #expect(!spent && forgotten, "at most 64 neighbours are remembered, the least recently heard dropped first")
    }

    @Test func eachNeighbourGetsSixteenAnswersInABurstThenOneASecond() {
        // `BlobHolderQueryTest`'s budget: an unsigned flood of queries costs the holder at most this.
        var exchange = BlobExchange(queriesHolders: false)
        let burst = (0..<16).map { _ in exchange.admitQuery(from: bob, now: 0) }
        let spent = exchange.admitQuery(from: bob, now: 0)
        let other = exchange.admitQuery(from: alice, now: 0)
        let refilled = exchange.admitQuery(from: bob, now: 1000)
        let againSpent = exchange.admitQuery(from: bob, now: 1000)
        let allAdmitted = burst.allSatisfy(\.self)
        #expect(allAdmitted)
        #expect(!spent, "the seventeenth in a burst is refused")
        #expect(other, "each neighbour has a budget of its own")
        #expect(refilled && !againSpent, "one more a second")
    }

    @Test func aQueryIsAnsweredForItsFirstThirtyTwoDistinctHashesOfASaneLength() {
        let long = String(repeating: "a", count: BlobExchange.maxHashCharacters + 1)
        let named = ["", "x", "x", long] + (0..<40).map { "h\($0)" }
        let asked = BlobExchange.answerable(named)
        #expect(asked.count == BlobExchange.maxQueryHashes)
        #expect(asked.first == "x" && !asked.contains("") && !asked.contains(long))
        #expect(asked.last == "h30", "the rest are ignored, not refused")
    }

    @Test func timersDueWithinASecondStepTogetherAndTheEarliestWins() {
        var exchange = BlobExchange(queriesHolders: false)
        for index in 1...4 {
            want(&exchange, index, now: 0)
        }
        exchange.arm(hash(1), at: 5000)
        exchange.arm(hash(1), at: 9000)
        exchange.arm(hash(2), at: 5900)
        exchange.arm(hash(3), at: 6001)
        #expect(exchange.nextDeadline == 5000, "a later wake never pushes an earlier one back")
        #expect(exchange.takeDue(now: 4999).isEmpty)
        #expect(exchange.takeDue(now: 5000) == [hash(1), hash(2)])
        #expect(exchange.nextDeadline == 6001, "each due want is disarmed, so it is stepped once")
    }

    @Test func aSentQueryIsForgottenACycleOnAndTheOldestGoFirst() {
        var exchange = BlobExchange(queriesHolders: false)
        exchange.noteQuerySent("q-old", to: bob, hashes: [hash(1)], now: 0)
        exchange.noteQuerySent("q-new", to: bob, hashes: [hash(1)], now: BlobExchange.cycleMilliseconds)
        #expect(exchange.sentQueries[ExactKey("q-old")] == nil)
        for index in 0...BlobExchange.maxSentQueries {
            exchange.noteQuerySent("q\(index)", to: bob, hashes: [], now: BlobExchange.cycleMilliseconds)
        }
        #expect(exchange.sentQueries.count == BlobExchange.maxSentQueries)
        #expect(exchange.sentQueries[ExactKey("q-new")] == nil)
        #expect(exchange.counts.queriesSent == BlobExchange.maxSentQueries + 3)
    }

    @Test func queriesGoOneFramePerNeighbourAtMostThirtyTwoHashesEach() {
        // `BlobHolderQueryTest`: forty hashes owed one neighbour go as 32 and 8, and two wants share a frame.
        var exchange = BlobExchange(queriesHolders: true)
        for index in 0..<40 {
            exchange.queue(hash(index), for: [bob, alice])
        }
        exchange.queue(hash(0), for: [bob])
        let frames = exchange.takeQueries()
        #expect(frames.map(\.peer) == [bob, bob, alice, alice])
        #expect(frames.map(\.hashes.count) == [32, 8, 32, 8])
        #expect(exchange.takeQueries().isEmpty)
    }
}
