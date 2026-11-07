import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// ``KeyChurnLimiter`` (knit-next ADR 2026-11.xp6d, step 5a obligation 6; ADR 2026-11.sv5t), ported case for case from
/// `KeyChurnLimiterTest.kt` at `cad69c77b`: a contact streaming key generations costs the resolver a bounded number of
/// HMACs, the newest listing applies once the window frees, and nothing is ever held from being unlisted.
@Suite struct KeyChurnLimiterTests {
    private let bob = BlindFixture.id("bob")
    private let carol = BlindFixture.id("carol")
    private var fixture = BlindFixture()

    private mutating func keys(_ count: Int) -> [PresenceKey] {
        (0..<count).map { _ in fixture.key() }
    }

    private static func list(_ aliases: AdvertAliases<String>, _ listing: [NodeId: [PresenceKey]]) {
        aliases.setKeys(listing.compactMapValues { ExpectedTagTable.ContactKey(keys: $0) })
    }

    @Test mutating func aContactStreamingAThousandGenerationsCostsAtMost420HmacsPerMinuteAndTheNewestApplies() throws {
        let clocks = BlindClocks()
        clocks.now = 0
        let aliases = clocks.aliases(String.self)
        var limiter = KeyChurnLimiter()
        var newest: [PresenceKey] = []
        var windowStart: Int64 = 0
        var windowHmacs = aliases.counters.tableHmacs
        for _ in 0..<1000 {
            newest = keys(3)
            if let listing = limiter.offer([bob: newest], now: clocks.now) {
                Self.list(aliases, listing)
            }
            if let listing = limiter.release(now: clocks.now) {
                Self.list(aliases, listing)
            }
            clocks.now += 1000
            if clocks.now - windowStart >= KeyChurnLimiter.minIntervalMilliseconds {
                let spent = aliases.counters.tableHmacs - windowHmacs
                #expect(spent <= 420, "spent \(spent) in a minute")
                windowStart = clocks.now
                windowHmacs = aliases.counters.tableHmacs
            }
        }
        // The window frees: the newest listing held applies, never the first held.
        let due = try #require(limiter.nextDueAt())
        let applied = required(limiter.release(now: max(clocks.now, due)))
        Self.list(aliases, applied)
        let first = required(newest.first)
        let tag = BlindFixture.tag(first, owner: bob, slot: BlindTag.slotOf(wallMilliseconds: clocks.wall))
        #expect(aliases.resolve(BlindFixture.blinded(tag)).answer?.nodeId == bob)
        #expect(limiter.held + limiter.coalesced > 0)
    }

    @Test mutating func aContactThatDropsOutAndComesBackIsStillHeldToOneGainAMinute() {
        // A contact gone from the listing, then back with a fresh key.
        var limiter = KeyChurnLimiter()
        #expect(limiter.offer([bob: keys(1)], now: 0) != nil)
        #expect(limiter.offer([:], now: 1000)?.isEmpty == true, "unlisted at once")
        let back = keys(1)
        #expect(limiter.offer([bob: back], now: 2000) == nil, "its return is a gain inside its window: held")
        #expect(limiter.nextDueAt() == 60_000)
        #expect(limiter.release(now: 60_000)?[bob] == back)
        // A day on, a contact that left starts afresh.
        _ = limiter.offer([:], now: 70_000)
        #expect(limiter.offer([bob: keys(1)], now: 70_000 + KeyChurnLimiter.dayMilliseconds) != nil)
    }

    @Test mutating func aRemovalAKeyDroppedAndAnUnlistedContactApplyAtOnce() {
        var limiter = KeyChurnLimiter()
        let held = keys(2)
        #expect(limiter.offer([bob: held, carol: keys(1)], now: 0) != nil)
        // Inside the window: a dropped key still applies.
        #expect(limiter.offer([bob: [held[0]], carol: keys(1)], now: 1000)?[bob] == [held[0]])
        // A contact leaving the direct contacts is unlisted at once.
        #expect(limiter.offer([bob: [held[0]]], now: 2000).map { Set($0.keys) } == [bob])
    }

    @Test mutating func aChangeThatDropsAndGainsDropsAtOnceAndHoldsTheGain() {
        var limiter = KeyChurnLimiter()
        let listed = keys(3)
        _ = limiter.offer([bob: [listed[0], listed[1]]], now: 0)
        #expect(limiter.offer([bob: [listed[2], listed[0]]], now: 1000)?[bob] == [listed[0]], "b dropped at once, c held")
        #expect(limiter.release(now: 30_000) == nil, "nothing new until the window frees")
        #expect(limiter.release(now: 60_000)?[bob] == [listed[2], listed[0]])
        #expect(limiter.held == 1)
    }

    @Test mutating func aDailyCapHoldsPastIt() {
        var limiter = KeyChurnLimiter(minIntervalMilliseconds: 1, dailyCap: 3, dayMilliseconds: 1_000_000)
        var listed: [PresenceKey] = []
        var now: Int64 = 0
        for _ in 0..<3 {
            listed = keys(1) + listed
            #expect(limiter.offer([bob: listed], now: now) != nil)
            now += 10
        }
        #expect(limiter.offer([bob: keys(1) + listed], now: now) == nil, "the fourth gain in a day waits")
        #expect(limiter.nextDueAt() == 1_000_000)
    }

    @Test mutating func twentyFiveSameKeyReEntriesInADayAreEachListedWithinTheInterval() throws {
        // A flap that brings a contact back with the keys it had is a relisting, never a gain.
        var limiter = KeyChurnLimiter()
        let held = keys(2)
        var now: Int64 = 0
        #expect(limiter.offer([bob: held], now: now) != nil)
        for entry in 1...25 {
            now += 50 * 60_000 // an hour less ten minutes: 25 in a day
            #expect(limiter.offer([:], now: now) != nil, "leaving is never delayed")
            now += 1000
            var listed = limiter.offer([bob: held], now: now)
            if listed == nil {
                let due = try #require(limiter.nextDueAt())
                #expect(due - now <= KeyChurnLimiter.minIntervalMilliseconds)
                listed = limiter.release(now: due)
            }
            #expect(listed?[bob]?.count == 2, "re-entry \(entry) listed")
        }
    }

    @Test mutating func aReEntryInsideTheIntervalWaitsForItButNotForTheDailyCap() {
        var limiter = KeyChurnLimiter()
        let held = keys(1)
        let interval = KeyChurnLimiter.minIntervalMilliseconds
        #expect(limiter.offer([bob: held], now: 0) != nil)
        #expect(limiter.offer([:], now: 1000) != nil)
        #expect(limiter.offer([bob: held], now: 2000) == nil, "inside the interval: held")
        #expect(limiter.nextDueAt() == interval)
        #expect(limiter.release(now: interval) != nil)
        // A re-entry with a key it never had is a gain, under the interval and the cap as before.
        #expect(limiter.offer([:], now: interval + 1) != nil)
        #expect(limiter.offer([bob: keys(1)], now: interval + 2) == nil)
    }
}
