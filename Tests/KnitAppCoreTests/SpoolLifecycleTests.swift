import KnitMesh
import KnitWire
import Testing

@testable import KnitAppCore

/// When the spool runs (ADR 2026-11.adrq, P6): `wanted = gate && foreground`, with `foreground` false until the first
/// `.active`, false again on `.background`, and kept on `.inactive`; a pause or a resume only on an edge.
@Suite struct SpoolLifecycleTests {
    private static func steps(_ inputs: [SpoolLifecycle.Input]) -> [SpoolLifecycle.Step] {
        var lifecycle = SpoolLifecycle()
        return inputs.flatMap { lifecycle.apply($0) }
    }

    @Test func aLaunchInTheBackgroundResumesNothingUntilTheFirstActive() {
        #expect(Self.steps([.gate(true), .launched(background: true)]) == [.background(true)])
        #expect(
            Self.steps([.gate(true), .launched(background: true), .scene(.active)]) == [.background(true), .background(false), .resume])
    }

    @Test func inactiveBeforeTheFirstActiveDoesNotResume() {
        #expect(Self.steps([.gate(true), .launched(background: false), .scene(.inactive)]) == [.background(false), .background(false)])
    }

    @Test func inactiveKeepsTheSpoolAndActiveAfterItSendsNothing() {
        let steps = Self.steps([.gate(true), .scene(.active), .scene(.inactive), .scene(.active)])
        #expect(steps == [.background(false), .resume, .background(false), .background(false)])
    }

    @Test func backgroundPausesAndTheNextActiveResumes() {
        let steps = Self.steps([.gate(true), .scene(.active), .scene(.background), .scene(.inactive), .scene(.active)])
        #expect(steps == [.background(false), .resume, .background(true), .pause, .background(false), .background(false), .resume])
    }

    @Test func activeThenBackgroundBackToBackEndsPaused() {
        var lifecycle = SpoolLifecycle()
        _ = lifecycle.apply(.gate(true))
        _ = lifecycle.apply(.scene(.active))
        _ = lifecycle.apply(.scene(.background))
        #expect(!lifecycle.wanted)
    }

    @Test func theGateDecidesAtTheFrontAndNothingInTheBackground() {
        #expect(Self.steps([.scene(.active), .gate(true), .gate(false)]) == [.background(false), .resume, .pause])
        #expect(Self.steps([.scene(.background), .gate(true), .gate(false)]) == [.background(true)])
        #expect(Self.steps([.scene(.active), .gate(true), .gate(true)]) == [.background(false), .resume], "a repeat is no edge")
    }

    @Test func relaysPassThroughInOrder() throws {
        let url = try #require(AcceptedSpoolURL(SpoolURL.house, allowCleartext: false))
        let handle = SpoolRelayHandle(number: 1)
        #expect(Self.steps([.add(handle, url), .remove(handle)]) == [.add(handle, url), .remove(handle)])
    }

    @Test func aBurstEndsAsItsLastPhaseSays() {
        for last in [AppPhase.background, .active] {
            var lifecycle = SpoolLifecycle()
            _ = lifecycle.apply(.gate(true))
            var phases = (0..<9).map { $0.isMultiple(of: 2) ? AppPhase.active : .background }
            phases.append(last)
            var resumes = 0
            var pauses = 0
            for phase in phases {
                for step in lifecycle.apply(.scene(phase)) {
                    resumes += step == .resume ? 1 : 0
                    pauses += step == .pause ? 1 : 0
                }
            }
            #expect(lifecycle.wanted == (last == .active))
            #expect(resumes - pauses == (last == .active ? 1 : 0), "every resume but the last met its pause")
        }
    }
}

