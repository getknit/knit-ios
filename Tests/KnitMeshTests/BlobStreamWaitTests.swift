import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// A fetch waiting on a holder that streams us another file (`streamWait`, knit-next `79f38d3d` and `09f70b3e`):
/// `BlobExchangeTest`'s stream cases. `InteropAuditMeshTests` has the drop and the idle holder; these are the rest.
@Suite struct BlobStreamWaitTests {
    private let author = TestPeer(seed: 2).nodeId
    private let holder = TestPeer(seed: 3).nodeId
    private let photo = BlobHash(of: Array("a photo".utf8))
    private let recheck = BlobExchange.fetchingRecheckMilliseconds

    private func send(_ exchange: inout BlobExchange, at now: Int64) {
        for query in exchange.takeQueries() {
            exchange.noteQuerySent("\(query.peer)@\(now)", to: query.peer, hashes: query.hashes, now: now)
        }
    }

    private func answer(_ exchange: inout BlobExchange, _ peer: NodeId, _ state: BlobHolding, load: Int = 0, at now: Int64) {
        let latest = exchange.sentQueries.values.filter { $0.peer == peer }.max { $0.at < $1.at }
        let item = BlobHasItem(hash: photo.string, state: state, size: state.isHeld ? 1000 : nil)
        let re = latest.map { "\($0.peer)@\($0.at)" }
        _ = exchange.recordAnswers(BlobHasContent(items: [item], load: load, re: re), from: peer, now: now)
    }

    /// The author asked, then streaming us another file with `left` ms to go, beside a quiet `holder`.
    private func linked(left: Int64?) -> [BlobExchange.Candidate] {
        [
            BlobExchange.Candidate(id: author, streaming: left != nil, capable: true, streamLeftMilliseconds: left),
            BlobExchange.Candidate(id: holder, streaming: false, capable: true),
        ]
    }

    /// A fetch on the author, which said HAVE, beside a holder that said `state`.
    private func asked(_ state: BlobHolding, load: Int = 0) -> BlobExchange {
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, author: author, via: nil, asker: nil)
        _ = exchange.decide(photo, among: linked(left: nil), now: 0)
        send(&exchange, at: 0)
        answer(&exchange, author, .have, at: 100)
        answer(&exchange, holder, state, load: load, at: 100)
        _ = exchange.decide(photo, among: linked(left: nil), now: 100)
        return exchange
    }

    @Test func aNeighbourThatLackedTheBlobIsQueriedAgainWhileStuckWithoutSpendingAPullRecheck() {
        // `lackedWhileStuck`: the P8 sat 8 min behind a DM file while the P9 held the photo idle (knit-next 09f70b3e).
        var exchange = asked(.notHeld)
        #expect(exchange.wants[photo]?.fetch?.peer == author)
        #expect(exchange.decide(photo, among: linked(left: 60_000), now: 1000).query.isEmpty, "not yet due")
        let due = exchange.decide(photo, among: linked(left: 60_000), now: recheck - BlobExchange.timerCoalesceMilliseconds)
        #expect(due.query == [holder], "a recheck after its NONE's query, the timer's window early")
        #expect(exchange.wants[photo]?.pullRechecks[holder, default: 0] == 0, "not counted against PULL_RECHECKS")
        send(&exchange, at: recheck)
        answer(&exchange, holder, .have, at: recheck + 100)
        #expect(
            exchange.decide(photo, among: linked(left: 50_000), now: recheck + 100).asks == [BlobExchange.Ask(to: holder, line: .fetch)])
    }

    @Test func aStreamWithThirtySecondsLeftOrLessRechecksNobody() {
        var exchange = asked(.notHeld)
        let plan = exchange.decide(photo, among: linked(left: BlobExchange.streamSwitchMilliseconds), now: recheck)
        #expect(plan.query.isEmpty && plan.asks.isEmpty)
        #expect(plan.wake == BlobExchange.streamPollMilliseconds)
    }

    @Test func aHolderFeedingSomeoneElseIsNotIdle() {
        var exchange = asked(.have, load: 1)
        #expect(exchange.wants[photo]?.fetch?.peer == author)
        let plan = exchange.decide(photo, among: linked(left: 60_000), now: 1000)
        #expect(plan.asks.isEmpty, "load 1: it feeds something, so our copy would wait there too")
        #expect(exchange.counts.fallbacks == 0)
    }

    @Test func aStreamWhoseTimeLeftIsUnknownIsWaitedOut() {
        var exchange = asked(.notHeld)
        let unknown = [
            BlobExchange.Candidate(id: author, streaming: true, capable: true),
            BlobExchange.Candidate(id: holder, streaming: false, capable: true),
        ]
        let plan = exchange.decide(photo, among: unknown, now: recheck)
        #expect(plan.asks.isEmpty && plan.wake == BlobExchange.streamPollMilliseconds)
    }
}
