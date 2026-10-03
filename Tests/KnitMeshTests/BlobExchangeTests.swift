import KnitWire
import Testing

@testable import KnitMesh

/// The blob exchange's books, ported from knit-next's `BlobExchangeTest`: a blob is wanted once, the wants and the
/// serve memo are bounded, and both age out.
@Suite struct BlobExchangeTests {
    private let alice = TestPeer(seed: 1).nodeId
    private let bob = TestPeer(seed: 2).nodeId

    private func hash(_ index: Int) -> BlobHash {
        BlobHash(digest: (0..<32).map { UInt8(truncatingIfNeeded: index >> ($0 % 4 * 8)) }) ?? .empty
    }

    @Test func aBlobIsWantedOnceAndARefreshKeepsItsPlace() {
        var exchange = BlobExchange()
        let first = exchange.want(hash(1), now: 0)
        let second = exchange.want(hash(2), now: 0)
        let again = exchange.want(hash(1), now: 5)
        #expect(first && second)
        #expect(!again, "already wanted: no second broadcast")
        #expect(exchange.wanted == [hash(1), hash(2)], "a refresh keeps the order it was first wanted in")
        #expect(exchange.isWanted(hash(2)))
        exchange.forget(hash(1))
        #expect(exchange.wanted == [hash(2)])
    }

    @Test func theOldestWantGoesWhenTheSetIsFull() {
        var exchange = BlobExchange()
        for index in 0...BlobExchange.maxWanted {
            _ = exchange.want(hash(index), now: Int64(index))
        }
        #expect(exchange.wanted.count == BlobExchange.maxWanted)
        #expect(!exchange.isWanted(hash(0)))
        #expect(exchange.isWanted(hash(BlobExchange.maxWanted)))
    }

    @Test func aWantNobodyRefreshedAgesOut() {
        var exchange = BlobExchange()
        _ = exchange.want(hash(1), now: 0)
        _ = exchange.want(hash(2), now: 0)
        _ = exchange.want(hash(2), now: 600_000)
        let early = exchange.sweep(now: BlobExchange.wantMilliseconds)
        let late = exchange.sweep(now: BlobExchange.wantMilliseconds + 1)
        #expect(early == 0, "only past the TTL")
        #expect(late == 1)
        #expect(exchange.wanted == [hash(2)])
    }

    @Test func aServeHoldsOffASecondCopyToThatNeighbourForTheMemo() {
        var exchange = BlobExchange()
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
        var exchange = BlobExchange()
        let first = exchange.shouldServe(hash(1), to: bob, now: 0)
        exchange.forgetServe(hash(1), to: bob)
        let again = exchange.shouldServe(hash(1), to: bob, now: 1)
        #expect(first && again)
    }

    @Test func theServeMemoIsBounded() {
        var exchange = BlobExchange()
        for index in 0...BlobExchange.maxServeMemo {
            _ = exchange.shouldServe(hash(index), to: bob, now: 0)
        }
        #expect(exchange.servedCount == BlobExchange.maxServeMemo)
        let oldest = exchange.shouldServe(hash(0), to: bob, now: 0)
        #expect(oldest, "the oldest serve was forgotten")
    }
}
