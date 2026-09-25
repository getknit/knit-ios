import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// Recovering a missing key hop by hop, ported from knit-next's `KeyExchangeTest`.
@Suite struct KeyExchangeTests {
    private let me = fixtureNodeId(1)
    private let wanted = fixtureNodeId(2)
    private let neighbor = fixtureNodeId(3)

    /// The `n`th of many distinct node ids; `fixtureNodeId` wraps at 256 seeds.
    private func nodeId(_ n: Int) -> NodeId {
        guard let id = NodeId(bytes: [0xAB, UInt8(n >> 8), UInt8(n & 0xFF)] + Array(repeating: 0, count: 13)) else {
            fatalError("any 16 bytes are a node id")
        }
        return id
    }

    private func profile(_ seed: UInt8) -> WireEnvelope {
        WireEnvelope(sig: [seed], signed: [seed, seed])
    }

    @Test func aWantAsksNowThenWaitsOutTheCooldown() {
        var exchange = KeyExchange()
        let first = exchange.want(wanted, me: me, now: 0)
        let repeated = exchange.want(wanted, me: me, now: 29_999)
        let afterCooldown = exchange.want(wanted, me: me, now: 30_000)
        #expect(first)
        #expect(!repeated)
        #expect(afterCooldown)
        #expect(exchange.missingIds == [wanted])
    }

    @Test func ourOwnKeyAndAHeldKeyAreNeverWanted() {
        var exchange = KeyExchange()
        _ = exchange.onProfilePinned(wanted, wire: profile(1))
        let own = exchange.want(me, me: me, now: 0)
        let held = exchange.want(wanted, me: me, now: 0)
        #expect(!own && !held)
        #expect(exchange.missingIds.isEmpty)
    }

    @Test func aHolderServesTheCachedProfilePointToPoint() {
        var exchange = KeyExchange()
        let cached = profile(7)
        _ = exchange.onProfilePinned(wanted, wire: cached)
        let answer = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        #expect(answer.serve == [WireEnvelope(relay: false, sig: cached.sig, signed: cached.signed)])
        #expect(answer.ask.isEmpty)
        #expect(exchange.cachedProfile(of: wanted) == cached)
    }

    @Test func aNonHolderAsksOnTheRequestersBehalfAndServesItLater() {
        var exchange = KeyExchange()
        let answer = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        #expect(answer.serve.isEmpty)
        #expect(answer.ask == [wanted])
        let waiting = exchange.onProfilePinned(wanted, wire: profile(4))
        #expect(waiting == [neighbor])
        #expect(exchange.missingIds.isEmpty, "the want is settled")
        let again = exchange.onProfilePinned(wanted, wire: profile(4))
        #expect(again.isEmpty, "each wanter is served once")
    }

    @Test func aRequestSkipsOurOwnIdTheCapAndAnythingNotANodeId() {
        var exchange = KeyExchange()
        let flood = (0..<200).map { nodeId($0).string }
        let answer = exchange.onRequest([me.string, "not-a-node-id"] + flood, from: neighbor, me: me, now: 0)
        #expect(answer.ask.count == KeyExchange.maxRequestIds - 2)
        #expect(!answer.ask.contains(me))
    }

    @Test func theWantedListEvictsItsOldestPastTheCap() {
        var exchange = KeyExchange()
        for n in 0...KeyExchange.maxMissing {
            _ = exchange.want(nodeId(n), me: me, now: 0)
        }
        #expect(exchange.missingIds.count == KeyExchange.maxMissing)
        #expect(exchange.missingIds.first == nodeId(1))
    }

    @Test func theWantersListEvictsItsOldestPastTheCap() {
        var exchange = KeyExchange()
        let ids = (0...KeyExchange.maxWanters).map(nodeId)
        for id in ids {
            _ = exchange.onRequest([id.string], from: neighbor, me: me, now: 0)
        }
        let dropped = exchange.onProfilePinned(ids[0], wire: profile(1))
        let kept = exchange.onProfilePinned(ids[1], wire: profile(1))
        #expect(dropped.isEmpty, "the oldest relayed want was dropped")
        #expect(kept == [neighbor])
    }

    @Test func theSweepDropsOnlyStaleWants() {
        var exchange = KeyExchange()
        _ = exchange.want(wanted, me: me, now: 0)
        _ = exchange.want(neighbor, me: me, now: 80)
        let swept = exchange.sweep(now: KeyExchange.missingMilliseconds + 1)
        #expect(swept == 1)
        #expect(exchange.missingIds == [neighbor])
    }

    @Test func requestsAreChunkedToTheirCap() {
        let ids = (0..<300).map(nodeId)
        let chunks = KeyExchange.chunked(ids)
        #expect(chunks.map(\.count) == [128, 128, 44])
        #expect(chunks.flatMap(\.self) == ids)
        #expect(KeyExchange.chunked([]).isEmpty)
    }

    @Test func twoNeighboursWaitingForOneKeyAreBothServed() {
        var exchange = KeyExchange()
        let other = fixtureNodeId(4)
        let first = exchange.onRequest([wanted.string], from: neighbor, me: me, now: 0)
        let second = exchange.onRequest([wanted.string], from: other, me: me, now: 1)
        #expect(first.ask == [wanted])
        #expect(second.ask.isEmpty, "inside the cooldown")
        let waiting = exchange.onProfilePinned(wanted, wire: profile(2))
        #expect(waiting == [neighbor, other])
    }
}
