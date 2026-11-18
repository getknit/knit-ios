import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A mesh made with its spool paused (ADR 2026-11.adrq, P6): the app's live mesh starts that way, so a launch in the
/// background, Bluetooth's restoration among them, opens no relay socket until the app's scene comes to the front and
/// resumes it. The plane's wanted state lives in the mesh alone, so a bridge-style stop and start keep it; a resume keeps a
/// relay's own `Retry-After`, through a late refusal and a re-add, and its early-end floor; and a resume of a running spool
/// changes nothing.
@Suite struct MeshSpoolLifecycleTests {
    private static let second = SpoolRelayHandle(number: 2)

    /// A mesh over `net`'s door, its spool paused from the start, and the two relays it carries, added before `start()` as the
    /// app adds the relays it read at launch.
    private static func pausedMesh(_ net: SpoolNet) async throws -> (Mesh, ManualClock) {
        let fixture = EngineFixture(SpoolEngineLabTests.alice)
        let mesh = Mesh(
            identity: fixture.me.keys,
            deviceTag: nil,
            stores: fixture.stores,
            radio: FakeRadio(advertisesServiceData: false),
            clock: fixture.clock,
            random: SeededGenerator(seed: 7),
            spoolSockets: net.door(0),
            spoolStartsPaused: true
        )
        let other = try #require(AcceptedSpoolURL("wss://lab.spool.test/spool/v1", allowCleartext: false))
        #expect(await mesh.addSpoolRelay(SpoolMeshRig.relay, url: try #require(SpoolLab.url)))
        #expect(await mesh.addSpoolRelay(Self.second, url: other))
        return (mesh, fixture.clock)
    }

    @Test func aMeshStartedPausedOpensNoSocketUntilItsSpoolResumes() async throws {
        let net = SpoolNet(spool: FakeSpool(now: EngineFixture.start))
        let (mesh, _) = try await Self.pausedMesh(net)
        await mesh.start()
        await Self.settle(mesh, net)
        #expect(net.dials == 0, "a paused start dials nothing")
        #expect(await mesh.spoolDeadline == nil, "and leaves no spool deadline")
        #expect(await mesh.spoolStatus.paused)

        await mesh.resumeSpool()
        await Self.settle(mesh, net)
        #expect(net.dials == 2, "one dial per relay")
        await mesh.stop()
    }

    @Test func aStopAndStartWhilePausedOpensNone() async throws {
        let net = SpoolNet(spool: FakeSpool(now: EngineFixture.start))
        let (mesh, _) = try await Self.pausedMesh(net)
        await mesh.start()
        await mesh.stop()
        await mesh.start()
        await Self.settle(mesh, net)
        #expect(net.dials == 0, "the bridge's stop and start keep the pause")

        // Once resumed, a stop pauses the plane and the next start resumes it, as before.
        await mesh.resumeSpool()
        await Self.settle(mesh, net)
        await mesh.stop()
        await Self.settle(mesh, net)
        let dials = net.dials
        await mesh.start()
        await Self.settle(mesh, net)
        #expect(net.dials == dials + 2)
        await mesh.stop()
    }

    /// A 503 with `Retry-After: 30`, then a pause and a resume ten seconds later: the relay is dialled no sooner than the
    /// thirty seconds it asked for, and the other relay at once.
    @Test func aResumeKeepsARelaysOwnRetryAfter() async throws {
        let net = SpoolNet(spool: FakeSpool(now: EngineFixture.start))
        let (mesh, clock) = try await Self.pausedMesh(net)
        net.refuse([SpoolDialFailure(.http, status: 503, retryAfter: SpoolRetryAfter(header: Array("30".utf8)))])
        await mesh.start()
        await mesh.removeSpoolRelay(Self.second)
        let refusedAt = clock.monotonicMilliseconds()
        await mesh.resumeSpool()
        await Self.settle(mesh, net)
        #expect(net.dials == 1, "the one dial was refused")

        clock.advance(10_000)
        await mesh.pauseSpool()
        let other = try #require(AcceptedSpoolURL("wss://lab.spool.test/spool/v1", allowCleartext: false))
        #expect(await mesh.addSpoolRelay(Self.second, url: other))
        await mesh.resumeSpool()
        await Self.settle(mesh, net)
        #expect(net.dials == 2, "the other relay goes at once; the refused one waits")
        let redial = try #require(await mesh.spoolRedial(SpoolMeshRig.relay))
        #expect(redial >= refusedAt + 30_000, "no sooner than the relay asked: \(redial - refusedAt)")

        clock.advance(redial - clock.monotonicMilliseconds() - 1)
        await Self.settle(mesh, net)
        #expect(net.dials == 2)
        clock.advance(1)
        await Self.settle(mesh, net)
        #expect(net.dials == 3, "then it is dialled")
        await mesh.stop()
    }

