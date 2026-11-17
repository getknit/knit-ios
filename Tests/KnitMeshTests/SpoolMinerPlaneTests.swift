import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The miner through the plane and its heals (ADR 2026-11.adrq, P4b2), over ``SpoolLab``'s synchronous driver: serials, one
/// run per value across table churn and relay churn, the heal's answers, the day's allowance against the cache, and pause.
@Suite struct SpoolMinerPlaneTests {
    private static let alice = SpoolEngineLabTests.alice

    private static func starts(_ lab: SpoolLab, _ index: Int) -> [SpoolMinerJob] {
        lab.runnerActions[index].compactMap { action in if case .start(let job) = action { job } else { nil } }
    }

    private static func subs(_ lab: SpoolLab, _ index: Int, naming scope: SpoolID) -> [ScopeSub] {
        lab.sent[index].flatMap { record -> [ScopeSub] in
            guard case .sub(let sub) = record else {
                return []
            }
            return sub.subs.filter { $0.scope == scope.bytes }
        }
    }

    @Test func aRunnerThatAlwaysExhaustsRunsOncePerValueAndTheScopeParksUntilTheNextDay() throws {
        let lab = try SpoolEngineLabTests.greeted(spool: FakeSpool(powBits: 8, now: EngineFixture.start))
        lab.holdsRuns = true
        lab.connect(1)
        lab.run(2)
        let job = try #require(lab.endRun(1, .exhausted(tried: SpoolPow.maxTries)))
        let scope = try #require(lab.scopes(1).first)
        let heal = try #require(lab.heal(1))
        let wall = lab[1].clock.wallMilliseconds()
        let nextDay = (job.day + 1) * SpoolPow.dayMilliseconds
        #expect(heal.state(scope.id)?.parkedUntil == lab[1].clock.monotonicMilliseconds() + nextDay - wall)
        // The spool keeps demanding for the rest of the day; no second run is asked for the value.
        lab.run(60, every: SpoolEngineLabTests.minute)
        #expect(Self.starts(lab, 1).count { $0.scope == job.scope && $0.day == job.day && $0.bits == job.bits } == 1)
        #expect(lab.planes[1].miner.counts.exhausted == 1 && lab.heldRuns.isEmpty)
        let status = lab.planes[1].status(inbound: lab[1].engine.spoolInbound.counts, now: lab[1].clock.monotonicMilliseconds())
        #expect(status.counts["minerExhausted"] == 1 && status.counts["minerSpent"] == Int(SpoolPow.maxTries))
    }

    @Test func aSpoolRefusingEveryStampedSubCostsAtMostTheDaysStampsThoughTheCacheHoldsOne() throws {
        let spool = FakeSpool(powBits: 8, now: EngineFixture.start)
        spool.refusesEveryStampedSub = true
        let lab = try SpoolEngineLabTests.greeted(spool: spool)
        lab.connect(1)
        lab.run(120, every: SpoolEngineLabTests.minute)
        let scope = try #require(lab.scopes(1).first)
        let stamped = Self.subs(lab, 1, naming: scope.id).filter { $0.pow != nil }
        #expect(stamped.count == ScopeHeal.maxStampsPerDay, "a found answer from the cache counts toward the allowance")
        #expect(lab.planes[1].miner.counts.runs == 1 && lab.planes[1].miner.counts.fromCache >= 1)
        let heal = try #require(lab.heal(1))
        #expect(heal.counts.stampsCapped >= 1 && heal.isParked(scope.id, now: lab[1].clock.monotonicMilliseconds()))
    }

    @Test func aScopeThatLeavesAndReentersTheTableFourTimesIsMinedOnce() throws {
        let lab = try SpoolEngineLabTests.greeted(spool: FakeSpool(powBits: 8, now: EngineFixture.start))
        lab.connect(1)
        lab.run(2)
        let scope = try #require(lab.scopes(1).first)
        #expect(Self.starts(lab, 1).count == 1 && lab.spool.scopes[scope.id] != nil)
        for _ in 0..<4 {
            lab.block(1, Self.alice.nodeId)
            #expect(lab.scopes(1).isEmpty)
            lab[1].engine.unblock(Self.alice.nodeId)
            lab.spool.forget(scope.id)
            lab.markTableDirty(1)
            lab.run(2)
            #expect(lab.spool.scopes[scope.id] != nil, "back in the table and subscribed")
        }
        #expect(Self.starts(lab, 1).count == 1, "the cache answered every return")
        #expect(lab.planes[1].miner.counts.fromCache == 4)
    }

    @Test func aRelayRemovedAndAddedMidSearchGivesTheOldSerialNothingAndTheNewOneAnswer() throws {
        let lab = try SpoolEngineLabTests.greeted(spool: FakeSpool(powBits: 8, now: EngineFixture.start))
        lab.holdsRuns = true
        lab.connect(1)
        lab.run(2)
        let old = try #require(lab.heal(1)?.mining.values.first)
        lab.planes[1].remove(lab.relay, engine: lab[1].engine)
        lab.takeActions(1)
        lab.pump()
        guard case .stop(let stopped)? = lab.runnerActions[1].last else {
            Issue.record("the removal stopped the run")
            return
        }
        SpoolLab.add(&lab.planes[1], lab.relay, engine: lab[1].engine)
        lab.connect(1)
        lab.run(2)
        let fresh = try #require(lab.heal(1)?.mining.values.first)
        #expect(fresh.serial != old.serial && fresh.scope == old.scope)
        #expect(lab.runnerActions[1].last == .proceed(run: stopped), "the identical ask took the run back")
        lab.endRun(1)
        lab.run(2)
        #expect(Self.starts(lab, 1).count == 1 && lab.heal(1)?.mining.isEmpty == true)
        #expect(lab.spool.scopes[old.scope] != nil, "the re-added relay subscribed")
        #expect(lab.planes[1].miner.requests.isEmpty)
    }

    @Test func aPauseMidSearchResumesAtTheCounterItReachedAndTheFirstSubCarriesTheStamp() throws {
        let lab = try SpoolEngineLabTests.greeted(spool: FakeSpool(powBits: 8, now: EngineFixture.start))
        lab.holdsRuns = true
        lab.connect(1)
        lab.run(2)
        let job = try #require(lab.heldRuns.first?.job)
        lab.disconnect(1)
        #expect(lab.runnerActions[1].last == .stop(run: job.run), "the pause stopped the run")
        lab.endRun(1, .cancelled(tried: 65_536))
        lab.run(4)
        #expect(lab.heldRuns.isEmpty && Self.starts(lab, 1).count == 1, "no run starts while paused")
        #expect(lab.heal(1)?.mining.count == 1, "the request stays attached")
        lab.forgetSent(1)
        lab.connect(1)
        let resumed = try #require(lab.heldRuns.first?.job, "the resume started it in its own turn")
        #expect(resumed.from == 65_536 && resumed.run != job.run)
        let scope = SpoolID(resumed.scope.bytes)
        lab.endRun(1)
        lab.run(2)
        let subs = Self.subs(lab, 1, naming: try #require(scope))
        #expect(subs.first?.pow != nil, "the first sub after the resume carries the stamp")
        if let pow = subs.first?.pow {
            #expect(
                pow.counter >= 65_536 && SpoolPow.verify(scopeId: resumed.scope.bytes, day: pow.day, n: pow.counter, bits: resumed.bits))
        }
        #expect(lab.planes[1].miner.counts.resumed == 1 && lab.link(1)?.counts.stampsAnsweredOffline == 0)
    }
}
