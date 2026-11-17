import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The miner through two ``Mesh``es (ADR 2026-11.adrq, P4b2): one run engine-wide while the mesh answers, two relays served
/// by one run, a pause and a stop mid-search resumed where they stopped, and the real runner beside ratchet seals and
/// stopping within one check of a removal.
@Suite struct SpoolMinerMeshTests {
    /// `SpoolPow`'s counters between two looks at the stop flag.
    private static let checkInterval: Int64 = 65_536

    private static func stamped(_ rig: SpoolMeshRig, by tag: Int, scope: SpoolID) -> [PowStamp] {
        rig.net.sent(by: tag).flatMap { record -> [PowStamp] in
            guard case .sub(let sub) = record else {
                return []
            }
            return sub.subs.filter { $0.scope == scope.bytes }.compactMap(\.pow)
        }
    }

    private static func waitIdle(_ rig: SpoolMeshRig, _ index: Int) async {
        await rig.until { await rig[index].spool.miner.running == nil }
    }

    @Test func oneRunServesTwoRelaysWhileTheMeshAnswers() async throws {
        let bob = FakeStampRunner()
        let rig = try await SpoolMeshRig.make(spool: FakeSpool(powBits: 8, now: EngineFixture.start), runners: [FakeStampRunner(), bob])
        await rig.run(2)
        let url = try #require(AcceptedSpoolURL("wss://second.spool.test/spool/v1", allowCleartext: false))
        let second = SpoolRelayHandle(number: 2)
        #expect(await rig[1].addSpoolRelay(second, url: url))
        await rig.run(2)
        let scope = try #require(await rig[1].spoolScopes.first)
        let relays = await rig[1].spool.relays
        #expect(relays.values.allSatisfy { $0.heal.mining.count == 1 }, "both relays wait on a stamp")
        #expect(bob.started.count == 1 && bob.held.count == 1, "one run for both")
        for _ in 0..<3 {
            #expect(await rig[1].spoolStatus.relays.count == 2, "the mesh answers while the runner holds its search")
        }
        bob.release()
        await Self.waitIdle(rig, 1)
        await rig.run(2)
        let after = await rig[1].spool.relays
        let answered = after.values.allSatisfy(\.heal.mining.isEmpty)
        #expect(answered, "both answered")
        let stamps = Self.stamped(rig, by: 1, scope: scope)
        #expect(stamps.count >= 2, "each relay's sub carried the stamp")
        #expect(stamps.allSatisfy { SpoolPow.verify(scopeId: scope.bytes, day: $0.day, n: $0.counter, bits: 8) })
        #expect(await rig[1].spoolStatus.counts["minerRuns"] == 1)
    }

    /// A mesh carrying two relays, the first with its share spent: a value the second relay asks for is mined on the second
    /// relay's share, the first relay's ask joins the running search and gets its answer, and the second relay's scope never
    /// parks over budget while the engine's window has room. The choice among several asking relays is pinned by
    /// `SpoolMinerBudgetTests.aValueSeveralRelaysAskForIsChargedToALeastSpentRelayWhoseShareHolds`.
    @Test func aSharedValueIsMinedOnTheShareOfARelayThatHoldsIt() async throws {
        let bob = FakeStampRunner()
        let spool = FakeSpool(now: EngineFixture.start)
        let rig = try await SpoolMeshRig.make(spool: spool, runners: [FakeStampRunner(), bob])
        await rig.run(2)
        let url = try #require(AcceptedSpoolURL("wss://second.spool.test/spool/v1", allowCleartext: false))
        let second = SpoolRelayHandle(number: 2)
        #expect(await rig[1].addSpoolRelay(second, url: url))
        await rig.run(2)
        let scope = try #require(rig.spoolScope())
        // The first relay's share is spent on other peers' searches; the spool now forgets the scope and asks 16 bits.
        let other = try #require(NodeId(bytes: [UInt8](repeating: 0x77, count: NodeId.byteCount)))
        await rig[1].chargeSpoolMiner(SpoolMinerBudget.relayCap, relay: SpoolMeshRig.relay, peer: other)
        rig.net.withSpool { spool in
            spool.forget(scope)
            spool.powBits = 16
        }
        // The second relay asks first; the first, carried again, asks while that search runs and attaches to it.
        await rig[1].removeSpoolRelay(SpoolMeshRig.relay)
        rig.net.dropAll()
        await rig.run(30, every: SpoolBackoff.maxRetryAfterMilliseconds)
        let job = try #require(bob.held.first, "a search for the scope")
        #expect(job.bits == 16)
        let first = try #require(SpoolLab.url)
        #expect(await rig[1].addSpoolRelay(SpoolMeshRig.relay, url: first))
        await rig.run(4)
        #expect(bob.held.count == 1 && bob.started.count == 1, "the first relay's ask joined the running search")
        bob.release()
        await Self.waitIdle(rig, 1)
        await rig.run(4)
        let budget = await rig[1].spool.miner.budget
        let now = rig.clock.monotonicMilliseconds()
        #expect(budget.spent(relay: second, now: now) > 0, "the second relay paid")
        #expect(budget.spent(relay: SpoolMeshRig.relay, now: now) == SpoolMinerBudget.relayCap)
        let stamps = Self.stamped(rig, by: 1, scope: scope)
        #expect(!stamps.isEmpty && stamps.allSatisfy { SpoolPow.verify(scopeId: scope.bytes, day: $0.day, n: $0.counter, bits: 16) })
        let status = await rig[1].spoolStatus
        let relayTwo = try #require(status.relays.first { $0.handle == second.number })
        #expect(relayTwo.counts["parks"] == 0 && status.counts["minerOverBudget"] == 0, "nothing on the second relay parked")
        #expect(status.counts["minerOverRelayShare"] == 0, "no value refused for want of a relay share")
        let relayOne = try #require(await rig[1].spool.relays[SpoolMeshRig.relay]?.heal.state(scope))
        #expect(relayOne.stamp != nil && relayOne.stampBits >= 16, "the first relay's heal got the found answer too")
        #expect(await rig[1].spool.relays[second]?.heal.mining.isEmpty == true)
    }

