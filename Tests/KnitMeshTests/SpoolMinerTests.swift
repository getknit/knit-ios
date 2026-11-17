import KnitCrypto
import Testing

@testable import KnitMesh

/// The engine's stamp miner as a value (ADR 2026-11.adrq, P4b2): one run per value, requests by serial, exactly one ending
/// each, the cache, the budget and its shares, the order, and pause. The runner is the test: it ends each started job with
/// the search it names. No test here hashes past one digest per found answer.
@Suite struct SpoolMinerTests {
    private static let full = SpoolPow.maxTries

    // MARK: One run per value

    @Test func oneRunServesEveryRequestForAValueAcrossRelays() {
        var bench = MinerBench([MinerVector.twenty.scope])
        let first = bench.request(MinerVector.twenty.scope, bits: 20, relay: 1)
        let second = bench.request(MinerVector.twenty.scope, bits: 20, relay: 2)
        bench.ask([first])
        bench.ask([second])
        #expect(bench.starts().count == 1, "one run for the value")
        bench.end(.found(MinerVector.twenty.counter, tried: MinerVector.twenty.counter + 1))
        #expect(bench.answer(first) == .found(counter: MinerVector.twenty.counter, bits: MinerVector.twenty.bits))
        #expect(bench.answer(second) == bench.answer(first))
        #expect(bench.miner.requests.isEmpty && bench.miner.values.isEmpty && bench.miner.running == nil)
        #expect(bench.miner.counts.runs == 1 && bench.miner.counts.found == 1)
    }

    @Test func aCancelOfOneOfTwoRequestsLeavesTheRunToTheOther() throws {
        var bench = MinerBench([MinerVector.twenty.scope])
        let kept = bench.request(MinerVector.twenty.scope, bits: 20, relay: 1)
        let dropped = bench.request(MinerVector.twenty.scope, bits: 20, relay: 2)
        bench.ask([kept, dropped])
        let job = try #require(bench.starts().first)
        bench.cancel(dropped)
        #expect(bench.miner.takeActions().isEmpty, "a request is still attached: no stop")
        bench.end(.found(MinerVector.twenty.counter, tried: MinerVector.twenty.counter + 1))
        #expect(bench.answer(kept) != nil && bench.answer(dropped) == nil && job.from == 0)
    }

    @Test func aMineAndItsCancelInOneBatchStartNoRun() {
        var bench = MinerBench([1])
        let request = bench.request(1, bits: 8)
        bench.asked[request.serial] = request
        bench.record(bench.miner.take([.mine(request), .cancel(request)], now: bench.now))
        #expect(bench.starts().isEmpty && bench.miner.requests.isEmpty && bench.miner.values.isEmpty)
        #expect(bench.answers.isEmpty)
    }

    @Test func aCancelTheMinerDoesNotHoldDoesNothing() {
        var bench = MinerBench([1])
        let early = bench.request(1, bits: 8)
        bench.cancel(early)
        #expect(bench.miner.takeActions().isEmpty)
        bench.ask([early])
        #expect(bench.starts().count == 1, "a cancel before its mine leaves the mine to run")
    }

    @Test func aMineForAScopeOutsideTheTableIsNotTaken() {
        var bench = MinerBench([1])
        let request = bench.request(2, bits: 8)
        bench.ask([request])
        #expect(bench.miner.requests.isEmpty && bench.starts().isEmpty && bench.miner.counts.unheldScopes == 1)
        bench.asked[request.serial] = nil
    }

    // MARK: Exactly one ending

    @Test func detachingTheLastRequestStopsTheRunAndAnAttachClearsTheStop() throws {
        var bench = MinerBench([1])
        let old = bench.request(1, bits: 16)
        bench.ask([old])
        let job = try #require(bench.starts().first)
        bench.cancel(old)
        #expect(bench.miner.takeActions() == [.stop(run: job.run)], "the last request gone stops the run")
        let fresh = bench.request(1, bits: 16)
        bench.ask([fresh])
        #expect(bench.miner.takeActions() == [.proceed(run: job.run)], "an identical request clears the stop")
        // The runner had already seen the stop: its cancelled result requeues the value for the attached request alone.
        bench.end(.cancelled(tried: 65_536))
        let resumed = try #require(bench.starts().first)
        #expect(resumed.from == 65_536 && bench.miner.counts.resumed == 1 && bench.miner.counts.stopped == 1)
        bench.end(.exhausted(tried: Self.full - 65_536))
        #expect(bench.answer(fresh) == .exhausted && bench.answer(old) == nil, "the old serial gets nothing")
        #expect(bench.answers.count == 1)
    }

