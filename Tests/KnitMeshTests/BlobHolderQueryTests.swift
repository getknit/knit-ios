import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// The asker's half of the holder query (knit-next ADR 2026-10.6e5t), ported from `BlobHolderQueryTest`'s one-radio
/// cases: query every neighbour that can answer, ask the best holder alone, confirm and fall back, and ask blind only
/// once no confirmed holder is left.
@Suite struct BlobHolderQueryTests {
    private let bob = TestPeer(seed: 2).nodeId
    private let carol = TestPeer(seed: 3).nodeId
    private let dave = TestPeer(seed: 4).nodeId
    private let photo = BlobHash(of: Array("a photo".utf8))
    private let grace = BlobExchange.firstAskGraceMilliseconds
    private let wait = BlobExchange.queryWaitMilliseconds

    private func capable(_ ids: NodeId..., streaming: Set<NodeId> = []) -> [BlobExchange.Candidate] {
        ids.map { BlobExchange.Candidate(id: $0, streaming: streaming.contains($0), capable: true) }
    }

    private func exchange(author: NodeId? = nil) -> BlobExchange {
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, author: author, via: nil, asker: nil)
        return exchange
    }

    private func step(_ exchange: inout BlobExchange, _ linked: [BlobExchange.Candidate], at now: Int64) -> BlobExchange.Plan {
        exchange.decide(photo, among: linked, now: now)
    }

    /// `peer` answers `state` for the photo, with `load`, to the query it was last sent.
    private func answer(
        _ exchange: inout BlobExchange, _ peer: NodeId, _ state: BlobHolding, load: Int = 0, at now: Int64
    ) -> [BlobHasItem] {
        let item = BlobHasItem(hash: photo.string, state: state, size: state.isHeld ? 1000 : nil)
        return exchange.recordAnswers(BlobHasContent(items: [item], load: load), from: peer, now: now).touched
    }

    @Test func everyNeighbourThatCanAnswerIsQueriedOnceAndNothingIsAskedUntilTheAnswersAreIn() {
        var exchange = exchange()
        let linked = capable(bob, carol)
        let first = step(&exchange, linked, at: 0)
        #expect(first.query == [bob, carol] && first.asks.isEmpty)
        #expect(first.wake == wait)
        #expect(exchange.takeQueries().map(\.peer) == [bob, carol])
        _ = answer(&exchange, bob, .have, at: 100)
        let partly = step(&exchange, linked, at: 100)
        #expect(partly.query.isEmpty && partly.asks.isEmpty, "carol's answer is still due")
        #expect(partly.wake == wait - 100)
        _ = answer(&exchange, carol, .notHeld, at: 200)
        let chosen = step(&exchange, linked, at: 200)
        #expect(chosen.asks == [BlobExchange.Ask(to: bob, line: .fetch)])
        #expect(BlobExchange.askLine(photo, chosen, .fetch).hasSuffix("(link, load 0), grace \(grace) ms"))
        #expect(exchange.counts.fetches == 1)
    }

    @Test func theBestHolderIsAskedAloneByItsLinkThenItsLoadThenItsId() {
        var exchange = exchange()
        let linked = capable(bob, carol, dave, streaming: [dave])
        _ = step(&exchange, linked, at: 0)
        _ = answer(&exchange, bob, .have, load: 2, at: 10)
        _ = answer(&exchange, carol, .have, load: 1, at: 10)
        _ = answer(&exchange, dave, .have, load: 0, at: 10)
        let plan = step(&exchange, linked, at: 10)
        #expect(plan.asks.map(\.to) == [carol], "dave streams us a file, so it ranks below a quiet link")
        #expect(plan.why == "link, load 1")
    }

    @Test func holdersOnTheSameLinkAndLoadAreTakenByIdAndOneStreamingToUsIsASlowLink() {
        var tied = exchange()
        _ = step(&tied, capable(carol, bob), at: 0)
        _ = answer(&tied, carol, .have, at: 10)
        _ = answer(&tied, bob, .have, at: 10)
        let lower = [bob, carol].min { $0.string < $1.string }
        #expect(step(&tied, capable(carol, bob), at: 10).asks.map(\.to) == [lower].compactMap(\.self))
        var busy = exchange()
        _ = step(&busy, capable(bob, streaming: [bob]), at: 0)
        _ = answer(&busy, bob, .have, at: 10)
        #expect(step(&busy, capable(bob, streaming: [bob]), at: 10).why == "slow link, load 0")
    }

    @Test func aSilentNeighbourIsAskedBlindAndOneThatLacksItIsAskedToPullItThrough() {
        var exchange = exchange()
        let linked = capable(bob, carol)
        _ = step(&exchange, linked, at: 0)
        _ = answer(&exchange, carol, .notHeld, at: 10)
        #expect(step(&exchange, linked, at: wait).asks == [BlobExchange.Ask(to: bob, line: .first)])
        let pull = step(&exchange, linked, at: wait + grace)
        #expect(pull.asks == [BlobExchange.Ask(to: carol, line: .pull)], "bob said nothing, so nothing is known it lacks")
    }

    @Test func aHolderAlreadySendingIsWaitedOnNotAsked() {
        var exchange = exchange()
        _ = step(&exchange, capable(bob, carol), at: 0)
        _ = answer(&exchange, bob, .sending, at: 10)
        let plan = step(&exchange, capable(bob, carol), at: 10)
        #expect(plan.asks.isEmpty && plan.wake == grace)
        #expect(plan.notes == ["blob wait \(photo.string.prefix(8))… on \(bob) (sending), grace \(grace) ms"])
    }

    @Test func aHolderThatBringsNothingIsConfirmedThenPassedOverForTheNext() {
        var exchange = exchange()
        let linked = capable(bob, carol)
        _ = step(&exchange, linked, at: 0)
        _ = answer(&exchange, bob, .have, load: 0, at: 10)
        _ = answer(&exchange, carol, .have, load: 1, at: 10)
        #expect(step(&exchange, linked, at: 10).asks.map(\.to) == [bob])
        let confirm = step(&exchange, linked, at: 10 + grace)
        #expect(confirm.query == [bob] && confirm.asks.isEmpty && confirm.wake == wait)
        _ = answer(&exchange, bob, .notHeld, at: 20 + grace)
        let next = step(&exchange, linked, at: 20 + grace)
        #expect(next.asks.map(\.to) == [carol])
        #expect(next.notes.contains("blob fallback \(photo.string.prefix(8))… \(bob) (confirm NONE) → next"))
        #expect(exchange.counts.confirms == 1 && exchange.counts.fallbacks == 1)
    }

    @Test func aSilentConfirmFallsBack() {
        var exchange = exchange()
        let linked = capable(bob, carol)
        _ = step(&exchange, linked, at: 0)
        _ = answer(&exchange, bob, .have, at: 10)
        _ = answer(&exchange, carol, .have, load: 1, at: 10)
        _ = step(&exchange, linked, at: 10)
        _ = step(&exchange, linked, at: 10 + grace)
        #expect(step(&exchange, linked, at: 10 + grace + wait - 1).asks.isEmpty, "its answer is still due")
        let silent = step(&exchange, linked, at: 10 + grace + wait)
        #expect(silent.asks.map(\.to) == [carol])
        #expect(silent.notes.contains { $0.hasSuffix("\(bob) (confirm silent) → next") })
    }

    @Test func aConfirmThatStillSendsBuysAnotherGraceAndTheSecondConfirmIsNeverRead() {
        // Android's `fetchWait` checks `MAX_CONFIRMS` before `confirmWait` reads the second confirm's answer
        // (`BlobExchange.kt:385`), so a holder still sending after two graces is passed over for its grace. Ported as
        // written, so both phones log the same steps; a fix lands in knit-next first.
        var exchange = exchange()
        let linked = capable(bob, carol)
        _ = step(&exchange, linked, at: 0)
        _ = answer(&exchange, bob, .have, at: 10)
        _ = answer(&exchange, carol, .have, load: 1, at: 10)
        _ = step(&exchange, linked, at: 10)
        _ = step(&exchange, linked, at: 10 + grace)
        _ = answer(&exchange, bob, .sending, at: 20 + grace)
        let more = step(&exchange, linked, at: 20 + grace)
        #expect(more.asks.isEmpty && more.wake == grace, "still sending: a fresh grace")
        #expect(step(&exchange, linked, at: 20 + 2 * grace).query == [bob], "the second confirm")
        _ = answer(&exchange, bob, .sending, at: 30 + 2 * grace)
        let passed = step(&exchange, linked, at: 20 + 2 * grace + wait)
        #expect(passed.asks.map(\.to) == [carol])
        #expect(passed.notes.contains { $0.hasSuffix("\(bob) (grace) → next") })
        #expect(exchange.counts.confirms == 2)
    }

    @Test func aHolderThatSaysHaveToAQueryAfterOurAskNeverGotItAndIsAskedOnceMore() {
        var exchange = exchange()
        let linked = capable(bob)
        _ = step(&exchange, linked, at: 0)
        _ = answer(&exchange, bob, .have, at: 10)
        _ = step(&exchange, linked, at: 10)
        _ = step(&exchange, linked, at: 10 + grace)
        _ = answer(&exchange, bob, .have, at: 20 + grace)
        #expect(step(&exchange, linked, at: 20 + grace).asks == [BlobExchange.Ask(to: bob, line: .fetch)])
    }

    @Test func theBlindTierWaitsUntilNoConfirmedHolderIsLeft() {
        var exchange = exchange(author: dave)
        let linked = capable(bob) + [BlobExchange.Candidate(id: dave, streaming: false, capable: false)]
        let first = step(&exchange, linked, at: 0)
        #expect(first.query == [bob] && first.asks.isEmpty, "a holder that says so beats an author that cannot")
        _ = answer(&exchange, bob, .have, at: 10)
        #expect(step(&exchange, linked, at: 10).asks.map(\.to) == [bob])
        _ = step(&exchange, linked, at: 10 + grace)
        _ = answer(&exchange, bob, .notHeld, at: 20 + grace)
        #expect(step(&exchange, linked, at: 20 + grace).asks == [BlobExchange.Ask(to: dave, line: .first)])
    }

    @Test func aHolderThatAnswersJustAfterTheRoundWidensWaitsForTheWideningsGraceAndItsMemo() {
        // f7gg: a widened round's asks have their own grace, and a holder asked blind is not asked again in the memo.
        var exchange = exchange(author: carol)
        let linked = capable(bob) + [BlobExchange.Candidate(id: carol, streaming: false, capable: false)]
        _ = step(&exchange, linked, at: 0)
        #expect(step(&exchange, linked, at: wait).asks == [BlobExchange.Ask(to: carol, line: .first)])
        #expect(step(&exchange, linked, at: wait + grace).asks == [BlobExchange.Ask(to: bob, line: .widened)])
        _ = answer(&exchange, bob, .have, at: wait + grace + 1000)
        let held = step(&exchange, linked, at: wait + grace + 1000)
        #expect(held.asks.isEmpty)
        #expect(held.wake == grace - 1000, "the widened asks' grace runs first")
    }

    @Test func aQueriedNeighbourStillSilentPastTheWaitIsAskedBlind() {
        var exchange = exchange()
        _ = step(&exchange, capable(bob), at: 0)
        #expect(step(&exchange, capable(bob), at: wait - 1).asks.isEmpty)
        #expect(step(&exchange, capable(bob), at: wait).asks == [BlobExchange.Ask(to: bob, line: .first)])
    }

    @Test func anAnswerCountsOnlyFromANeighbourQueriedThisCycleForAHashItsQueryNamed() {
        var exchange = exchange()
        _ = step(&exchange, capable(bob), at: 0)
        exchange.noteQuerySent("q1", to: bob, hashes: [photo], now: 0)
        let item = BlobHasItem(hash: photo.string, state: .have, size: 10)
        let stranger = exchange.recordAnswers(BlobHasContent(items: [item], re: "q1"), from: carol, now: 5)
        #expect(stranger.touched.isEmpty, "carol was never queried")
        exchange.noteQuerySent("q2", to: bob, hashes: [], now: 0)
        #expect(exchange.recordAnswers(BlobHasContent(items: [item], re: "q2"), from: bob, now: 5).touched.isEmpty)
        let taken = exchange.recordAnswers(BlobHasContent(items: [item], re: "q1"), from: bob, now: 250)
        #expect(taken.touched == [item] && taken.latency == 250)
        let unnamed = exchange.recordAnswers(BlobHasContent(items: [item]), from: bob, now: 300)
        #expect(unnamed.touched == [item] && unnamed.latency == nil, "no query named: taken, as Android takes it")
        #expect(exchange.counts.answersIgnored == 2 && exchange.counts.answersTaken == 2)
    }

    @Test func aStateThisBuildDoesNotKnowIsNeverTakenForHave() {
        var exchange = exchange()
        _ = step(&exchange, capable(bob), at: 0)
        _ = answer(&exchange, bob, .partial, at: 10)
        let plan = step(&exchange, capable(bob), at: 10)
        #expect(plan.asks == [BlobExchange.Ask(to: bob, line: .pull)], "a lacking neighbour, asked to pull it through")
    }

    @Test func aNeighbourThatLinksAgainIsQueriedAgainAtOnce() {
        var exchange = exchange()
        _ = step(&exchange, capable(bob), at: 0)
        _ = answer(&exchange, bob, .notHeld, at: 10)
        exchange.linked([bob])
        #expect(step(&exchange, capable(bob), at: 20).query == [bob])
    }
}
