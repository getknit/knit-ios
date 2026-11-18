public import KnitMesh
import KnitSync
public import KnitWire

/// `-demoRelays`' stand-in for the spool plane, under `-seedDemo` (ADR 2026-11.adrq, P6): the demo's mesh hears the scene's
/// phases, and its relays are kept here, each shown connected while the plane runs. It opens no socket, so the UI tests walk
/// the relay settings with nothing leaving the Simulator.
public final class DemoRelays: PhaseTarget {
    private struct State {
        var relays: Set<Int> = []
        var paused = true
    }

    private let mesh: any PhaseTarget
    private let state = Lock(State())

    /// The stand-in over `mesh`, which hears the background.
    public init(over mesh: any PhaseTarget) {
        self.mesh = mesh
    }

    public func setInBackground(_ background: Bool) async {
        await mesh.setInBackground(background)
    }

    public func pauseSpool() {
        state.withLock { $0.paused = true }
    }

    public func resumeSpool() {
        state.withLock { $0.paused = false }
    }

    @discardableResult
    public func addSpoolRelay(_ handle: SpoolRelayHandle, url _: AcceptedSpoolURL) -> Bool {
        state.withLock { $0.relays.insert(handle.number).inserted }
    }

    public func removeSpoolRelay(_ handle: SpoolRelayHandle) {
        _ = state.withLock { $0.relays.remove(handle.number) }
    }

    public func relayStatus() -> RelayMeshStatus {
        state.withLock { state in
            let shown = RelayMeshStatus.Relay(state: state.paused ? "idle" : "open", failures: 0)
            return RelayMeshStatus(paused: state.paused, relays: Dictionary(uniqueKeysWithValues: state.relays.map { ($0, shown) }))
        }
    }
}
