import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// knit-next #140, the amendment of 2026-10-06 to ADR 2026-10.6e5t: an ask to a holder stands until its link goes, its
/// floor passes or it says it no longer holds the blob, and every wait on a neighbour stretches to its round trip.
/// Ported from `BlobHolderQueryTest`'s cases for it. In the trace, the Pixel 3's own frames were queued, so every answer
/// missed its wait, the author was asked blind, and a second holder's late HAVE bought a second copy.
@Suite struct BlobAskStandsTests {
    private let author = TestPeer(seed: 2).nodeId
    private let holder = TestPeer(seed: 3).nodeId
    private let photo = BlobHash(of: Array("a photo".utf8))
    private let grace = BlobExchange.firstAskGraceMilliseconds
    private let wait = BlobExchange.queryWaitMilliseconds
    private let memo = BlobExchange.serveMemoMilliseconds

    private func capable(_ ids: NodeId...) -> [BlobExchange.Candidate] {
        ids.map { BlobExchange.Candidate(id: $0, streaming: false, capable: true) }
    }

    private func step(_ exchange: inout BlobExchange, _ linked: [BlobExchange.Candidate], at now: Int64) -> BlobExchange.Plan {
        exchange.decide(photo, among: linked, now: now)
    }

    /// Sends the queries the steps so far owe at `now`, each under an id of its own, as the engine's flush does.
    private func send(_ exchange: inout BlobExchange, at now: Int64) {
        for query in exchange.takeQueries() {
            exchange.noteQuerySent("\(query.peer)@\(now)", to: query.peer, hashes: query.hashes, now: now)
        }
    }

    /// `peer` says it holds `hash`, with `load`, to the latest query sent it, at `now`.
    private func answer(_ exchange: inout BlobExchange, _ peer: NodeId, have hash: BlobHash, load: Int, at now: Int64) {
        let latest = exchange.sentQueries.values.filter { $0.peer == peer }.max { $0.at < $1.at }
        let item = BlobHasItem(hash: hash.string, state: .have, size: 1000)
        let re = latest.map { "\($0.peer)@\($0.at)" }
        _ = exchange.recordAnswers(BlobHasContent(items: [item], load: load, re: re), from: peer, now: now)
    }

