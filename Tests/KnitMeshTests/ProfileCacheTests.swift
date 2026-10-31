import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The bounded cache under ``KeyExchange`` (ADR 2026-10.r88m): least recently used first, whichever end of its list an
/// entry is touched from.
@Suite struct ProfileCacheTests {
    private let ids = (1...6).map { fixtureNodeId($0) }

    private func profile(_ seed: UInt8) -> WireEnvelope {
        WireEnvelope(sig: [seed], signed: [seed])
    }

    /// The ids held, in `ids`' order.
    private func held(_ cache: ProfileCache) -> [NodeId] {
        ids.filter(cache.contains)
    }

    @Test func aMiddleOrOldestEntryTouchedMovesToTheNewestEnd() {
        var cache = ProfileCache(capacity: 3)
        for (index, id) in ids.prefix(3).enumerated() {
            cache.set(profile(UInt8(index)), for: id)
        }
        // The middle one, then the oldest: each becomes the newest.
        #expect(cache.use(ids[1]) == profile(1))
        #expect(cache.use(ids[0]) == profile(0))
        #expect(cache.use(ids[0]) == profile(0), "the newest touched again stays where it is")
        cache.set(profile(3), for: ids[3])
        #expect(held(cache) == [ids[0], ids[1], ids[3]], "the third, untouched, went first")
        cache.set(profile(4), for: ids[4])
        #expect(held(cache) == [ids[0], ids[3], ids[4]], "then the middle one touched first")
        #expect(cache.use(ids[1]) == nil && cache.count == 3)
        // The eviction left the first id oldest: touched now, it outlives the third.
        #expect(cache.use(ids[0]) == profile(0))
        cache.set(profile(5), for: ids[5])
        #expect(held(cache) == [ids[0], ids[4], ids[5]], "the oldest after an eviction moves when touched")
    }

    @Test func aReplacedEntryIsTheNewestAndACapacityBelowOneIsOne() {
        var cache = ProfileCache(capacity: 0)
        #expect(cache.capacity == 1)
        cache.set(profile(1), for: ids[0])
        cache.set(profile(2), for: ids[0])
        #expect(cache.peek(ids[0]) == profile(2) && cache.count == 1)
        cache.set(profile(3), for: ids[1])
        #expect(held(cache) == [ids[1]])
    }
}
