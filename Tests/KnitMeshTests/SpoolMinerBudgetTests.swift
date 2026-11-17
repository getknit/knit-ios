import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// The miner's budget, its shares and its order, and pause (ADR 2026-11.adrq, P4b2), driven through ``MinerBench``.
@Suite struct SpoolMinerBudgetTests {
    private static let full = SpoolPow.maxTries
    private static let relayCap = SpoolMinerBudget.relayCap

    // MARK: The budget

    @Test func pastTheEngineWindowNoRunStartsAndEveryQueuedRequestIsAnsweredOverBudget() {
        let scopes = Array(UInt8(1)...UInt8(10))
        // Spread over relays and peers so no share binds before the engine.
        var bench = MinerBench(scopes)
        var requests: [SpoolMiningRequest] = []
        for scope in scopes {
            requests.append(bench.request(scope, bits: 22, relay: Int(scope)))
        }
        bench.ask(requests)
        for _ in 0..<8 {
            bench.end(.exhausted(tried: Self.full))
        }
        #expect(bench.miner.budget.spent(now: bench.now.monotonic) == SpoolMinerBudget.engineCap)
        #expect(bench.miner.running == nil, "no ninth run")
        let parked = requests.dropFirst(8).compactMap { bench.answer($0) }
        #expect(parked.count == 2 && bench.miner.counts.overBudget == 2)
        for answer in parked {
            guard case .overBudget(let park) = answer else {
                Issue.record("over budget")
                continue
            }
            #expect(park == SpoolPow.dayMilliseconds, "until a whole range frees, held to a day")
        }
        // The window rolls on the monotonic clock: 25 hours on, a search fits again.
        _ = bench.starts()
        bench.advance(SpoolMinerBudget.windowHours * SpoolMinerBudget.hourMilliseconds)
        let next = bench.request(1, bits: 21)
        bench.ask([next])
        #expect(bench.starts().count == 1)
    }

