import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The mesh's side of the spool's sockets at its edges (ADR 2026-11.adrq, P4b1): a mesh with no factory, a removal, a
/// stamp answered with no session, a pause and a resume in one breath, a dial that opens after its token ended, and a
/// reader's wait.
@Suite struct SpoolMeshEdgeTests {
    @Test func aMeshWithNoSocketFactoryCarriesNoRelay() async throws {
        let fixture = EngineFixture(SpoolEngineLabTests.alice)
        let mesh = Mesh(
            identity: fixture.me.keys,
            deviceTag: nil,
            stores: fixture.stores,
            radio: FakeRadio(advertisesServiceData: false),
            clock: fixture.clock,
            random: SeededGenerator(seed: 3)
        )
        await mesh.start()
        let url = try #require(SpoolLab.url)
        #expect(await !mesh.addSpoolRelay(SpoolMeshRig.relay, url: url))
        #expect(await mesh.spoolStatus.relays.isEmpty)
        await mesh.stop()
    }

    /// Test 11 through the meshes: the stamp is answered while Bob has no session, and his next connection's first `sub`
    /// carries it with no second search; then a removal cancels what is still asked.
    @Test func aStampAnsweredWithNoSessionRidesTheNextSubThroughTheMesh() async throws {
        let rig = try await SpoolMeshRig.make(spool: FakeSpool(powBits: 8, now: EngineFixture.start))
        await rig.run(2)
        let asked = await rig[1].spoolMiningQueue
        let request = try #require(asked.first, "the spool asked a stamp")
        await rig[1].pauseSpool()
        await rig.settle()
        let counter = SpoolPow.mine(scopeId: request.scope.bytes, day: request.day, bits: request.bits)
        await rig[1].spoolStampMined(request, counter: counter)
        #expect(await rig[1].spoolMiningQueue.isEmpty)
        #expect(await rig[1].spoolStatus.relays.first?.counts["stampsAnsweredOffline"] == 1)
        rig.net.forgetSent()
        await rig[1].resumeSpool()
        await rig.run(2)
        let subs = rig.net.sent(by: 1).compactMap { record -> SpoolSub? in if case .sub(let sub) = record { sub } else { nil } }
        #expect(subs.first?.subs.contains { $0.scope == request.scope.bytes && $0.pow != nil } == true, "the first sub carries it")
        #expect(await rig[1].spoolMiningQueue.isEmpty, "no second search")

        // Alice still waits on hers, if the spool asked one; a removal cancels it in its turn.
        await rig[0].removeSpoolRelay(SpoolMeshRig.relay)
        let queue = await rig[0].spoolMiningQueue
        let relays = await rig[0].spoolStatus.relays
        #expect(queue.isEmpty && relays.isEmpty)
        await rig[1].spoolStampMined(request, counter: counter)
    }

    /// A pause and a resume in one breath: the new dial waits for the old task to end, then goes.
    @Test func aDialWaitsForTheLastTaskToEnd() async throws {
        let rig = try await SpoolMeshRig.make()
        await rig.run(2)
        let dials = rig.net.dials
        await rig[0].pauseSpool()
        await rig[0].resumeSpool()
        // A second pause closes the dial that waits, before it ever went.
        await rig[0].pauseSpool()
        await rig[0].resumeSpool()
        await rig.run(2)
        #expect(rig.net.dials <= dials + 2 && rig.net.dials > dials, "the waiting dials went one at a time")
        #expect(await rig[0].spoolStatus.relays.first?.state == "open")
        #expect(rig.net.overlappingReceives == 0)
    }

    /// A dial that opens after its open deadline ended its token is closed at once, and the next dial goes.
    @Test func aSocketThatOpensAfterItsTokenEndedIsClosed() async throws {
        let rig = try await SpoolMeshRig.make()
        await rig.run(2)
        rig.net.holdsOpens = true
        rig.net.dropAll()
        await rig.settle()
        // A session that ended before 30 s waits out the rest of them, then redials.
        await rig.rawAdvance(SpoolLink.reachedMilliseconds + SpoolBackoff.jitterMilliseconds)
        #expect(rig.net.heldOpens > 0, "the redial waits")
        await rig.rawAdvance(SpoolLink.openMilliseconds)
        #expect(await rig[0].spoolStatus.relays.first?.counts["dialTimeouts"] ?? 0 >= 1)
        rig.net.holdsOpens = false
        rig.net.releaseOpens()
        await rig.settle()
        await rig.run(30, every: SpoolBackoff.maxRetryAfterMilliseconds)
        #expect(await rig[0].spoolStatus.relays.first?.state == "open", "a later dial opened")
    }