/// The phases through ``MeshPhases`` into a real ``Mesh`` whose spool starts paused, dialling a counting factory: the order
/// the stream keeps is the order the sockets open and close in.
@Suite(.timeLimit(.minutes(1))) struct MeshPhasesTests {
    /// A started mesh, its relay carried and the gate open, as the app leaves it after a launch with the switch on.
    /// A mesh, the stream into it, and the sockets it opened.
    private struct Rig {
        let mesh: Mesh
        let phases: MeshPhases
        let sockets: CountingSockets
    }

    private static func rig(background: Bool) async throws -> Rig {
        let sockets = CountingSockets()
        let mesh = try pausedMesh(sockets)
        let phases = MeshPhases(target: mesh)
        phases.send(.add(SpoolRelayHandle(number: 1), try #require(AcceptedSpoolURL(SpoolURL.house, allowCleartext: false))))
        phases.send(.gate(true))
        await mesh.start()
        phases.send(.launched(background: background))
        await flush(phases)
        return Rig(mesh: mesh, phases: phases, sockets: sockets)
    }

    private static func flush(_ phases: MeshPhases) async {
        await withCheckedContinuation { continuation in
            phases.send(.remove(SpoolRelayHandle(number: 0))) { continuation.resume() }
        }
    }

    private static func send(_ phases: MeshPhases, _ scenes: [AppPhase]) async {
        for scene in scenes {
            phases.send(.scene(scene))
        }
        await flush(phases)
    }

    @Test func aBackgroundLaunchOpensNoSocketUntilActive() async throws {
        let rig = try await Self.rig(background: true)
        #expect(await rig.mesh.spoolStatus.paused, "a background launch leaves the spool paused")
        #expect(await rig.mesh.spoolStatus.relays.map(\.state) == ["idle"], "the relay is carried and undialled")
        #expect(rig.sockets.opens == 0)
        await Self.send(rig.phases, [.inactive])
        #expect(await rig.mesh.spoolStatus.paused, "inactive before the first active resumes nothing")
        await Self.send(rig.phases, [.active])
        await eventually { rig.sockets.opens == 1 }
        await rig.mesh.stop()
    }

    @Test func inactiveBetweenTwoActivesOpensOneConnection() async throws {
        let rig = try await Self.rig(background: false)
        await Self.send(rig.phases, [.active, .inactive, .active])
        await eventually { await rig.mesh.spoolStatus.relays.first?.state == "open" }
        #expect(rig.sockets.opens == 1 && rig.sockets.closes == 0)
        await rig.mesh.stop()
    }

    @Test func theBackgroundClosesAndTheNextActiveReopens() async throws {
        let rig = try await Self.rig(background: false)
        await Self.send(rig.phases, [.active])
        await eventually { rig.sockets.opens == 1 }
        await Self.send(rig.phases, [.background])
        #expect(await rig.mesh.spoolStatus.paused, "the pause has run once the stream says it has")
        await eventually { rig.sockets.closes == 1 }
        await Self.send(rig.phases, [.active])
        await eventually { rig.sockets.opens == 2 }
        await eventually { await rig.mesh.spoolStatus.relays.first?.state == "open" }
        await rig.mesh.stop()
    }

    /// The background task covers the pause: `done` runs once the rig.mesh is paused and the close issued.
    @Test func aBackgroundsDoneRunsAfterThePause() async throws {
        let rig = try await Self.rig(background: false)
        await Self.send(rig.phases, [.active])
        await eventually { await rig.mesh.spoolStatus.relays.first?.state == "open" }
        await withCheckedContinuation { continuation in
            rig.phases.send(.scene(.background)) { continuation.resume() }
        }
        #expect(await rig.mesh.spoolStatus.paused)
        #expect(rig.sockets.closes == 1, "the close was issued before done")
        await rig.mesh.stop()
    }

    @Test func aBurstOfTenFlipsEndsAsTheLastOneSays() async throws {
        for last in [AppPhase.background, .active] {
            let rig = try await Self.rig(background: false)
            var flips = (0..<9).map { $0.isMultiple(of: 2) ? AppPhase.active : .background }
            flips.append(last)
            await Self.send(rig.phases, flips)
            if last == .active {
                await eventually { await rig.mesh.spoolStatus.relays.first?.state == "open" }
                await eventually { rig.sockets.open == 1 }
            } else {
                #expect(await rig.mesh.spoolStatus.paused)
                await eventually { rig.sockets.open == 0 }
            }
            await rig.mesh.stop()
        }
    }

    @Test func theMeshReportsItsRelaysByHandle() async throws {
        let rig = try await Self.rig(background: false)
        #expect(await rig.mesh.relayStatus() == RelayMeshStatus(paused: true, relays: [1: .init(state: "idle", failures: 0)]))
        rig.phases.finish()
        await rig.mesh.stop()
    }
}
