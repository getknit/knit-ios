public import KnitMesh
public import KnitWire

/// What ``MeshPhases`` tells: the live app's ``Mesh``, the demo's stand-in, or a test's.
public protocol PhaseTarget: AnyObject, Sendable {
    /// Whether Knit is in the background, where the links seek peers (ADR 2026-10.mueg).
    func setInBackground(_ background: Bool) async
    /// Ends every relay's session and dials none until ``resumeSpool()``.
    func pauseSpool() async
    /// Dials every relay again.
    func resumeSpool() async
    /// Carries the relay at `url` under `handle`; answers whether it took it.
    @discardableResult
    func addSpoolRelay(_ handle: SpoolRelayHandle, url: AcceptedSpoolURL) async -> Bool
    /// Drops the relay `handle`.
    func removeSpoolRelay(_ handle: SpoolRelayHandle) async
    /// Where each relay stands, by handle and counts alone.
    func relayStatus() async -> RelayMeshStatus
}

/// The spool plane as the relay settings show it: whether it is paused, and each relay's connection by handle.
public struct RelayMeshStatus: Sendable, Equatable {
    /// One relay's connection.
    public struct Relay: Sendable, Equatable {
        /// `idle`, `dialing` or `open`.
        public let state: String
        /// Unreached sessions in a row.
        public let failures: Int

        /// A relay `state` after `failures` failures.
        public init(state: String, failures: Int) {
            self.state = state
            self.failures = failures
        }
    }

    /// Whether the plane is paused.
    public let paused: Bool
    /// Each relay the plane carries, by handle number.
    public let relays: [Int: Relay]

    /// A status.
    public init(paused: Bool, relays: [Int: Relay]) {
        self.paused = paused
        self.relays = relays
    }
}

extension Mesh: PhaseTarget {
    /// The plane's ``SpoolStatus`` with its counts left out: the settings show a word per relay, never a number.
    public func relayStatus() -> RelayMeshStatus {
        let status = spoolStatus
        let relays = status.relays.map { ($0.handle, RelayMeshStatus.Relay(state: $0.state, failures: $0.failures)) }
        // The plane keys its relays by handle, so each handle comes once.
        return RelayMeshStatus(paused: status.paused, relays: Dictionary(uniqueKeysWithValues: relays))
    }
}

/// The one serial stream into a mesh from the app (ADR 2026-11.adrq, P6): the scene's phases, the gate, and the relays the
/// settings add and drop, applied in the order they were sent by one task, so a quick toggle never overtakes the one before
/// it and nothing reaches the mesh from a fresh task per change. ``SpoolLifecycle`` decides when the spool pauses and
/// resumes; the links hear every phase.
public final class MeshPhases: Sendable {
    private typealias Sent = (input: SpoolLifecycle.Input, done: (@Sendable () -> Void)?)

    /// The mesh it tells.
    public let target: any PhaseTarget
    private let continuation: AsyncStream<Sent>.Continuation

    /// A stream into `target`, its task running from now on.
    public init(target: any PhaseTarget) {
        self.target = target
        let (stream, sink) = AsyncStream<Sent>.makeStream()
        continuation = sink
        Task {
            var lifecycle = SpoolLifecycle()
            for await sent in stream {
                for step in lifecycle.apply(sent.input) {
                    await Self.perform(step, on: target)
                }
                sent.done?()
            }
        }
    }

    /// Sends `input`; `done` runs once the mesh has done all it asked, a pause's closes issued among them, or at once when the
    /// stream has ended and nothing will reach the mesh, so a background task waiting on it is never held to its expiry.
    @preconcurrency
    public func send(_ input: SpoolLifecycle.Input, done: (@Sendable () -> Void)? = nil) {
        if case .terminated = continuation.yield((input, done)) {
            done?()
        }
    }

    /// Ends the stream: what the sample chats do as they close. Nothing sent after reaches the mesh.
    public func finish() {
        continuation.finish()
    }

    private static func perform(_ step: SpoolLifecycle.Step, on target: any PhaseTarget) async {
        switch step {
        case .background(let background):
            await target.setInBackground(background)
        case .pause:
            await target.pauseSpool()
        case .resume:
            await target.resumeSpool()
        case .add(let handle, let url):
            await target.addSpoolRelay(handle, url: url)
        case .remove(let handle):
            await target.removeSpoolRelay(handle)
        }
    }
}
