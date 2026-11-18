import KnitCrypto
import KnitMesh
import KnitStore
import KnitSync
import KnitWire
import Testing

@testable import KnitAppCore

/// Sockets that open and stay quiet until closed, counting each open and close and recording the host each was opened to:
/// the factory a real ``Mesh`` dials through in the relay tests, so a test reads what the plane was asked to open.
final class CountingSockets: SpoolSocketFactory {
    private struct State {
        var hosts: [String] = []
        var closes = 0
    }

    private let state = Lock(State())

    /// Every host a socket was opened to, in order.
    var hosts: [String] { state.withLock { $0.hosts } }
    var opens: Int { state.withLock { $0.hosts.count } }
    var closes: Int { state.withLock { $0.closes } }
    /// Sockets opened and not yet closed.
    var open: Int { state.withLock { $0.hosts.count - $0.closes } }

    // swiftlint:disable:next async_without_await - the factory's requirement is async; this one answers at once
    func open(_ url: AcceptedSpoolURL) async -> SpoolDial {
        state.withLock { $0.hosts.append(url.description) }
        return .opened(QuietSocket { [weak self] in self?.state.withLock { $0.closes += 1 } })
    }
}

/// A socket that says nothing: its reader waits until it is closed.
final class QuietSocket: SpoolSocket {
    private struct State {
        var reader: CheckedContinuation<SpoolSocketMessage, Never>?
        var ended = false
    }

    private let state = Lock(State())
    private let closed: @Sendable () -> Void

    init(closed: @escaping @Sendable () -> Void) {
        self.closed = closed
    }

    func receive() async -> SpoolSocketMessage {
        await withCheckedContinuation { continuation in
            let ended = state.withLock { state in
                if !state.ended {
                    state.reader = continuation
                }
                return state.ended
            }
            if ended {
                continuation.resume(returning: .closed(SpoolSocketEnd(.closed)))
            }
        }
    }

    // swiftlint:disable:next async_without_await - the socket's requirement is async; this one takes every send at once
    func send(_: [UInt8]) async -> Bool {
        true
    }

    func close(code: Int) {
        let (first, reader) = state.withLock { state -> (Bool, CheckedContinuation<SpoolSocketMessage, Never>?) in
            guard !state.ended else {
                return (false, nil)
            }
            state.ended = true
            let reader = state.reader
            state.reader = nil
            return (true, reader)
        }
        if first {
            closed()
        }
        reader?.resume(returning: .closed(SpoolSocketEnd(.closed, code: code)))
    }
}

/// A mesh stand-in that records what it was told, in order, and answers the status a test sets.
final class RecordingTarget: PhaseTarget {
    enum Call: Equatable {
        case background(Bool)
        case pause
        case resume
        case add(Int, String)
        case remove(Int)
    }

    private struct State {
        var calls: [Call] = []
        var status = RelayMeshStatus(paused: true, relays: [:])
    }

    private let state = Lock(State())

    var calls: [Call] { state.withLock { $0.calls } }
    var status: RelayMeshStatus {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }

    /// The handles added and not removed since, in the order added.
    var carried: [Int] {
        var handles: [Int] = []
        for call in calls {
            if case .add(let handle, _) = call {
                handles.append(handle)
            } else if case .remove(let handle) = call {
                handles.removeAll { $0 == handle }
            }
        }
        return handles
    }

    func setInBackground(_ background: Bool) {
        state.withLock { $0.calls.append(.background(background)) }
    }

    func pauseSpool() {
        state.withLock { $0.calls.append(.pause) }
    }

    func resumeSpool() {
        state.withLock { $0.calls.append(.resume) }
    }

    func addSpoolRelay(_ handle: SpoolRelayHandle, url: AcceptedSpoolURL) -> Bool {
        state.withLock { $0.calls.append(.add(handle.number, url.socketURLText)) }
        return true
    }

    func removeSpoolRelay(_ handle: SpoolRelayHandle) {
        // Handle 0 is the tests' flush, never a relay.
        if handle.number != 0 {
            state.withLock { $0.calls.append(.remove(handle.number)) }
        }
    }

    func relayStatus() -> RelayMeshStatus {
        status
    }
}

/// A log that keeps its lines, so a test sees what a failure said.
final class RelayLog: KnitLog {
    private let kept = Lock<[String]>([])

    var lines: [String] { kept.withLock { $0 } }

    func log(_: LogLevel, _ message: @autoclosure () -> String) {
        let line = message()
        kept.withLock { $0.append(line) }
    }
}

extension MemoryPreferences {
    /// The kept relay list, when it reads.
    var keptBook: RelayBook? {
        if case .stored(let book) = relayBook {
            return book
        }
        return nil
    }

    /// Keeps `book` as the app would.
    func keep(_ book: RelayBook) {
        relayBookData = book.encoded
    }
}

/// The relay settings over a stream into `target`, with their preferences and Keychain in memory.
@MainActor
struct RelayRig {
    let preferences: MemoryPreferences
    let secrets: MemoryRelaySecrets
    let phases: MeshPhases
    let log = RelayLog()
    let relays: InternetRelays

    init(
        target: any PhaseTarget, preferences: MemoryPreferences = MemoryPreferences(), secrets: MemoryRelaySecrets = MemoryRelaySecrets(),
        debugBuild: Bool = true
    ) {
        self.preferences = preferences
        self.secrets = secrets
        phases = MeshPhases(target: target)
        relays = InternetRelays(debugBuild: debugBuild, preferences: preferences, secrets: secrets, phases: phases, log: log)
    }

    /// Waits until the stream has told the mesh everything sent before it.
    func flush() async {
        await withCheckedContinuation { continuation in
            phases.send(.remove(SpoolRelayHandle(number: 0))) { continuation.resume() }
        }
    }

    /// Turns the switch on through its sheet.
    func turnOn() throws {
        relays.setSwitch(true)
        relays.confirm(try #require(relays.sheet))
    }

    /// Adds the relay at `url` through an opened invite and its sheet.
    func add(_ url: String) throws {
        relays.offer(opened: Self.invite(url))
        relays.confirm(try #require(relays.sheet, "an invite for \(url) opened a sheet"))
    }

    /// The scheme form of an invite for `url`.
    static func invite(_ url: String) -> String {
        RelayInvite.schemePrefix + RelayInvite.mint(url: url)
    }

    /// The App Link form of an invite for `url`.
    static func appLink(_ url: String) -> String {
        RelayInvite.urlPrefix + RelayInvite.mint(url: url)
    }
}

/// A real mesh whose spool starts paused, dialling through `sockets`, as the live app's does.
func pausedMesh(_ sockets: CountingSockets) throws -> Mesh {
    let identity = try #require(DemoSeed.identity)
    return Mesh(
        identity: identity,
        deviceTag: nil,
        stores: MeshStores.inMemory(),
        radio: DemoRadio(state: .on),
        clock: DemoClock(),
        random: SystemRandomNumberGenerator(),
        spoolSockets: sockets,
        spoolStartsPaused: true
    )
}

/// Waits until `condition` holds; the suite's time limit ends a wait that never does.
func eventually(isolation _: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async {
    while await !condition() {
        await Task.yield()
    }
}
