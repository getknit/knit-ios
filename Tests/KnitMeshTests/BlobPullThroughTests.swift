import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// When nobody in reach holds a blob (knit-next ADR 2026-10.6e5t), ported from `BlobHolderQueryTest`: a neighbour that
/// lacks it is asked to pull it through and queried again shortly, a dead blob's cycles back off, and a lead ends the
/// backoff. Past its deadline nobody is asked to pull it (knit-next ADR 2026-10.2drc), and the latest want of our own says
/// what the deadline is.
@Suite struct BlobPullThroughTests {
    private let bob = TestPeer(seed: 2).nodeId
    private let carol = TestPeer(seed: 3).nodeId
    private let photo = BlobHash(of: Array("a photo".utf8))
    private let recheck = BlobExchange.fetchingRecheckMilliseconds
    private let cycle = BlobExchange.cycleMilliseconds

    private func capable(_ ids: NodeId...) -> [BlobExchange.Candidate] {
        ids.map { BlobExchange.Candidate(id: $0, streaming: false, capable: true) }
    }

    private func exchange(via: NodeId? = nil) -> BlobExchange {
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(
            photo, now: 0, wall: wallAt(0), author: nil, via: via, asker: nil, reach: .own(until: nil, rederived: false))
        return exchange
    }

    private func step(_ exchange: inout BlobExchange, _ linked: [BlobExchange.Candidate], at now: Int64) -> BlobExchange.Plan {
        exchange.decide(photo, among: linked, now: now, wall: wallAt(now))
    }

    private func answer(_ exchange: inout BlobExchange, _ peer: NodeId, _ state: BlobHolding, at now: Int64) {
        _ = exchange.recordAnswers(BlobHasContent(items: [BlobHasItem(hash: photo.string, state: state)]), from: peer, now: now)
    }

    /// A cycle at `now` in which every neighbour says it lacks the blob: queried, answered, and asked to pull it.
    private func deadCycle(_ exchange: inout BlobExchange, _ linked: [BlobExchange.Candidate], at now: Int64) -> BlobExchange.Plan {
        _ = step(&exchange, linked, at: now)
        for candidate in linked {
            answer(&exchange, candidate.id, .notHeld, at: now)
        }
        return step(&exchange, linked, at: now)
    }

    @Test func theHopIsAskedToPullItThroughFirstThenEveryNeighbourThatLacksIt() {
        var exchange = exchange(via: bob)
        let linked = capable(bob, carol)
        let hop = deadCycle(&exchange, linked, at: 0)
        #expect(hop.asks == [BlobExchange.Ask(to: bob, line: .pull)] && hop.why == "via hop")
        #expect(BlobExchange.askLine(photo, hop, .pull) == "blob pull \(photo.string.prefix(8))… → \(bob) (via hop) [pull 3]")
        #expect(hop.wake == recheck, "the hop is queried again once its own pull may have landed")
        #expect(exchange.counts.pullThroughs == 1)
        let wide = deadCycle(&exchange, linked, at: cycle)
        #expect(wide.asks.map(\.to) == [bob, carol] && wide.why == "wide", "from the next empty cycle on")
    }

    @Test func aPullHasNothingToWithdrawOnceItsNeighbourSaysAtOrAfterItThatItLacksTheBlob() {
        // A neighbour that lacks a blob remembers no asker (knit-next ADR 2026-10.nsr7's device rerun of 2026-10-07, where a
        // dead want sent a cancel every cycle). Only an answer at or after the ask says the ask found it lacking.
        var exchange = exchange(via: bob)
        let linked = capable(bob, carol)
        var together = exchange
        #expect(deadCycle(&together, linked, at: 0).asks.map(\.to) == [bob])
        #expect(together.obtained(photo, from: carol).isEmpty, "pulled in the step its answer came in")
        _ = step(&exchange, linked, at: 0)
        answer(&exchange, bob, .notHeld, at: 0)
        answer(&exchange, carol, .notHeld, at: 0)
        #expect(step(&exchange, linked, at: 10).asks.map(\.to) == [bob])
        var earlier = exchange
        #expect(earlier.obtained(photo, from: carol) == [bob], "its answer is older than the ask, which may have found it holding")
        answer(&exchange, bob, .fetching, at: recheck + 10)
        var lacking = exchange
        #expect(lacking.obtained(photo, from: carol).isEmpty, "it said after the ask that it lacks it")
        answer(&exchange, bob, .have, at: 2 * recheck)
        #expect(exchange.obtained(photo, from: carol) == [bob], "it holds it now, and may have our copy queued")
    }