    /// A second and a third `resumeSpool()` on a mesh whose spool already runs, with its relay three refusals deep in the
    /// backoff: no dial goes, and the redial and the count stay as they were.
    @Test func aResumeOfARunningSpoolKeepsTheBackoff() async throws {
        let net = SpoolNet(spool: FakeSpool(now: EngineFixture.start))
        let (mesh, clock) = try await Self.oneRelayMesh(net)
        net.refuse(Array(repeating: SpoolDialFailure(.http, status: 503, retryAfter: nil), count: 3))
        await mesh.start()
        await mesh.resumeSpool()
        await Self.settle(mesh, net)
        while net.dials < 3 {
            let redial = try #require(await mesh.spoolRedial(SpoolMeshRig.relay))
            clock.advance(redial - clock.monotonicMilliseconds())
            await Self.settle(mesh, net)
        }
        #expect(await mesh.spool.relays[SpoolMeshRig.relay]?.link.failures == 3)
        let redial = try #require(await mesh.spoolRedial(SpoolMeshRig.relay))

        await mesh.resumeSpool()
        await mesh.resumeSpool()
        await Self.settle(mesh, net)
        #expect(net.dials == 3, "no dial at once")
        #expect(await mesh.spoolRedial(SpoolMeshRig.relay) == redial, "the redial stands")
        #expect(await mesh.spool.relays[SpoolMeshRig.relay]?.link.failures == 3, "and so does the count")
        await mesh.stop()
    }

    /// A 503 with `Retry-After: 30` held at the door while the app pauses, then landing: the pause had ended the dial, but
    /// the relay's floor stands, and the resume ten seconds later dials it no sooner than thirty seconds after the refusal.
    @Test func aRefusalThatLandsAfterAPauseKeepsItsFloor() async throws {
        let net = SpoolNet(spool: FakeSpool(now: EngineFixture.start))
        let (mesh, clock) = try await Self.oneRelayMesh(net)
        net.refuse([SpoolDialFailure(.http, status: 503, retryAfter: SpoolRetryAfter(header: Array("30".utf8)))])
        net.holdsOpens = true
        await mesh.start()
        await mesh.resumeSpool()
        await Self.settle(mesh, net)
        #expect(net.heldOpens == 1, "the dial waits at the door")
        await mesh.pauseSpool()
        net.holdsOpens = false
        net.releaseOpens()
        await Self.settle(mesh, net)
        // The task ends just after it posts the refusal, and neither post moves what `settle` watches: wait on the task.
        for _ in 0..<10_000 where await mesh.spoolTasks.running[SpoolMeshRig.relay] != nil {
            await Task.yield()
        }
        #expect(net.dials == 1)
        let refusedAt = clock.monotonicMilliseconds()
        #expect(await mesh.spool.askedFloors[SpoolMeshRig.relay] == refusedAt + 30_000, "the refusal landed after the pause")

        clock.advance(10_000)
        await mesh.resumeSpool()
        await Self.settle(mesh, net)
        #expect(net.dials == 1)
        #expect(await mesh.spoolRedial(SpoolMeshRig.relay) == refusedAt + 30_000, "the floor the refusal named")
        await Self.expectDial(at: refusedAt + 30_000, mesh, net, clock)
        await mesh.stop()
    }