    @Test func aRunStoppingForWantOfRequestsThatAPauseFindsStillResumesFirst() throws {
        let scope = MinerVector.sixteen.scope
        var bench = MinerBench([scope, 2])
        let gone = bench.request(scope, bits: 16, relay: 1)
        bench.ask([gone])
        let job = try #require(bench.starts().first)
        bench.cancel(gone)
        bench.miner.pause()
        #expect(bench.miner.takeActions() == [.stop(run: job.run)], "one stop, from the detach")
        let again = bench.request(scope, bits: 16, relay: 1)
        bench.ask([again])
        bench.end(.cancelled(tried: 65_536))
        let other = bench.request(2, bits: 16, relay: 2)
        bench.ask([other])
        bench.record(bench.miner.resume(now: bench.now))
        let next = try #require(bench.starts().first)
        #expect(next.scope == MinerBench.id(scope) && next.from == 65_536, "the stopped value first, though the other spent less")
    }

    @Test func aStoppedRunWithNoRequestAnswersNobodyAndItsFindIsCached() {
        var bench = MinerBench([MinerVector.twenty.scope])
        let request = bench.request(MinerVector.twenty.scope, bits: 20)
        bench.ask([request])
        _ = bench.starts()
        bench.cancel(request)
        bench.cancel(request)
        bench.end(.found(MinerVector.twenty.counter, tried: MinerVector.twenty.counter + 1))
        #expect(bench.answers.isEmpty && bench.miner.values.isEmpty)
        let later = bench.request(MinerVector.twenty.scope, bits: 18)
        bench.ask([later])
        #expect(bench.answer(later) == .found(counter: MinerVector.twenty.counter, bits: MinerVector.twenty.bits) && bench.starts().isEmpty)
        #expect(bench.miner.counts.fromCache == 1)
    }

    @Test func aStoppedRunWithNoRequestIsDroppedAndAResultForAnotherRunIsIgnored() throws {
        var bench = MinerBench([1])
        let request = bench.request(1, bits: 16)
        bench.ask([request])
        let job = try #require(bench.starts().first)
        bench.cancel(request)
        #expect(bench.miner.ended(run: job.run + 7, .exhausted(tried: 1), now: bench.now).isEmpty, "another run's result")
        bench.end(.cancelled(tried: 131_072))
        #expect(bench.miner.values.isEmpty && bench.miner.running == nil && bench.starts().isEmpty)
        #expect(bench.miner.budget.spent(now: bench.now.monotonic) == 131_072, "charged exactly its tried")
    }

    // MARK: The cache

    @Test func theCacheAnswersFewerBitsThanAFindAndMoreThanAnExhaustion() {
        var bench = MinerBench([MinerVector.deep.scope, 2])
        let deep = bench.request(MinerVector.deep.scope, bits: 24)
        bench.ask([deep])
        _ = bench.starts()
        // A 20-bit ask queued behind the 24-bit run for the same scope and day is answered by its find.
        let twenty = bench.request(MinerVector.deep.scope, bits: 20)
        bench.ask([twenty])
        #expect(bench.starts().isEmpty, "queued behind the run")
        bench.end(.found(MinerVector.deep.counter, tried: 1))
        #expect(bench.answer(deep) == .found(counter: MinerVector.deep.counter, bits: MinerVector.deep.bits))
        #expect(bench.answer(twenty) == bench.answer(deep) && bench.starts().isEmpty, "answered by the find, no run")

        let exhausting = bench.request(2, bits: 12)
        bench.ask([exhausting])
        _ = bench.starts()
        bench.end(.exhausted(tried: Self.full))
        let more = bench.request(2, bits: 14)
        let fewer = bench.request(2, bits: 10)
        bench.ask([more, fewer])
        #expect(bench.answer(more) == .exhausted, "more bits than an exhaustion: exhausted at once")
        #expect(bench.answer(fewer) == nil && bench.starts().count == 1, "fewer bits still run")
        #expect(bench.miner.counts.fromCache == 2 && bench.miner.counts.exhausted == 1)
    }

