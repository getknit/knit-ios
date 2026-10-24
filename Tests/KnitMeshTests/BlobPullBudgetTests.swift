import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// The pull-through's hop budget, one engine's books at a time (knit-next ADR 2026-10.2drc, ADR 2026-10.8hek), ported from
/// `BlobHolderQueryTest`'s budget, echo and newcomer cases: an echo wants a blob with one hop less than its ask allowed, an
/// ask keeps a want alive only when it carries at least the want's own budget, a want of our own takes the whole budget
/// back, nothing echoes past its deadline, and a newcomer is pulled at once, once per link-up. The two-engine cases are
/// ``BlobPullBudgetLabTests``.
@Suite struct BlobPullBudgetTests {
    private let alice = TestPeer(seed: 1).nodeId
    private let bob = TestPeer(seed: 2).nodeId
    private let carol = TestPeer(seed: 3).nodeId
    private let newcomer = TestPeer(seed: 6).nodeId
    private let photo = BlobHash(of: Array("a photo".utf8))
    private let ttl = BlobExchange.wantMilliseconds
    private let cycle = BlobExchange.cycleMilliseconds

    private func capable(_ ids: NodeId...) -> [BlobExchange.Candidate] {
        ids.map { BlobExchange.Candidate(id: $0, streaming: false, capable: true) }
    }

    private func step(_ exchange: inout BlobExchange, _ linked: [BlobExchange.Candidate], at now: Int64) -> BlobExchange.Plan {
        exchange.decide(photo, among: linked, now: now, wall: wallAt(now))
    }

    private func answer(_ exchange: inout BlobExchange, _ peer: NodeId, _ state: BlobHolding, at now: Int64) {
        _ = exchange.recordAnswers(BlobHasContent(items: [BlobHasItem(hash: photo.string, state: state)]), from: peer, now: now)
    }

    /// `asker` asks us at `now` to pull the photo through, allowing `pull` and naming `until`.
    private func asked(_ exchange: inout BlobExchange, by asker: NodeId, pull: Int?, until: Int64? = nil, at now: Int64) {
        _ = exchange.recordWant(
            photo, now: now, wall: wallAt(now), author: nil, via: nil, asker: asker, reach: .asked(pull: pull, until: until))
    }

    /// A want of our own at `now`.
    private func own(_ exchange: inout BlobExchange, at now: Int64, until: Int64? = nil) {
        _ = exchange.recordWant(
            photo, now: now, wall: wallAt(now), author: nil, via: nil, asker: nil, reach: .own(until: until, rederived: true))
    }

    /// A step at `now` in which every one of `linked` that is queried says it lacks the blob, and the step its answers make.
    private func lacking(_ exchange: inout BlobExchange, _ linked: [BlobExchange.Candidate], at now: Int64) -> BlobExchange.Plan {
        let first = step(&exchange, linked, at: now)
        for peer in first.query {
            answer(&exchange, peer, .notHeld, at: now)
        }
        return step(&exchange, linked, at: now)
    }

    @Test func anEchoWantsTheBlobWithOneHopLessAndTheLastRingOnlyQueries() {
        // `eachRingSpendsAHopOfTheBudgetAndTheLastOneOnlyQueries`, ring by ring: asked with 3 it pulls with 2, with 2 it
        // pulls with 1, and with 1 it wants the blob at 0, which queries and fetches but asks nobody to pull it.
        for (pull, budget) in [(3, 2), (2, 1), (7, 2)] {
            var exchange = BlobExchange(queriesHolders: true)
            asked(&exchange, by: alice, pull: pull, at: 0)
            let plan = lacking(&exchange, capable(alice, bob), at: 0)
            #expect(plan.asks == [BlobExchange.Ask(to: bob, line: .pull)] && plan.pull == budget, "asked with \(pull)")
        }
        var last = BlobExchange(queriesHolders: true)
        asked(&last, by: alice, pull: 1, at: 0)
        let plan = lacking(&last, capable(alice, bob), at: 0)
        #expect(plan.asks.isEmpty && last.counts.pullsWithheld == 1, "at 0 it only queries")
        #expect(plan.notes == ["blob no-pull \(photo.string.prefix(8))… → nobody of \(bob) (fetch only)"])
    }