    @Test func aRelaysSpendStaysWithinItsShareAndAnotherRelayIsServedFirst() throws {
        let busy = Array(UInt8(10)..<UInt8(138))
        var bench = MinerBench(busy + [MinerVector.twenty.scope])
        let demands = busy.map { bench.request($0, bits: 24, relay: 1) }
        bench.ask(demands)
        let first = try #require(bench.starts().first)
        #expect(first.scope == MinerBench.id(10))
        let other = bench.request(MinerVector.twenty.scope, bits: 20, relay: 2)
        bench.ask([other])
        bench.end(.exhausted(tried: Self.full))
        let second = try #require(bench.starts().first)
        #expect(
            second.scope == MinerBench.id(MinerVector.twenty.scope), "the relay that spent nothing goes before the busy one's second run")
        bench.end(.found(MinerVector.twenty.counter, tried: MinerVector.twenty.counter + 1))
        #expect(bench.answer(other) == .found(counter: MinerVector.twenty.counter, bits: MinerVector.twenty.bits))
        while bench.miner.running != nil {
            bench.end(.exhausted(tried: Self.full))
        }
        let spent = bench.miner.budget.spent(relay: SpoolRelayHandle(number: 1), now: bench.now.monotonic)
        #expect(spent <= SpoolMinerBudget.relayCap && spent == 4 * Self.full)
        #expect(bench.miner.counts.overRelayShare == busy.count - 4 && bench.asked.isEmpty)
    }

    @Test func aValueSeveralRelaysAskForIsChargedToALeastSpentRelayWhoseShareHolds() {
        var bench = MinerBench([MinerVector.deep.scope])
        let one = SpoolRelayHandle(number: 1)
        let two = SpoolRelayHandle(number: 2)
        bench.miner.budget.charge(Self.relayCap, relay: one, peer: MinerBench.peer(200), now: bench.now.monotonic)
        let first = bench.request(MinerVector.deep.scope, bits: 24, relay: 1)
        let second = bench.request(MinerVector.deep.scope, bits: 24, relay: 2)
        bench.ask([first, second])
        #expect(bench.starts().count == 1, "one run for the value")
        bench.end(.found(MinerVector.deep.counter, tried: 1000))
        let found = SpoolStampAnswer.found(counter: MinerVector.deep.counter, bits: MinerVector.deep.bits)
        #expect(bench.answer(first) == found && bench.answer(second) == found)
        #expect(bench.miner.budget.spent(relay: two, now: bench.now.monotonic) == 1000, "the relay whose share holds paid")
        #expect(bench.miner.budget.spent(relay: one, now: bench.now.monotonic) == Self.relayCap)
        #expect(bench.miner.counts.overRelayShare == 0)
    }

    @Test func twoRelaysAskingTheSameValuesAreRefusedARelayShareOnlyWhenBothSharesAreShort() {
        let scopes = Array(UInt8(10)..<UInt8(138))
        var bench = MinerBench(scopes)
        bench.ask(scopes.map { bench.request($0, bits: 24, relay: 1) })
        bench.ask(scopes.map { bench.request($0, bits: 24, relay: 2) })
        var runs = 0
        while bench.miner.running != nil {
            runs += 1
            bench.end(.exhausted(tried: Self.full / 2))
        }
        let now = bench.now.monotonic
        let one = bench.miner.budget.spent(relay: SpoolRelayHandle(number: 1), now: now)
        let two = bench.miner.budget.spent(relay: SpoolRelayHandle(number: 2), now: now)
        #expect(runs == 14 && one == 7 * Self.full / 2 && two == one, "each relay paid for half the runs")
        #expect(one <= Self.relayCap && two <= Self.relayCap)
        #expect(bench.miner.counts.overRelayShare == scopes.count - runs && bench.miner.counts.overBudget == 0)
        #expect(bench.asked.isEmpty, "every request of both relays answered")
    }

    @Test func aPeerWhoseScopeChangesEveryMinuteSpendsWithinItsShare() {
        let peer: UInt8 = 200
        var bench = MinerBench([])
        var scopes: [UInt8] = []
        for minute in 0..<10 {
            let scope = UInt8(20 + minute)
            scopes.append(scope)
            bench.adopt(scopes, peers: scopes.map { _ in peer })
            let request = bench.request(scope, bits: 24, relay: 1 + minute % 3)
            bench.ask([request])
            bench.end(.exhausted(tried: Self.full))
            bench.advance(60_000)
        }
        #expect(bench.miner.budget.spent(peer: MinerBench.peer(peer), now: bench.now.monotonic) == SpoolMinerBudget.peerCap)
        #expect(bench.miner.counts.overPeerShare == 8 && bench.miner.counts.runs == 2)
        // Another peer's new scope is still mined.
        bench.adopt(scopes + [99], peers: scopes.map { _ in peer } + [99])
        let other = bench.request(99, bits: 24, relay: 1)
        bench.ask([other])
        #expect(bench.starts().contains { $0.scope == MinerBench.id(99) })
    }

    @Test func aFreeRunnerTakesTheLeastSpentRelayThenPeerThenRank() {
        var bench = MinerBench([1, 2, 3, 4, 5], peers: [1, 1, 2, 3, 1])
        let warm = bench.request(5, bits: 8, relay: 1)
        bench.ask([warm])
        bench.end(.exhausted(tried: 1000))
        // Relay 1 and peer 1 have spent; relay 2 has not.
        let blocker = bench.request(4, bits: 8, relay: 1)
        bench.ask([blocker])
        let samePeer = bench.request(2, bits: 8, relay: 2)
        let byRank = bench.request(3, bits: 8, relay: 2)
        let busyRelay = bench.request(1, bits: 9, relay: 1)
        bench.ask([busyRelay, samePeer, byRank])
        _ = bench.starts()
        bench.end(.exhausted(tried: 1))
        #expect(bench.starts().first?.scope == MinerBench.id(3), "relay 2, and a peer that spent nothing")
        bench.end(.exhausted(tried: 1))
        #expect(bench.starts().first?.scope == MinerBench.id(2), "relay 2 before the relay that spent")
        bench.end(.exhausted(tried: 1))
        #expect(bench.starts().first?.scope == MinerBench.id(1))
    }

    @Test func theBudgetNeverDropsAChargeBeforeADayAndKeepsAtMost25Buckets() {
        var budget = SpoolMinerBudget()
        let relay = SpoolRelayHandle(number: 1)
        let peer = MinerBench.peer(1)
        let hour = SpoolMinerBudget.hourMilliseconds
        for step in 0..<60 {
            budget.charge(10, relay: relay, peer: peer, now: Int64(step) * hour + hour - 1)
        }
        #expect(budget.engine.buckets.count == 25 && budget.spent(now: 60 * hour - 1) == 250)
        // A clock that runs back charges the newest bucket rather than an older one.
        budget.charge(5, relay: relay, peer: peer, now: 0)
        #expect(budget.engine.buckets.count == 25 && budget.spent(now: 60 * hour - 1) == 255)
        // A share with nothing left in its window is dropped.
        budget.charge(1, relay: SpoolRelayHandle(number: 2), peer: MinerBench.peer(2), now: 200 * hour)
        #expect(budget.relays.keys.sorted() == [SpoolRelayHandle(number: 2)] && budget.peers.count == 1)
        #expect(budget.spent(relay: relay, now: 200 * hour) == 0 && budget.spent(peer: peer, now: 200 * hour) == 0)
        // The shortest park holds even when the window frees within it.
        var spentPeer = SpoolMinerBudget()
        spentPeer.charge(SpoolMinerBudget.peerCap, relay: relay, peer: peer, now: 0)
        let short = spentPeer.shortfall(need: 1, relay: relay, peer: peer, now: 25 * hour - 1)
        #expect(short?.share == .peer && short?.parkMilliseconds == SpoolSession.minParkMilliseconds)
        #expect(spentPeer.shortfall(need: 1, relay: SpoolRelayHandle(number: 3), peer: MinerBench.peer(3), now: 0) == nil)
        let relayShort = spentPeer.shortfall(need: SpoolMinerBudget.relayCap, relay: relay, peer: MinerBench.peer(3), now: 0)
        #expect(relayShort?.share == .relay && relayShort?.parkMilliseconds == SpoolPow.dayMilliseconds)
    }

    // MARK: Pause

    @Test func aPausedSearchWhoseResultLandsAfterTheResumeStillResumesFirst() throws {
        let scope = MinerVector.sixteen.scope
        var bench = MinerBench([scope, 2])
        let paused = bench.request(scope, bits: 16, relay: 1)
        bench.ask([paused])
        let job = try #require(bench.starts().first)
        let other = bench.request(2, bits: 16, relay: 2)
        bench.ask([other])
        bench.miner.pause()
        bench.record(bench.miner.resume(now: bench.now))
        #expect(bench.miner.takeActions() == [.stop(run: job.run), .proceed(run: job.run)])
        // The runner had seen the stop before the resume cleared it: its result lands after the resume.
        bench.end(.cancelled(tried: 65_536))
        let next = try #require(bench.starts().first)
        #expect(next.scope == MinerBench.id(scope) && next.from == 65_536, "the paused value first, though the other relay spent less")
    }

    @Test func aPauseStopsTheRunKeepsItsRequestsAndTheResumeCarriesItOn() throws {
        let scope = MinerVector.sixteen.scope
        var bench = MinerBench([scope, 2])
        let running = bench.request(scope, bits: 16)
        bench.ask([running])
        let job = try #require(bench.starts().first)
        bench.miner.pause()
        bench.miner.pause()
        #expect(bench.miner.takeActions() == [.stop(run: job.run)], "one stop")
        let queued = bench.request(2, bits: 16)
        bench.ask([queued])
        let again = bench.request(scope, bits: 16, relay: 2)
        bench.ask([again])
        #expect(bench.miner.takeActions().isEmpty, "nothing starts or clears while paused")
        bench.end(.cancelled(tried: 65_536))
        #expect(bench.starts().isEmpty && bench.miner.requests.count == 3, "the requests stay attached")
        bench.record(bench.miner.resume(now: bench.now))
        let resumed = try #require(bench.starts().first)
        #expect(resumed.scope == MinerBench.id(scope) && resumed.from == 65_536, "the stopped value resumes where it stopped")
        // A resume before the runner looked clears the flag instead.
        bench.miner.pause()
        _ = bench.miner.takeActions()
        bench.record(bench.miner.resume(now: bench.now))
        #expect(bench.miner.takeActions() == [.proceed(run: resumed.run)])
        // A search that returned before a pause still lands, and nothing starts after it while paused.
        bench.miner.pause()
        bench.end(.found(MinerVector.sixteen.counter, tried: MinerVector.sixteen.counter - 65_536 + 1))
        let found = SpoolStampAnswer.found(counter: MinerVector.sixteen.counter, bits: MinerVector.sixteen.bits)
        #expect(bench.answer(running) == found && bench.answer(again) == found)
        #expect(bench.answer(queued) == nil && bench.miner.running == nil)
        #expect(bench.miner.budget.spent(now: bench.now.monotonic) == MinerVector.sixteen.counter + 1, "the runs add up to one search")
    }
}