    /// A relay refused with `Retry-After: 30`, removed and added again five seconds later under its handle, as the switch,
    /// consent and park do: it is dialled no sooner than the thirty seconds it asked for.
    @Test func aReAddedRelayKeepsItsFloor() async throws {
        let net = SpoolNet(spool: FakeSpool(now: EngineFixture.start))
        let (mesh, clock) = try await Self.oneRelayMesh(net)
        net.refuse([SpoolDialFailure(.http, status: 503, retryAfter: SpoolRetryAfter(header: Array("30".utf8)))])
        await mesh.start()
        await mesh.resumeSpool()
        await Self.settle(mesh, net)
        #expect(net.dials == 1)
        let refusedAt = clock.monotonicMilliseconds()

        clock.advance(5000)
        await mesh.removeSpoolRelay(SpoolMeshRig.relay)
        #expect(await mesh.addSpoolRelay(SpoolMeshRig.relay, url: try #require(SpoolLab.url)))
        await Self.settle(mesh, net)
        #expect(net.dials == 1, "the fresh relay waits for its handle's floor")
        #expect(await mesh.spoolRedial(SpoolMeshRig.relay) == refusedAt + 30_000)
        await Self.expectDial(at: refusedAt + 30_000, mesh, net, clock)
        await mesh.stop()
    }

    /// A session the relay closed five seconds in, then a pause and a resume: the relay is dialled no sooner than thirty
    /// seconds after that session opened, as its own redial would have been.
    @Test func aResumeKeepsTheEarlyEndFloor() async throws {
        let net = SpoolNet(spool: FakeSpool(now: EngineFixture.start))
        let (mesh, clock) = try await Self.oneRelayMesh(net)
        await mesh.start()
        await mesh.resumeSpool()
        await Self.settle(mesh, net)
        #expect(await mesh.spoolStatus.relays.first?.state == "open")
        let openedAt = clock.monotonicMilliseconds()

        clock.advance(5000)
        net.dropAll()
        await Self.settle(mesh, net)
        #expect(await mesh.spoolStatus.relays.first?.state == "idle", "the relay closed the session early")
        await mesh.pauseSpool()
        await mesh.resumeSpool()
        await Self.settle(mesh, net)
        #expect(net.dials == 1)
        #expect(await mesh.spoolRedial(SpoolMeshRig.relay) == openedAt + SpoolLink.reachedMilliseconds, "the rest of 30 s")
        await Self.expectDial(at: openedAt + SpoolLink.reachedMilliseconds, mesh, net, clock)
        await mesh.stop()
    }

    /// ``pausedMesh(_:)`` with its second relay removed.
    private static func oneRelayMesh(_ net: SpoolNet) async throws -> (Mesh, ManualClock) {
        let (mesh, clock) = try await pausedMesh(net)
        await mesh.removeSpoolRelay(second)
        return (mesh, clock)
    }

    /// Nothing more is dialled until `due`, and one dial goes then.
    private static func expectDial(
        at due: Int64, _ mesh: Mesh, _ net: SpoolNet, _ clock: ManualClock, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let dials = net.dials
        clock.advance(due - clock.monotonicMilliseconds() - 1)
        await settle(mesh, net)
        #expect(net.dials == dials, "nothing a millisecond before", sourceLocation: sourceLocation)
        clock.advance(1)
        await settle(mesh, net)
        #expect(net.dials == dials + 1, "then the dial", sourceLocation: sourceLocation)
    }

    /// Waits until no dial, receive, send or timer moves for a while.
    private static func settle(_ mesh: Mesh, _ net: SpoolNet, sourceLocation: SourceLocation = #_sourceLocation) async {
        var last: [Int] = []
        var stable = 0
        for _ in 0..<100_000 {
            let now = net.activity + [await mesh.timerFirings]
            await Task.yield()
            if now == last {
                stable += 1
                if stable >= 40 {
                    return
                }
            } else {
                stable = 0
                last = now
            }
        }
        Issue.record("the mesh never went quiet", sourceLocation: sourceLocation)
    }
}