    /// The reviewers' two-engine pause: the search crosses a check, sees the pause's stop, and the resume carries it on.
    @Test func aPauseMidSearchResumesWhereItStoppedAndTheChargeAddsUpToOneSearch() async throws {
        // The pair's scope is drawn afresh in each lab: move to the first day whose 16-bit stamp lies past the first check.
        let lab = try SpoolEngineLabTests.greeted()
        let scope = try #require(lab.scopes(1).first?.id)
        let today = SpoolPow.utcDay(nowMs: lab[0].clock.wallMilliseconds())
        let offset = try #require(
            (Int64(0)..<32).first { offset in
                var checks = 0
                let search = SpoolPow.mine(scopeId: scope.bytes, day: today + offset, bits: 16) {
                    checks += 1
                    return checks > 1
                }
                return search == .cancelled(tried: Self.checkInterval)
            })
        lab.advance(offset * SpoolPow.dayMilliseconds)
        let bob = FakeStampRunner()
        let spool = FakeSpool(powBits: 16, now: lab[0].clock.wallMilliseconds())
        let rig = try await SpoolMeshRig.make(lab, nodes: [0, 1], spool: spool, runners: [FakeStampRunner(), bob])
        await rig.run(2)
        let job = try #require(bob.held.first, "bob's spool asked a stamp")
        #expect(job.scope == scope && job.day == today + offset)
        await rig[1].pauseSpool()
        #expect(bob.stopAsked, "the pause set the stop flag")
        bob.release(skippedChecks: 1)
        await Self.waitIdle(rig, 1)
        #expect(await rig[1].spoolStatus.counts["minerStopped"] == 1 && bob.held.isEmpty, "stopped at a check, nothing new while paused")
        await rig[1].resumeSpool()
        let resumed = try #require(bob.held.first, "the resume started it in its own turn")
        #expect(resumed.from == Self.checkInterval, "at the counter it reached")
        bob.release()
        await Self.waitIdle(rig, 1)
        await rig.run(2)
        let whole = try #require(SpoolPow.mine(scopeId: scope.bytes, day: job.day, bits: 16).counter)
        let stamps = Self.stamped(rig, by: 1, scope: scope)
        #expect(stamps.first?.counter == whole, "the stamp a search from 0 finds")
        let status = await rig[1].spoolStatus
        #expect(status.counts["minerSpent"] == Int(whole + 1), "both runs add up to one search")
        let relay = try #require(status.relays.first)
        #expect(relay.counts["parks"] == 0 && (relay.counts["stampsAnsweredOffline"] ?? 0) <= 1)
        #expect(rig.spool.scopes[scope] != nil, "the spool took the stamp")
    }

    @Test func aStopMidSearchThenAStartRunsTheQueuedSearchAndMiningEmpties() async throws {
        let bob = FakeStampRunner()
        let rig = try await SpoolMeshRig.make(spool: FakeSpool(powBits: 8, now: EngineFixture.start), runners: [FakeStampRunner(), bob])
        await rig.run(2)
        #expect(bob.held.count == 1)
        await rig[1].stop()
        bob.release()
        await Self.waitIdle(rig, 1)
        #expect(bob.held.isEmpty && bob.started.count == 1, "nothing starts while stopped")
        #expect(await rig[1].spool.miner.requests.count == 1, "the request waits in the queue")
        await rig[1].start()
        #expect(bob.held.count == 1, "the start ran the queued search")
        bob.release()
        await Self.waitIdle(rig, 1)
        await rig.run(4)
        #expect(await rig[1].spool.relays[SpoolMeshRig.relay]?.heal.mining.isEmpty == true)
        #expect(await rig[1].spool.miner.requests.isEmpty)
    }

    @Test func aResumeBeforeTheRunnerLooksClearsTheStopAndTheSearchLands() async throws {
        let bob = FakeStampRunner()
        let rig = try await SpoolMeshRig.make(spool: FakeSpool(powBits: 8, now: EngineFixture.start), runners: [FakeStampRunner(), bob])
        await rig.run(2)
        #expect(bob.held.count == 1)
        await rig[1].pauseSpool()
        await rig[1].resumeSpool()
        #expect(!bob.stopAsked, "the resume cleared the stop before the runner looked")
        bob.release()
        await Self.waitIdle(rig, 1)
        await rig.run(4)
        let stopped = await rig[1].spoolStatus.counts["minerStopped"]
        #expect(bob.started.count == 1 && stopped == 0, "one search, never stopped")
        #expect(await rig[1].spool.relays[SpoolMeshRig.relay]?.heal.mining.isEmpty == true)
    }

    /// The real runner at 8 bits while both meshes seal and open ratchet messages, under TSan in `check.sh tsan`.
    @Test func theRealRunnerMinesBesideRatchetSeals() async throws {
        let rig = try await SpoolMeshRig.make(spool: FakeSpool(powBits: 8, now: EngineFixture.start))
        var ids: [String] = []
        for index in 0..<4 {
            ids.append(try await rig.send(0, 1, "sealed \(index)"))
            ids.append(try await rig.send(1, 0, "and back \(index)"))
            await rig.run(1)
        }
        for index in 0..<2 {
            await Self.waitIdle(rig, index)
        }
        await rig.run(12)
        #expect(ids.allSatisfy { rig.holds(0, $0) && rig.holds(1, $0) }, "every message delivered")
        let alice = await rig[0].spoolStatus.counts["minerFound"] ?? 0
        let bob = await rig[1].spoolStatus.counts["minerFound"] ?? 0
        #expect(alice + bob >= 1, "a real run found a stamp")
        for index in 0..<2 {
            await rig[index].shutdownSpoolMiner()
        }
    }

    /// A real 24-bit search while the mesh answers, then the relay removed: the search stops within one check of it.
    @Test func aRealDeepSearchStopsWithinOneCheckOfTheRemoval() async throws {
        let rig = try await SpoolMeshRig.make(spool: FakeSpool(powBits: 24, now: EngineFixture.start))
        let flag = try #require(await rig[1].spoolSearch?.flag, "the search runs")
        await rig.until(polls: 50_000_000) {
            let running = await rig[1].spoolSearch != nil
            return flag.checks >= 2 || !running
        }
        for _ in 0..<3 {
            #expect(await rig[1].spoolStatus.relays.count == 1, "the mesh answers while the search runs")
        }
        await rig[1].removeSpoolRelay(SpoolMeshRig.relay)
        let checks = flag.checks
        await rig[1].shutdownSpoolMiner()
        await Self.waitIdle(rig, 1)
        let status = await rig[1].spoolStatus
        let tried = try #require(status.counts["minerSpent"])
        // A random scope's 24-bit stamp lies within the first checks once in a hundred searches or so: then the search found
        // it before the removal, and the bound holds all the same.
        #expect((status.counts["minerStopped"] ?? 0) + (status.counts["minerFound"] ?? 0) == 1)
        #expect(Int64(tried) <= Int64(checks) * Self.checkInterval, "at most one check past the removal")
        await rig[0].removeSpoolRelay(SpoolMeshRig.relay)
        await rig[0].shutdownSpoolMiner()
    }
}

extension Mesh {
    /// Charges the miner's budget as though `relay` had run searches for `peer`: how a test spends a share first.
    func chargeSpoolMiner(_ tried: Int64, relay: SpoolRelayHandle, peer: NodeId) {
        spool.miner.budget.charge(tried, relay: relay, peer: peer, now: engine.clock.monotonicMilliseconds())
    }
}