    @Test func anAskWithNoFieldIsAFetchOnlyAndOneWithNoneLeftMakesNoWant() {
        // `anAskWithNoBudgetFieldIsAFetchOnlyAndOneWithNoneLeftIsServedOnly`, the books' half: the engine's serve is
        // `MeshEngineBlobTests`'.
        #expect(BlobExchange.budgetOf(nil) == 0, "an ask from a build before the field counts as 1")
        #expect(BlobExchange.budgetOf(1) == 0 && BlobExchange.budgetOf(0) == -1)
        #expect(BlobExchange.echoRefusal(pull: nil, until: nil, wall: wallAt(0)) == nil, "a fetch-only want is made")
        #expect(BlobExchange.echoRefusal(pull: 0, until: nil, wall: wallAt(0)) == "fetch only")
        // The smallest Kotlin `Int` less one is a plain negative here, never a wrap to the largest (ADR 2026-10.8hek).
        let smallest = Int(Int32.min)
        #expect(BlobExchange.budgetOf(smallest) == smallest - 1)
        #expect(BlobExchange.echoRefusal(pull: smallest, until: nil, wall: wallAt(0)) == "fetch only")
    }

    @Test func pastItsDeadlineAnAskMakesNoEchoAndAnEchoStopsPulling() {
        let deadline = wallAt(600_000)
        var exchange = BlobExchange(queriesHolders: true)
        asked(&exchange, by: alice, pull: 3, until: deadline, at: 0)
        let inside = lacking(&exchange, capable(alice, bob), at: 0)
        #expect(inside.asks == [BlobExchange.Ask(to: bob, line: .pull)], "inside the deadline, it pulls Bob through")
        #expect(inside.until == deadline, "and passes the deadline on")
        let past = lacking(&exchange, capable(alice, bob), at: 600_000)
        #expect(past.asks.isEmpty && exchange.counts.pullsWithheld == 1, "past it, it asks nobody to pull it")
        #expect(BlobExchange.echoRefusal(pull: 3, until: deadline, wall: wallAt(600_000)) == "past its deadline")
        #expect(BlobExchange.echoRefusal(pull: 3, until: deadline, wall: wallAt(599_999)) == nil)
    }

    @Test func anAskThatCarriesLessThanTheWantsBudgetNeverKeepsItAlive() {
        var exchange = BlobExchange(queriesHolders: true)
        asked(&exchange, by: alice, pull: 3, at: 0)
        #expect(exchange.wants[photo]?.budget == 2, "a root's pull: wanted with 2")
        var now: Int64 = 0
        var gone = false
        while !gone, now < ttl + 600_000 {
            now += 300_000
            // Swept first, read, then asked: a want an ask made again would read as one an ask kept.
            _ = exchange.sweep(now: now)
            gone = !exchange.isWanted(photo)
            if !gone {
                // Carol, an echo of ours, asks back with one hop less, and an older build with none at all.
                asked(&exchange, by: carol, pull: 2, at: now)
                asked(&exchange, by: bob, pull: nil, at: now)
            }
        }
        #expect(gone, "their asks never kept the root's echo alive")
        #expect(now <= ttl + 300_000, "it went within a sweep of its TTL: \(now) ms")
        // The root, still asking, keeps it.
        var kept = BlobExchange(queriesHolders: true)
        asked(&kept, by: alice, pull: 3, at: 0)
        for tick in Int64(1)...10 {
            _ = kept.sweep(now: tick * 300_000)
            #expect(kept.isWanted(photo), "a root's asks keep it (\(tick))")
            asked(&kept, by: alice, pull: 3, at: tick * 300_000)
        }
    }

    @Test func aLargerBudgetTakesTheAsksDeadlineAndAnEqualOneWidensIt() {
        var exchange = BlobExchange(queriesHolders: true)
        asked(&exchange, by: alice, pull: 2, until: wallAt(100), at: 0)
        asked(&exchange, by: bob, pull: 3, until: wallAt(50), at: 10)
        #expect(exchange.wants[photo]?.budget == 2 && exchange.wants[photo]?.until == wallAt(50), "more budget: its deadline")
        asked(&exchange, by: carol, pull: 3, until: wallAt(200), at: 20)
        #expect(exchange.wants[photo]?.until == wallAt(200), "as much: the later deadline")
        asked(&exchange, by: carol, pull: 3, until: wallAt(150), at: 30)
        #expect(exchange.wants[photo]?.until == wallAt(200), "never an earlier one")
        asked(&exchange, by: carol, pull: 3, until: nil, at: 40)
        #expect(exchange.wants[photo]?.until == nil, "none is the widest")
        asked(&exchange, by: carol, pull: 3, until: wallAt(300), at: 50)
        #expect(exchange.wants[photo]?.until == nil)
        #expect(exchange.wants[photo]?.wantedAt == 50, "each of them refreshed it")
    }