    /// A dial asked for while the last task still runs waits for it, and a pause in between closes it before it goes.
    @Test func aWaitingDialIsClosedByAPause() async throws {
        let rig = try await SpoolMeshRig.make()
        await rig.run(2)
        rig.net.holdsOpens = true
        await rig[0].pauseSpool()
        await rig[0].resumeSpool()
        await rig.settle()
        #expect(rig.net.heldOpens == 1, "the first redial's task holds")
        await rig[0].pauseSpool()
        await rig[0].resumeSpool()
        let waiting = await rig[0].spoolTasks.waitingDials[SpoolMeshRig.relay]
        #expect(waiting != nil, "the second waits for the first task")
        await rig[0].pauseSpool()
        #expect(await rig[0].spoolTasks.waitingDials[SpoolMeshRig.relay] == nil, "a pause closed the waiting dial")
        rig.net.holdsOpens = false
        rig.net.releaseOpens()
        await rig[0].resumeSpool()
        await rig.run(4)
        #expect(await rig[0].spoolStatus.relays.first?.state == "open")
    }

    /// A reader parks only under its own token, and a resume that came first is not lost.
    @Test func aResumeBeforeTheParkIsOwedToTheReader() async throws {
        let rig = try await SpoolMeshRig.make()
        await rig.run(2)
        let stale = SpoolConnectionToken(value: 999)
        #expect(await !rig[0].spoolParkReader(SpoolMeshRig.relay, stale), "an old token reads no further")
        let token = try #require(await rig[0].spoolTasks.running[SpoolMeshRig.relay]?.token)
        await rig[0].resumeSpoolReader(SpoolMeshRig.relay, token)
        #expect(await rig[0].spoolParkReader(SpoolMeshRig.relay, token), "the owed resume lets it read on")
        await rig[0].resumeSpoolReader(SpoolMeshRig.relay, stale)
    }

    /// A relay whose sessions end right after their first round is dialled at most once per 30 s.
    @Test func sessionsThatEndEarlyAreDialledAtMostOncePerReachedSpan() async throws {
        let rig = try await SpoolMeshRig.make()
        await rig.run(4)
        rig.net.withSpool { $0.closesAfterRound = true }
        let dials = rig.net.dials
        await rig.run(Int(10 * 60_000 / ScopeHeal.healFloorMilliseconds))
        let mine = await rig[0].spoolStatus.relays.first?.counts["dials"] ?? 0
        #expect(rig.net.dials - dials <= 2 * 21 && mine <= 22, "at most 21 dials a relay in 10 minutes: \(mine)")
        #expect(await rig[0].spoolStatus.relays.first?.counts["reached"] ?? 0 > 5, "each session compared a round")
    }

    /// A long clock jump while a pull's blobs wait on the inbound budget: whatever the session does, both folds end on the
    /// spool's digest, each frame is delivered once, and the spool serves at most the backlog and one more pull.
    @Test func aLongClockJumpOnAnOpenSessionStillConverges() async throws {
        let rig = try await SpoolMeshRig.make()
        await rig.run(4)
        await rig[1].pauseSpool()
        var ids: [String] = []
        for index in 0..<100 {
            ids.append(try await rig.send(0, 1, "jump \(index)"))
        }
        await rig.run(2)
        let served = rig.net.served(to: 1)
        await rig[1].resumeSpool()
        await rig.settle()
        let parked = await rig[1].spoolStatus.relays.first?.counts["inboundDeferred"] ?? 0
        #expect(parked > 0 || rig.net.queued > 0, "the pull's blobs wait on the inbound budget")
        let lateBefore = await rig[1].spoolStatus.relays.first?.counts["dropped.unsolicited"] ?? 0
        await rig.rawAdvance(5 * 60_000)
        await rig.run(24)
        let lateAfter = await rig[1].spoolStatus.relays.first?.counts["dropped.unsolicited"] ?? 0
        #expect(lateAfter > lateBefore, "the jump ran the late-pull path")
        let folds = await rig.folds()
        #expect(folds.alice == folds.spool && folds.bob == folds.spool)
        #expect(ids.allSatisfy { rig.holds(1, $0) })
        let rows = rig.lab.radio.thread(1, with: 0)
        #expect(Set(rows).count == rows.count, "each delivered once")
        let backlog = rig.spool.scopes.values.flatMap(\.live).map(\.data.count)
        let largest = backlog.max() ?? 0
        #expect(rig.net.served(to: 1) - served <= backlog.reduce(0, +) + FakeSpool.defaultLimits.maxPull * largest)
    }
}
