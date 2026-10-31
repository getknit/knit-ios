import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// The bound on ``KeyExchange``'s profile cache (ADR 2026-10.r88m), beside ``KeyExchangeTests``'s
/// `aHolderWhoseCacheARestartEmptiedAnswersFromItsPinStore`: past ``KeyExchange/maxCachedProfiles`` the least recently
/// pinned or served profile is dropped, and the pin store answers for it at its next miss.
@Suite struct KeyExchangeCacheTests {
    private let me = fixtureNodeId(1)
    private let neighbor = fixtureNodeId(3)
    private let bound = KeyExchange.maxCachedProfiles

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

    @Test func theBoundIsOneThousandAndTwentyFour() {
        #expect(bound == 1024)
    }

    @Test func theCacheHoldsAtMostItsBoundAndDropsTheLeastRecentlyUsedFirst() {
        var exchange = KeyExchange()
        for n in 0..<bound {
            _ = exchange.onProfilePinned(nodeId(n), wire: profile(UInt8(n & 0xFF)), now: 0)
        }
        #expect(exchange.cachedProfileCount == bound)
        // Serving the oldest makes it the most recently used, so the next pin drops the second oldest instead.
        #expect(exchange.serveKey(nodeId(0)) != nil)
        _ = exchange.onProfilePinned(nodeId(bound), wire: profile(1), now: 0)
        #expect(exchange.cachedProfileCount == bound)
        #expect(exchange.cachedProfile(of: nodeId(0)) != nil, "served last, so kept")
        #expect(exchange.cachedProfile(of: nodeId(1)) == nil, "the least recently used went first")
        #expect(exchange.cachedProfile(of: nodeId(bound)) != nil)
        // A read leaves the order alone: looking at the next oldest does not save it.
        #expect(exchange.cachedProfile(of: nodeId(2)) != nil)
        for n in (bound + 1)...(bound + 10) {
            _ = exchange.onProfilePinned(nodeId(n), wire: profile(1), now: 0)
        }
        #expect(exchange.cachedProfileCount == bound)
        #expect((2...11).allSatisfy { exchange.cachedProfile(of: nodeId($0)) == nil })
        #expect(exchange.cachedProfile(of: nodeId(12)) != nil)
        #expect(exchange.cachedProfile(of: nodeId(0)) != nil)
    }

    @Test func aPinAgainReplacesItsProfileAndMakesItTheNewest() {
        var exchange = KeyExchange()
        for n in 0..<bound {
            _ = exchange.onProfilePinned(nodeId(n), wire: profile(1), now: 0)
        }
        _ = exchange.onProfilePinned(nodeId(0), wire: profile(2), now: 0)
        _ = exchange.onProfilePinned(nodeId(bound), wire: profile(1), now: 0)
        #expect(exchange.cachedProfileCount == bound)
        #expect(exchange.cachedProfile(of: nodeId(0)) == profile(2), "the newer profile, kept")
        #expect(exchange.cachedProfile(of: nodeId(1)) == nil)
    }

    @Test func aProfileTheCacheDroppedIsServedAgainFromThePinStore() {
        // Every pin keeps its signed frame in the pin store (knit-next ADR 2026-09.g64k), so a profile the bound dropped
        // answers the next request from there, asks nobody, and is cached again.
        let first = nodeId(0)
        let kept = profile(9)
        var exchange = KeyExchange { [first] in $0 == first ? kept : nil }
        _ = exchange.onProfilePinned(first, wire: kept, now: 0)
        for n in 1...bound {
            _ = exchange.onProfilePinned(nodeId(n), wire: profile(1), now: 0)
        }
        #expect(exchange.cachedProfile(of: first) == nil, "dropped past the bound")
        let answer = exchange.onRequest([first.string], from: neighbor, me: me, now: 0)
        #expect(answer.serve == [WireEnvelope(relay: false, sig: kept.sig, signed: kept.signed)])
        #expect(answer.ask.isEmpty)
        #expect(exchange.missingIds.isEmpty)
        #expect(exchange.cachedProfile(of: first) == kept)
        #expect(exchange.cachedProfileCount == bound)
        #expect(exchange.cachedProfile(of: nodeId(1)) == nil, "and the least recently used made room for it")
    }
}