    @Test func nothingIsPulledWhileANeighbourFetchesItAndThatNeighbourIsQueriedAgainShortly() {
        var exchange = exchange(via: bob)
        let linked = capable(bob, carol)
        _ = step(&exchange, linked, at: 0)
        answer(&exchange, bob, .fetching, at: 10)
        answer(&exchange, carol, .notHeld, at: 10)
        let waiting = step(&exchange, linked, at: 10)
        #expect(waiting.asks.isEmpty && waiting.wake == recheck - 10)
        #expect(step(&exchange, linked, at: recheck).query == [bob])
        #expect(exchange.counts.pullThroughs == 0)
    }

    @Test func aNeighbourAskedToPullIsQueriedAgainAtMostFourTimesInACycle() {
        var exchange = exchange(via: bob)
        let linked = capable(bob)
        _ = deadCycle(&exchange, linked, at: 0)
        let rechecks = (1...4).map { step(&exchange, linked, at: Int64($0) * recheck).query }
        #expect(rechecks == [[bob], [bob], [bob], [bob]])
        #expect(step(&exchange, linked, at: cycle - 1).query.isEmpty, "four, then the next cycle's query")
    }

    @Test func pullRechecksRunOnlyInTheFirstTwoCyclesOfADeadStreak() {
        var exchange = exchange(via: bob)
        let linked = capable(bob)
        _ = deadCycle(&exchange, linked, at: 0)
        _ = deadCycle(&exchange, linked, at: cycle)
        #expect(step(&exchange, linked, at: cycle + recheck).query == [bob], "the second cycle still rechecks")
        let third = deadCycle(&exchange, linked, at: 3 * cycle)
        #expect(third.asks.map(\.to) == [bob], "the pull itself still goes")
        #expect(exchange.wants[photo]?.deadCycles == 2)
        #expect(third.wake == nil)
        #expect(step(&exchange, linked, at: 3 * cycle + recheck).query.isEmpty, "deep in the backoff")
    }

    @Test func eachDeadCycleInARowDoublesTheWaitForTheNextUpToSixMinutes() {
        var exchange = exchange(via: bob)
        let linked = capable(bob)
        var opened: Int64 = 0
        var gaps: [Int64] = []
        for _ in 0..<5 {
            _ = deadCycle(&exchange, linked, at: opened)
            let want = exchange.wants[photo]
            let gap = want?.cycleGap(now: opened, wall: wallAt(opened), dead: true) ?? 0
            #expect(want?.isCycleDue(at: opened + gap - 1, wall: wallAt(opened + gap - 1)) == false)
            #expect(want?.isCycleDue(at: opened + gap, wall: wallAt(opened + gap)) == true)
            gaps.append(gap)
            opened += gap
        }
        #expect(gaps == [cycle, 2 * cycle, 4 * cycle, 8 * cycle, 8 * cycle])
        let reopened = step(&exchange, linked, at: opened)
        #expect(reopened.notes == ["blob cycle \(photo.string.prefix(8))… after 5 dead, next if dead in \(8 * cycle) ms"])
    }

    @Test func aLeadEndsTheBackoffAndTheNextCycleIsDueACycleAfterIt() {
        var exchange = exchange(via: bob)
        let linked = capable(bob)
        _ = deadCycle(&exchange, linked, at: 0)
        _ = step(&exchange, linked, at: cycle)
        #expect(exchange.wants[photo]?.deadCycles == 1)
        answer(&exchange, bob, .fetching, at: cycle + 100)
        #expect(exchange.wants[photo]?.deadCycles == 0)
        #expect(exchange.wants[photo]?.isCycleDue(at: 2 * cycle + 99, wall: wallAt(2 * cycle + 99)) == false)
        #expect(exchange.wants[photo]?.isCycleDue(at: 2 * cycle + 100, wall: wallAt(2 * cycle + 100)) == true)
    }

    @Test func thePullerIsNeverQueriedBackInTheCycleItsAskOpens() {
        // A dead blob's pulls once went back and forth between two phones: the ask that opened the puller's next cycle
        // marked the asker first, and the new cycle forgot the mark.
        var exchange = exchange(via: bob)
        let linked = capable(bob, carol)
        _ = deadCycle(&exchange, linked, at: 0)
        let reach = BlobExchange.Reach.asked(pull: BlobExchange.pullBudget, until: nil)
        _ = exchange.recordWant(photo, now: cycle + 10, wall: wallAt(cycle + 10), author: nil, via: nil, asker: bob, reach: reach)
        let next = step(&exchange, linked, at: cycle + 10)
        #expect(next.query == [carol])
        #expect(exchange.wants[photo]?.pullers == [bob])
    }

