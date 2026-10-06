import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// When nobody in reach holds a blob (knit-next ADR 2026-10.6e5t), ported from `BlobHolderQueryTest`: a neighbour that
/// lacks it is asked to pull it through and queried again shortly, a dead blob's cycles back off, and a lead ends the
/// backoff.
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
        _ = exchange.recordWant(photo, now: 0, author: nil, via: via, asker: nil)
        return exchange
    }

    private func step(_ exchange: inout BlobExchange, _ linked: [BlobExchange.Candidate], at now: Int64) -> BlobExchange.Plan {
        exchange.decide(photo, among: linked, now: now)
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
        #expect(BlobExchange.askLine(photo, hop, .pull) == "blob pull \(photo.string.prefix(8))… → \(bob) (via hop)")
        #expect(hop.wake == recheck, "the hop is queried again once its own pull may have landed")
        #expect(exchange.counts.pullThroughs == 1)
        let wide = deadCycle(&exchange, linked, at: cycle)
        #expect(wide.asks.map(\.to) == [bob, carol] && wide.why == "wide", "from the next empty cycle on")
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
            let gap = want?.cycleGap(dead: true) ?? 0
            #expect(want?.isCycleDue(at: opened + gap - 1) == false)
            #expect(want?.isCycleDue(at: opened + gap) == true)
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
        #expect(exchange.wants[photo]?.isCycleDue(at: 2 * cycle + 99) == false)
        #expect(exchange.wants[photo]?.isCycleDue(at: 2 * cycle + 100) == true)
    }

    @Test func thePullerIsNeverQueriedBackInTheCycleItsAskOpens() {
        // A dead blob's pulls once went back and forth between two phones: the ask that opened the puller's next cycle
        // marked the asker first, and the new cycle forgot the mark.
        var exchange = exchange(via: bob)
        let linked = capable(bob, carol)
        _ = deadCycle(&exchange, linked, at: 0)
        _ = exchange.recordWant(photo, now: cycle + 10, author: nil, via: nil, asker: bob)
        let next = step(&exchange, linked, at: cycle + 10)
        #expect(next.query == [carol])
        #expect(exchange.wants[photo]?.pullers == [bob])
    }
}
