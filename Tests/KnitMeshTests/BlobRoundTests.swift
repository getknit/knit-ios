import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// knit-next ADR 2026-10.f7gg's round over the neighbours that cannot be queried, ported from `BlobExchangeTest`'s
/// one-radio cases: one ask of the likeliest holder, then every other neighbour at once once its grace is up.
@Suite struct BlobRoundTests {
    private let alice = TestPeer(seed: 1).nodeId
    private let bob = TestPeer(seed: 2).nodeId
    private let carol = TestPeer(seed: 3).nodeId
    private let photo = BlobHash(of: Array("a photo".utf8))
    private let grace = BlobExchange.firstAskGraceMilliseconds

    private func blind(_ ids: NodeId..., streaming: Set<NodeId> = []) -> [BlobExchange.Candidate] {
        ids.map { BlobExchange.Candidate(id: $0, streaming: streaming.contains($0), capable: false) }
    }

    private func exchange(author: NodeId? = nil, via: NodeId? = nil, asker: NodeId? = nil) -> BlobExchange {
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, author: author, via: via, asker: asker)
        return exchange
    }

    private func step(_ exchange: inout BlobExchange, _ linked: [BlobExchange.Candidate], at now: Int64) -> BlobExchange.Plan {
        exchange.decide(photo, among: linked, now: now)
    }

    @Test func aRoundAsksTheAuthorAloneThenEveryOtherNeighbourOnceItsGraceIsUp() {
        var exchange = exchange(author: carol)
        let linked = blind(alice, bob, carol)
        let first = step(&exchange, linked, at: 0)
        #expect(first.asks == [BlobExchange.Ask(to: carol, line: .first)])
        #expect(first.wake == grace && first.why == "author")
        #expect(BlobExchange.askLine(photo, first, .first).hasSuffix("first (author), widen in \(grace) ms"))
        let waiting = step(&exchange, linked, at: grace - 1)
        #expect(waiting.asks.isEmpty && waiting.wake == 1)
        let widened = step(&exchange, linked, at: grace)
        #expect(widened.asks == [BlobExchange.Ask(to: alice, line: .widened), BlobExchange.Ask(to: bob, line: .widened)])
        #expect(BlobExchange.askLine(photo, widened, .widened).hasSuffix(" widened"))
        #expect(step(&exchange, linked, at: grace + 1000).asks.isEmpty, "everyone asked once this round")
        #expect(exchange.counts.blindAsks == 2)
    }

    @Test func theFirstAskGoesToTheAuthorThenTheSourceHopThenTheLowestId() {
        var authored = exchange(author: bob, via: carol)
        #expect(step(&authored, blind(alice, bob, carol), at: 0).asks.map(\.to) == [bob])
        var carried = exchange(author: TestPeer(seed: 9).nodeId, via: carol)
        let hop = step(&carried, blind(alice, bob, carol), at: 0)
        #expect(hop.asks.map(\.to) == [carol] && hop.why == "source hop")
        var unnamed = exchange()
        let lowest = [alice, bob, carol].min { $0.string < $1.string }
        let any = step(&unnamed, blind(carol, bob, alice), at: 0)
        #expect(any.asks.map(\.to) == [lowest].compactMap(\.self) && any.why == "neighbour")
    }

    @Test func theGraceCountsFromTheFirstLookThatFindsTheHolderNoLongerStreaming() {
        // The #136 trial's S4: a grace restarted at the last look that saw the stream asked past a header 1.4 s out.
        var exchange = exchange(author: bob)
        _ = step(&exchange, blind(bob, carol), at: 0)
        let polling = step(&exchange, blind(bob, carol, streaming: [bob]), at: 3000)
        #expect(polling.asks.isEmpty && polling.wake == BlobExchange.streamPollMilliseconds)
        #expect(step(&exchange, blind(bob, carol, streaming: [bob]), at: 7000).asks.isEmpty, "past the grace, but streaming")
        let quiet = step(&exchange, blind(bob, carol), at: 9000)
        #expect(quiet.asks.isEmpty && quiet.wake == grace, "the grace starts at the first quiet look")
        #expect(step(&exchange, blind(bob, carol), at: 9000 + grace - 1).asks.isEmpty)
        #expect(step(&exchange, blind(bob, carol), at: 9000 + grace).asks.map(\.to) == [carol])
    }

    @Test func aNeighbourAskedBeforeIsNotAskedAgainWhileItsFileStreamsIn() {
        // knit-next ADR 2026-10.nxfb: our copy may sit in its stack behind the file streaming in now.
        var exchange = exchange(author: bob)
        _ = step(&exchange, blind(bob, carol), at: 0)
        _ = step(&exchange, blind(bob, carol), at: grace)
        let next = step(&exchange, blind(bob, carol, streaming: [bob]), at: 60_000)
        #expect(next.asks == [BlobExchange.Ask(to: carol, line: .first)], "a new round, its author passed over")
    }

    @Test func aFirstChoiceWhoseLinkIsGoneWidensTheRoundAtOnce() {
        var exchange = exchange(author: bob)
        _ = step(&exchange, blind(bob, carol), at: 0)
        #expect(step(&exchange, blind(carol), at: 1000).asks == [BlobExchange.Ask(to: carol, line: .widened)])
    }

    @Test func aNeighbourThatLinksDuringTheFirstAsksGraceWaitsForTheWidening() {
        var exchange = exchange(author: bob)
        _ = step(&exchange, blind(bob), at: 0)
        #expect(step(&exchange, blind(bob, carol), at: 1000).asks.isEmpty)
        #expect(step(&exchange, blind(bob, carol), at: grace).asks.map(\.to) == [carol])
    }

    @Test func aNeighbourThatLinksAgainIsAskedAgainAtOnce() {
        // A chaos sweep of `AttachmentResumeLabTest` caught a round counting an ask lost to a dropped link.
        var exchange = exchange(author: bob)
        _ = step(&exchange, blind(bob, carol), at: 0)
        exchange.linked([bob])
        #expect(step(&exchange, blind(bob, carol), at: 1000).asks == [BlobExchange.Ask(to: bob, line: .first)])
    }

    @Test func theNextRoundOpensACycleOnWithOneAskAndABlindRoundNeverBacksOff() {
        var exchange = exchange(author: bob)
        _ = step(&exchange, blind(bob, carol), at: 0)
        _ = step(&exchange, blind(bob, carol), at: grace)
        #expect(step(&exchange, blind(bob, carol), at: BlobExchange.cycleMilliseconds - 1).asks.isEmpty)
        for round in 1...4 {
            let now = Int64(round) * BlobExchange.cycleMilliseconds
            #expect(step(&exchange, blind(bob, carol), at: now).asks == [BlobExchange.Ask(to: bob, line: .first)])
            _ = step(&exchange, blind(bob, carol), at: now + grace)
        }
        #expect(exchange.wants[photo]?.deadCycles == 0, "a round that asked blind may have reached a holder")
    }

    @Test func aBlobPulledForANeighbourIsNotAskedOfItThatRoundButIsTheNext() {
        var exchange = exchange(asker: bob)
        #expect(step(&exchange, blind(bob, carol), at: 0).asks.map(\.to) == [carol])
        #expect(step(&exchange, blind(bob, carol), at: grace).asks.isEmpty, "the asker lacks it")
        let next = step(&exchange, blind(bob, carol), at: BlobExchange.cycleMilliseconds)
        #expect(next.asks.count == 1, "a later round asks it: it may be the one path left")
        #expect(step(&exchange, blind(bob, carol), at: BlobExchange.cycleMilliseconds + grace).asks.count == 1)
    }

    @Test func withQueriesOffACapableNeighbourIsAskedBlindAndNeverQueried() {
        var exchange = BlobExchange(queriesHolders: false)
        _ = exchange.recordWant(photo, now: 0, author: bob, via: nil, asker: nil)
        let capable = [bob, carol].map { BlobExchange.Candidate(id: $0, streaming: false, capable: true) }
        let plan = exchange.decide(photo, among: capable, now: 0)
        #expect(plan.query.isEmpty)
        #expect(plan.asks == [BlobExchange.Ask(to: bob, line: .first)])
    }
}