    // MARK: The deadline (knit-next ADR 2026-10.2drc)

    /// A want of our own, re-armed at `now` with deadline `until`, re-derived from every row naming it when `rederived`.
    private func rearm(_ exchange: inout BlobExchange, at now: Int64, until: Int64?, rederived: Bool = true) {
        _ = exchange.recordWant(
            photo, now: now, wall: wallAt(now), author: nil, via: nil, asker: nil, reach: .own(until: until, rederived: rederived))
    }

    @Test func aWantPastItsDeadlineAsksNobodyToPullItAndStillFetchesFromAHolder() {
        // `aWantPastItsDeadlineAsksNobodyToPullItAndStillFetchesFromAHolder`: nobody in reach holds it, and its DM's custody
        // window is over. A minute's tick re-arms it, re-derived, for 25 minutes.
        var exchange = BlobExchange(queriesHolders: true)
        let linked = capable(bob, carol)
        var asked: [BlobExchange.Ask] = []
        var notes: [String] = []
        for tick in Int64(0)...25 {
            let now = tick * 60_000
            rearm(&exchange, at: now, until: 0)
            let plan = deadCycle(&exchange, linked, at: now)
            asked += plan.asks
            notes += plan.notes
        }
        #expect(asked.isEmpty, "nobody was asked to pull it")
        // Cycles at 0, 1, 3, 6, 12 and 24 min: past its deadline, the fifth dead cycle backs off past 6 min.
        #expect(exchange.counts.pullsWithheld == 6, "each dead cycle said so once")
        let withheld = "blob no-pull \(photo.string.prefix(8))… → nobody of \(bob), \(carol) (past its deadline)"
        #expect(notes.filter { $0 == withheld }.count == 6)
        // A newcomer that holds it is queried at once, and asked for it: a holder still serves past the deadline.
        let eve = TestPeer(seed: 5).nodeId
        let now: Int64 = 25 * 60_000 + 1000
        exchange.linked([eve])
        let withEve = linked + capable(eve)
        #expect(step(&exchange, withEve, at: now).query == [eve])
        answer(&exchange, eve, .have, at: now)
        let fetch = step(&exchange, withEve, at: now)
        #expect(fetch.asks == [BlobExchange.Ask(to: eve, line: .fetch)])
        #expect(fetch.pull == BlobExchange.pullBudget && fetch.until == 0, "with its budget and deadline, as every ask")
        #expect(BlobExchange.askLine(photo, fetch, .fetch).hasSuffix(" [pull 3, until 0]"))
    }

    @Test func theLatestWantOfOurOwnSetsTheDeadlineAndANeighboursAskNeverDoes() {
        var exchange = BlobExchange(queriesHolders: true)
        let linked = capable(bob, carol)
        rearm(&exchange, at: 0, until: 0)
        #expect(deadCycle(&exchange, linked, at: 0).asks.isEmpty, "both said they lack it: a pull was due, and withheld")
        #expect(exchange.counts.pullsWithheld == 1)
        // Bob lacks it too: his ask opens the next cycle, Carol is queried, and her NONE makes a pull due, withheld again.
        let reach = BlobExchange.Reach.asked(pull: BlobExchange.pullBudget, until: nil)
        _ = exchange.recordWant(photo, now: cycle, wall: wallAt(cycle), author: nil, via: nil, asker: bob, reach: reach)
        #expect(step(&exchange, linked, at: cycle).query == [carol])
        answer(&exchange, carol, .notHeld, at: cycle)
        #expect(step(&exchange, linked, at: cycle).asks.isEmpty, "a neighbour's ask did not lift the deadline")
        #expect(exchange.counts.pullsWithheld == 2)
        // A want of ours that read no row and names no deadline (an avatar's) keeps the re-arm's.
        rearm(&exchange, at: 11 * cycle, until: nil, rederived: false)
        #expect(deadCycle(&exchange, linked, at: 11 * cycle).asks.isEmpty, "it did not lift it")
        // The re-arm, reading a group's row now: no deadline at all.
        rearm(&exchange, at: 21 * cycle, until: nil)
        #expect(deadCycle(&exchange, linked, at: 21 * cycle).asks.map(\.to) == [bob, carol], "the re-arm lifted it")
        // And set it again.
        rearm(&exchange, at: 31 * cycle, until: 0)
        #expect(deadCycle(&exchange, linked, at: 31 * cycle).asks.isEmpty)
        #expect(exchange.wants[photo]?.until == 0)
    }
}