    /// The trace, held: both neighbours miss the wait, the author is asked blind and says HAVE 7 s late, inside its
    /// grace. At the grace's end it is confirmed rather than widened past, the holder's HAVE lands 12 s late and is not
    /// asked, and the confirm's silence holds the ask to its floor. Answers the books at that point, 22 s in.
    private func heldOnTheAuthor() -> BlobExchange {
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, author: author, via: nil, asker: nil)
        let linked = capable(author, holder)
        _ = step(&exchange, linked, at: 0)
        send(&exchange, at: 0)
        #expect(step(&exchange, linked, at: wait).asks == [BlobExchange.Ask(to: author, line: .first)], "both silent")
        answer(&exchange, author, have: photo, load: 0, at: 7000)
        #expect(step(&exchange, linked, at: 7000).asks.isEmpty, "inside the blind ask's grace")
        let confirm = step(&exchange, linked, at: wait + grace)
        #expect(confirm.query == [author] && confirm.asks.isEmpty, "the author that said it holds it is confirmed")
        #expect(confirm.wake == 7000 + wait, "the confirm's wait stretches to the author's 7 s round trip")
        #expect(exchange.counts.blindAsks == 1, "not widened: nobody else is asked blind")
        send(&exchange, at: wait + grace)
        answer(&exchange, holder, have: photo, load: 0, at: 12_000)
        #expect(step(&exchange, linked, at: 12_000).asks.isEmpty, "the author's ask still stands: the holder is not asked")
        let held = step(&exchange, linked, at: 22_000)
        let floor = wait + memo - 22_000
        #expect(held.asks.isEmpty && held.wake == floor)
        #expect(held.notes == ["blob hold \(photo.string.prefix(8))… on \(author) (confirm silent), floor \(floor) ms"])
        #expect(exchange.counts.fallbacks == 0)
        return exchange
    }

    @Test func aLateHaveFromASecondHolderWaitsOnTheAskStandingOnTheFirstUntilItsLinkGoes() {
        var exchange = heldOnTheAuthor()
        #expect(exchange.fetches(on: [author]) == [photo] && exchange.fetches(on: [holder]).isEmpty)
        let next = step(&exchange, capable(holder), at: 23_000)
        #expect(next.asks == [BlobExchange.Ask(to: holder, line: .fetch)], "the author's link gone, the holder is asked at once")
        #expect(next.notes.contains("blob fallback \(photo.string.prefix(8))… \(author) (link gone) → next"))
        #expect(next.cancels.isEmpty, "its link, and any copy queued on it, are gone")
        #expect(exchange.counts.fallbacks == 1)
    }

    @Test func aHeldAskEndsAtItsFloorAndTheNextCycleAsksTheHolderThatAnswers() {
        var exchange = heldOnTheAuthor()
        let linked = capable(author, holder)
        #expect(step(&exchange, linked, at: wait + memo - 1).asks.isEmpty, "inside the floor, still held")
        let floor = step(&exchange, linked, at: wait + memo)
        #expect(floor.notes.contains("blob fallback \(photo.string.prefix(8))… \(author) (floor) → next"))
        #expect(floor.cancels == [author], "the held ask is withdrawn as the fetch moves on (knit-next ADR 2026-10.nsr7)")
        #expect(floor.asks.isEmpty && floor.query == [author, holder], "the cycle that stood since 0 opens again")
        send(&exchange, at: wait + memo)
        answer(&exchange, holder, have: photo, load: 0, at: wait + memo)
        #expect(step(&exchange, linked, at: wait + memo).asks.isEmpty, "the author's answer to the new cycle is still due")
        let asked = step(&exchange, linked, at: wait + memo + 7000 + wait)
        #expect(asked.asks == [BlobExchange.Ask(to: holder, line: .fetch)], "past the author's stretched wait")
        #expect(exchange.obtained(photo, from: nil) == [holder], "the author's ask was withdrawn once, at its floor")
    }

    @Test func aHolderWhoseConfirmIsSilentIsHeldToItsFloorNotPassedOver() {
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, author: nil, via: nil, asker: nil)
        let linked = capable(holder, author)
        _ = step(&exchange, linked, at: 0)
        send(&exchange, at: 0)
        answer(&exchange, author, have: photo, load: 1, at: 0)
        answer(&exchange, holder, have: photo, load: 0, at: 1000)
        let asked = step(&exchange, linked, at: 1000)
        #expect(asked.asks.map(\.to) == [holder] && asked.wake == grace + 1000, "the grace gains its 1 s round trip")
        #expect(step(&exchange, linked, at: 1000 + grace + 1000).query == [holder], "its grace up, it is confirmed")
        send(&exchange, at: 1000 + grace + 1000)
        let silent = step(&exchange, linked, at: 1000 + grace + 1000 + wait + 1000)
        #expect(silent.asks.isEmpty, "silence on a live link is a late answer: the next holder is not asked")
        #expect(exchange.counts.fallbacks == 0)
        let floor = step(&exchange, linked, at: 1000 + memo)
        #expect(floor.query == [holder, author] && exchange.counts.fallbacks == 1, "its floor; a new cycle queries both")
        send(&exchange, at: 1000 + memo)
        answer(&exchange, author, have: photo, load: 1, at: 1000 + memo)
        let next = step(&exchange, linked, at: 1000 + memo + wait + 1000)
        #expect(next.asks.map(\.to) == [author], "past its floor and its wait, the next holder is asked")
    }

    @Test func aConfirmSilentPastTheAsksFloorMovesOnAtOnce() {
        // A 20 s round trip stretches the grace and the confirm's wait to 25 s each, past the 45 s floor: nothing to hold.
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, author: nil, via: nil, asker: nil)
        _ = step(&exchange, capable(holder), at: 0)
        send(&exchange, at: 0)
        answer(&exchange, holder, have: photo, load: 0, at: 20_000)
        #expect(step(&exchange, capable(holder), at: 20_000).wake == grace + 20_000)
        _ = step(&exchange, capable(holder), at: 45_000)
        let silent = step(&exchange, capable(holder), at: 70_000)
        #expect(silent.notes.contains("blob fallback \(photo.string.prefix(8))… \(holder) (confirm silent) → next"))
    }

    @Test func aHolderOnlyWaitedOnHasNoFloorToHoldAndIsPassedOverAfterTwoConfirms() {
        // It said it was sending before we asked, so no ask of ours stands on it: there is nothing to hold.
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, author: nil, via: nil, asker: nil)
        let linked = capable(holder, author)
        _ = step(&exchange, linked, at: 0)
        let sending = BlobHasContent(items: [BlobHasItem(hash: photo.string, state: .sending, size: 1000)], load: 0, re: nil)
        _ = exchange.recordAnswers(sending, from: holder, now: 10)
        answer(&exchange, author, have: photo, load: 1, at: 10)
        #expect(step(&exchange, linked, at: 10).notes.first?.hasPrefix("blob wait") == true)
        #expect(step(&exchange, linked, at: 10 + grace).query == [holder], "the first confirm")
        _ = exchange.recordAnswers(sending, from: holder, now: 20 + grace)
        #expect(step(&exchange, linked, at: 20 + grace).asks.isEmpty, "still sending: another grace")
        #expect(step(&exchange, linked, at: 20 + 2 * grace).query == [holder], "the second confirm")
        _ = exchange.recordAnswers(sending, from: holder, now: 30 + 2 * grace)
        // `BlobExchange.kt:385`: the second confirm's answer is never read, and with no ask of ours on it, nothing holds.
        let passed = step(&exchange, linked, at: 30 + 2 * grace)
        #expect(passed.asks == [BlobExchange.Ask(to: author, line: .fetch)])
        #expect(passed.notes.contains("blob fallback \(photo.string.prefix(8))… \(holder) (grace) → next"))
    }

    // MARK: A SENDING answer's eta (knit-next ADR 2026-10.nsr7)

    /// `peer` says it is sending the photo, its copy `eta` ms from landing, to the latest query sent it, at `now`.
    private func sending(_ exchange: inout BlobExchange, _ peer: NodeId, eta: Int64?, at now: Int64) {
        let latest = exchange.sentQueries.values.filter { $0.peer == peer }.max { $0.at < $1.at }
        let item = BlobHasItem(hash: photo.string, state: .sending, size: 1000, eta: eta)
        let re = latest.map { "\($0.peer)@\($0.at)" }
        _ = exchange.recordAnswers(BlobHasContent(items: [item], load: 0, re: re), from: peer, now: now)
    }

    @Test func aSendingAnswersEtaHoldsTheAskerPastItsFloorAndOnlyThenIsTheNextHolderAsked() {
        // `BlobHolderQueryTest.aSendingAnswersEtaHoldsTheAskerPastItsFloor`: the holder parked our ask behind another
        // copy's three-minute feed, and says when ours should land. Asking the next holder at our ask's 45 s floor would
        // buy a second copy of a photo already on its way.
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, author: nil, via: nil, asker: nil)
        let linked = capable(holder, author)
        _ = step(&exchange, linked, at: 0)
        send(&exchange, at: 0)
        answer(&exchange, holder, have: photo, load: 0, at: 0)
        answer(&exchange, author, have: photo, load: 1, at: 0)
        #expect(step(&exchange, linked, at: 0).asks.map(\.to) == [holder])
        let eta: Int64 = 180_000
        #expect(step(&exchange, linked, at: grace).query == [holder], "the first confirm")
        send(&exchange, at: grace)
        sending(&exchange, holder, eta: eta, at: grace)
        #expect(step(&exchange, linked, at: grace).wake == grace, "still sending: another grace")
        #expect(step(&exchange, linked, at: 2 * grace).query == [holder], "the second confirm")
        send(&exchange, at: 2 * grace)
        sending(&exchange, holder, eta: eta, at: 2 * grace)
        let until = 2 * grace + eta + BlobExchange.holdSlackMilliseconds
        let held = step(&exchange, linked, at: 2 * grace + wait)
        let floor = until - (2 * grace + wait)
        #expect(held.asks.isEmpty && held.wake == floor, "held to the promise and its slack, not to our ask's floor")
        #expect(held.notes == ["blob hold \(photo.string.prefix(8))… on \(holder) (sending), floor \(floor) ms"])
        #expect(step(&exchange, linked, at: memo + 1).asks.isEmpty, "past our ask's own floor, still held")
        #expect(step(&exchange, linked, at: until - 1).asks.isEmpty)
        #expect(exchange.counts.fallbacks == 0)
        let spent = step(&exchange, linked, at: until)
        #expect(spent.notes.contains("blob fallback \(photo.string.prefix(8))… \(holder) (floor) → next"), "the promise is spent")
        #expect(exchange.counts.fallbacks == 1)
    }

    @Test func aHolderOnlyWaitedOnThatSaysWhenOurCopyLandsIsHeldToThat() {
        // No ask of ours stands on it, so there is no floor, but its answer is a promise: `hold` takes the later of the
        // two, and here there is only the promise.
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, author: nil, via: nil, asker: nil)
        let linked = capable(holder, author)
        _ = step(&exchange, linked, at: 0)
        sending(&exchange, holder, eta: 60_000, at: 10)
        answer(&exchange, author, have: photo, load: 1, at: 10)
        #expect(step(&exchange, linked, at: 10).notes.first?.hasPrefix("blob wait") == true)
        #expect(step(&exchange, linked, at: 10 + grace).query == [holder], "the first confirm")
        sending(&exchange, holder, eta: 60_000, at: 20 + grace)
        #expect(step(&exchange, linked, at: 20 + grace).asks.isEmpty, "still sending: another grace")
        #expect(step(&exchange, linked, at: 20 + 2 * grace).query == [holder], "the second confirm")
        sending(&exchange, holder, eta: 60_000, at: 30 + 2 * grace)
        let held = step(&exchange, linked, at: 30 + 2 * grace)
        let floor = 60_000 + BlobExchange.holdSlackMilliseconds
        #expect(held.asks.isEmpty, "the author is not asked while the holder's promise stands")
        #expect(held.notes == ["blob hold \(photo.string.prefix(8))… on \(holder) (sending), floor \(floor) ms"])
    }

    @Test func onlyASendingAnswerPromisesAndNoPromiseRunsPastTheCap() {
        // `etaAt`: an eta rides SENDING alone, a negative one is no promise, and a holder's lie costs at most 15 min.
        let cap = BlobExchange.holdCapMilliseconds
        #expect(BlobExchange.etaAt(BlobHasItem(hash: "h", state: .have, size: 1, eta: 1000), now: 5) == nil)
        #expect(BlobExchange.etaAt(BlobHasItem(hash: "h", state: .sending, size: 1), now: 5) == nil)
        #expect(BlobExchange.etaAt(BlobHasItem(hash: "h", state: .sending, size: 1, eta: -1), now: 5) == nil)
        #expect(BlobExchange.etaAt(BlobHasItem(hash: "h", state: .sending, size: 1, eta: 1000), now: 5) == 1005)
        #expect(BlobExchange.etaAt(BlobHasItem(hash: "h", state: .sending, size: 1, eta: .max), now: 5) == 5 + cap)
    }

    @Test func theWaitForAnAnswerStretchesToTheNeighboursLastRoundTrip() {
        let first = BlobHash(of: Array("first".utf8))
        let second = BlobHash(of: Array("second".utf8))
        let third = BlobHash(of: Array("third".utf8))
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(first, now: 0, author: nil, via: nil, asker: nil)
        _ = exchange.decide(first, among: capable(holder), now: 0)
        send(&exchange, at: 0)
        answer(&exchange, holder, have: first, load: 0, at: 20_000)
        #expect(exchange.queryWait(for: holder) == 20_000 + wait)
        _ = exchange.recordWant(second, now: 20_000, author: nil, via: nil, asker: nil)
        _ = exchange.decide(second, among: capable(holder), now: 20_000)
        send(&exchange, at: 20_000)
        #expect(exchange.decide(second, among: capable(holder), now: 35_000).asks.isEmpty, "15 s is inside its lag")
        let blind = exchange.decide(second, among: capable(holder), now: 45_000)
        #expect(blind.asks == [BlobExchange.Ask(to: holder, line: .first)], "past the round trip and the wait")
        #expect(blind.wake == grace + 20_000, "and the blind ask's grace gains the round trip too")
        exchange.linked([holder])
        #expect(exchange.queryWait(for: holder) == wait, "a new link, a new queue: the lag is forgotten")
        _ = exchange.recordWant(third, now: 45_000, author: nil, via: nil, asker: nil)
        _ = exchange.decide(third, among: capable(holder), now: 45_000)
        let plain = exchange.decide(third, among: capable(holder), now: 45_000 + wait)
        #expect(plain.asks == [BlobExchange.Ask(to: holder, line: .first)])
    }

    @Test func aRoundTripStretchesTheWaitOnlyUpToItsCap() {
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, author: nil, via: nil, asker: nil)
        _ = step(&exchange, capable(holder), at: 0)
        send(&exchange, at: 0)
        answer(&exchange, holder, have: photo, load: 0, at: 60_000)
        #expect(exchange.queryWait(for: holder) == BlobExchange.queryWaitCapMilliseconds)
        #expect(exchange.grace(for: holder) == grace + BlobExchange.queryWaitCapMilliseconds)
        #expect(exchange.queryWait(for: author) == wait && exchange.grace(for: author) == grace, "no answer yet, no stretch")
    }

    @Test func roundTripsAreKeptForAsManyNeighboursAsAnswerBudgets() {
        var trips = AnswerRoundTrips()
        let peers = (1...(AnswerBudget.maxPeers + 1)).map { TestPeer(seed: $0).nodeId }
        for (index, peer) in peers.enumerated() {
            trips.record(peer, Int64(index))
        }
        #expect(trips[peers[0]] == nil, "the one answered longest ago is dropped")
        #expect(trips[peers[1]] == 1)
        trips.record(peers[1], -5)
        #expect(trips[peers[1]] == 0, "a clock that ran back counts as no lag")
        trips.forget([peers[1]])
        #expect(trips[peers[1]] == nil)
    }
}