    @Test func aWantOfOurOwnTakesAnEchoBackToTheWholeBudget() {
        var exchange = BlobExchange(queriesHolders: true)
        asked(&exchange, by: alice, pull: 3, at: 0)
        #expect(lacking(&exchange, capable(alice, bob), at: 0).pull == 2, "an echo of Alice's: Bob is pulled with one less")
        own(&exchange, at: 10 * cycle)
        let plan = lacking(&exchange, capable(alice, bob), at: 10 * cycle)
        #expect(plan.asks.map(\.to) == [alice, bob] && plan.pull == BlobExchange.pullBudget, "a row of ours names it now: a root")
    }

    @Test func aNewcomerIsAskedToPullAtOnceOncePerLinkUpEvenDeepInTheBackoff() {
        var exchange = BlobExchange(queriesHolders: true)
        for tick in Int64(0)...60 {
            own(&exchange, at: tick * 60_000)
            _ = lacking(&exchange, capable(bob), at: tick * 60_000)
        }
        // An hour of dead cycles: the gap is 6 min, and the cycle that last opened pulled Bob already.
        let now: Int64 = 60 * 60_000 + 30_000
        let linked = capable(bob, newcomer)
        exchange.linked([newcomer])
        let pulled = lacking(&exchange, linked, at: now)
        #expect(pulled.asks == [BlobExchange.Ask(to: newcomer, line: .pull)] && pulled.why == "newcomer", "at once, mid-cycle")
        #expect(pulled.pull == BlobExchange.pullBudget)
        #expect(step(&exchange, linked, at: now + 1000).asks.isEmpty, "once per link-up")
        exchange.linked([newcomer])
        #expect(lacking(&exchange, linked, at: now + 2000).asks.map(\.to) == [newcomer], "a new link-up pulls it once more")
        // A newcomer whose answer comes only after its link went: its old link-up never pulls it later.
        let late = TestPeer(seed: 7).nodeId
        exchange.linked([late])
        #expect(step(&exchange, linked + capable(late), at: now + 3000).query == [late])
        exchange.unlinked([late])
        answer(&exchange, late, .notHeld, at: now + 4000)
        #expect(step(&exchange, linked + capable(late), at: now + 4000).asks.isEmpty, "an old link-up never fires later")
    }

    @Test func aNewcomerFromACycleThatClosedIsNotPulledInTheNext() {
        var exchange = BlobExchange(queriesHolders: true)
        _ = exchange.recordWant(photo, now: 0, wall: wallAt(0), author: nil, via: bob, asker: nil, reach: .own(until: nil, rederived: true))
        // Carol is fetching it: a lead, so nobody is pulled, and the newcomer is left in the cycle's newcomers.
        _ = step(&exchange, capable(bob, carol), at: 0)
        answer(&exchange, bob, .notHeld, at: 0)
        answer(&exchange, carol, .fetching, at: 0)
        exchange.linked([newcomer])
        let all = capable(bob, carol, newcomer)
        #expect(step(&exchange, all, at: 10_000).query == [carol, newcomer], "Carol's recheck, and the newcomer")
        answer(&exchange, carol, .fetching, at: 10_000)
        answer(&exchange, newcomer, .notHeld, at: 10_000)
        #expect(step(&exchange, all, at: 10_000).asks.isEmpty, "nobody pulled while a neighbour fetches it")
        // Carol walks off; the next cycle opens after one that saw a lead, so its first pull is the hop alone.
        exchange.unlinked([carol])
        let next = lacking(&exchange, capable(bob, newcomer), at: 10_000 + cycle)
        #expect(next.asks == [BlobExchange.Ask(to: bob, line: .pull)] && next.why == "via hop")
        #expect(step(&exchange, capable(bob, newcomer), at: 10_000 + cycle + 1000).asks.isEmpty, "the newcomer was the closed cycle's")
    }

    @Test func newcomersEveryFewMinutesCannotKeepAnEchoAlive() {
        var exchange = BlobExchange(queriesHolders: true)
        asked(&exchange, by: alice, pull: 3, at: 0)
        var now: Int64 = 0
        var round = 0
        while exchange.isWanted(photo), round < 20 {
            round += 1
            now += 240_000
            let stranger = TestPeer(seed: 20 + round).nodeId
            exchange.linked([stranger])
            let plan = lacking(&exchange, capable(stranger), at: now)
            #expect(plan.asks.count <= 1 && plan.pull == 2, "each newcomer is pulled at most once, with one hop less")
            // Its echo, with one hop less again, asks us back in its next cycle.
            asked(&exchange, by: stranger, pull: 1, at: now + 2 * cycle)
            exchange.unlinked([stranger])
            _ = exchange.sweep(now: now + 2 * cycle)
        }
        #expect(!exchange.isWanted(photo), "the echo ended within a TTL and a round (\(round) rounds)")
        #expect(now <= ttl + 240_000)
    }
}