    @Test func aSearchResumesFromTheFurthestCounterReachedAtItsBitsOrFewer() {
        var bench = MinerBench([1])
        let sixteen = bench.request(1, bits: 16)
        bench.ask([sixteen])
        _ = bench.starts()
        bench.miner.pause()
        bench.end(.cancelled(tried: 196_608))
        bench.cancel(sixteen)
        bench.record(bench.miner.resume(now: bench.now))
        let twenty = bench.request(1, bits: 20)
        bench.ask([twenty])
        #expect(bench.starts().first?.from == 196_608, "a deeper search resumes where a shallower one stopped")
        bench.end(.exhausted(tried: Self.full - 196_608))
        let twelve = bench.request(1, bits: 12)
        bench.ask([twelve])
        #expect(bench.starts().first?.from == 0, "a shallower one starts at 0")
    }

    @Test func theCacheKeepsTheDeepestFindAndTheShallowestExhaustion() {
        let value = SpoolMiner.Value(
            SpoolMiningRequest(serial: 1, relay: SpoolRelayHandle(number: 1), scope: MinerBench.id(1), day: 1, bits: 8))
        var cache = SpoolMinerCache()
        cache.found(value, counter: 5, bits: 12, table: [])
        cache.found(value, counter: 9, bits: 10, table: [])
        cache.found(value, counter: 3, bits: 14, table: [])
        #expect(cache.entries[value.key]?.found == SpoolMinerCache.Found(counter: 3, bits: 14))
        cache.exhausted(value, table: [])
        let deeper = SpoolMiner.Value(
            SpoolMiningRequest(serial: 2, relay: SpoolRelayHandle(number: 1), scope: MinerBench.id(1), day: 1, bits: 20))
        cache.exhausted(deeper, table: [])
        #expect(cache.entries[value.key]?.exhaustedBits == 8)
        cache.reached(value, counter: 70, table: [])
        cache.reached(value, counter: 40, table: [])
        #expect(cache.resumeFrom(deeper) == 70)
    }

    @Test func pastItsCapTheCacheEvictsScopesOutOfTheTableThenTheOldestDay() {
        var cache = SpoolMinerCache()
        let inTable = MinerBench.id(1)
        func value(_ byte: UInt8, day: Int64) -> SpoolMiner.Value {
            SpoolMiner.Value(
                SpoolMiningRequest(serial: 1, relay: SpoolRelayHandle(number: 1), scope: MinerBench.id(byte), day: day, bits: 8))
        }
        // One entry of a table scope on the oldest day, then entries of other scopes on later days up to the cap.
        cache.reached(value(1, day: 1), counter: 1, table: [inTable])
        for index in 0..<(SpoolMinerCache.maxEntries - 1) {
            cache.reached(value(UInt8(2 + index % 200), day: Int64(10 + index / 200)), counter: 1, table: [inTable])
        }
        #expect(cache.entries.count == SpoolMinerCache.maxEntries)
        cache.reached(value(250, day: 99), counter: 1, table: [inTable])
        #expect(cache.entries.count == SpoolMinerCache.maxEntries)
        #expect(cache.entries[value(1, day: 1).key] != nil, "a table scope's entry stays while others can go")
        #expect(cache.entries[value(2, day: 10).key] == nil, "the oldest day of a scope out of the table went first")
        // With every entry a table scope's, the oldest day goes.
        let all = Set((0...255).compactMap { SpoolID([UInt8](repeating: UInt8($0), count: 32)) })
        cache.reached(value(251, day: 99), counter: 1, table: all)
        #expect(cache.entries[value(1, day: 1).key] == nil)
        // Past reuse, an entry leaves whatever the table says.
        cache.prune(wall: 200 * SpoolPow.dayMilliseconds)
        #expect(cache.entries.isEmpty)
    }

    @Test func aScopeThatLeavesAndReentersTheTableIsMinedOncePerValue() {
        var bench = MinerBench([MinerVector.twenty.scope])
        for round in 0..<5 {
            let request = bench.request(MinerVector.twenty.scope, bits: 20)
            bench.ask([request])
            if round == 0 {
                bench.end(.found(MinerVector.twenty.counter, tried: MinerVector.twenty.counter + 1))
            }
            #expect(bench.answer(request) != nil, "round \(round)")
            bench.adopt([])
            bench.adopt([MinerVector.twenty.scope])
        }
        #expect(bench.miner.counts.runs == 1 && bench.miner.counts.fromCache == 4)
    }
}
