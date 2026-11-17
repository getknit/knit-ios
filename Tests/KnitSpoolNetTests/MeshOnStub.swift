#if canImport(Darwin)
    import KnitCrypto
    import KnitStore
    import KnitSync
    import KnitWire
    import Testing

    @testable import KnitMesh
    @testable import KnitSpoolNet

    /// A ``Mesh`` whose one relay is a stub server, dialled through the real ``URLSessionSpoolSocketFactory`` wrapped in a
    /// ``RecordingFactory``, on a ``StepClock`` the test moves and a radio that goes nowhere (ADR 2026-11.adrq, P5): the
    /// plane's half of the stub cases. The mesh holds the factory, as the app's does, for its life.
    struct MeshOnStub {
        static let relay = SpoolRelayHandle(number: 1)

        let mesh: Mesh
        let clock: StepClock
        let log: LineLog
        let factory: RecordingFactory

        /// A started mesh, its relay added at `url`.
        static func make(_ url: String) async throws -> Self {
            let keys = try #require(
                IdentityKeys(signingSeed: Array(repeating: 7, count: 32), agreementScalar: Array(repeating: 9, count: 32)))
            let accepted = try #require(AcceptedSpoolURL(url, allowCleartext: true))
            let lines = LineLog()
            let rig = Self(clock: StepClock(), log: lines, factory: RecordingFactory(URLSessionSpoolSocketFactory(log: lines)), keys: keys)
            await rig.mesh.start()
            #expect(await rig.mesh.addSpoolRelay(Self.relay, url: accepted))
            return rig
        }

        private init(clock: StepClock, log: LineLog, factory: RecordingFactory, keys: IdentityKeys) {
            self.clock = clock
            self.log = log
            self.factory = factory
            mesh = Mesh(
                identity: keys,
                deviceTag: nil,
                stores: .inMemory(),
                radio: SilentRadio(),
                clock: clock,
                random: SplitMix(seed: 3),
                log: log,
                spoolSockets: factory
            )
        }

        /// The relay's line in `status`.
        func relayStatus() async -> SpoolStatus.Relay? {
            await mesh.spoolStatus.relays.first
        }

        /// Waits until `holds` reads true of the mesh, at most `timeout`.
        func eventually(within timeout: Duration = .seconds(10), _ holds: @Sendable (Mesh) async -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if await holds(mesh) {
                    return true
                }
                await Task.yield()
            }
            return await holds(mesh)
        }
    }

    /// A ``SpoolSocketFactory`` around another that records every dial's outcome and every message its sockets hand the plane,
    /// so a test reads what reached the plane, as the plane got it.
    final class RecordingFactory: SpoolSocketFactory {
        private let inner: any SpoolSocketFactory
        private let kept = Lock<(failures: [SpoolDialFailure], messages: [SpoolSocketMessage])>(([], []))

        init(_ inner: any SpoolSocketFactory) {
            self.inner = inner
        }

        var failures: [SpoolDialFailure] { kept.withLock { $0.failures } }
        var messages: [SpoolSocketMessage] { kept.withLock { $0.messages } }

        func open(_ url: AcceptedSpoolURL) async -> SpoolDial {
            switch await inner.open(url) {
            case .failed(let failure):
                kept.withLock { $0.failures.append(failure) }
                return .failed(failure)
            case .opened(let socket):
                return .opened(Recorded(socket, factory: self))
            }
        }

        func note(_ message: SpoolSocketMessage) {
            kept.withLock { $0.messages.append(message) }
        }

        private final class Recorded: SpoolSocket {
            let socket: any SpoolSocket
            let factory: RecordingFactory

            init(_ socket: any SpoolSocket, factory: RecordingFactory) {
                self.socket = socket
                self.factory = factory
            }

            func receive() async -> SpoolSocketMessage {
                let message = await socket.receive()
                factory.note(message)
                return message
            }

            func send(_ bytes: [UInt8]) async -> Bool {
                await socket.send(bytes)
            }

            func close(code: Int) {
                socket.close(code: code)
            }
        }
    }

    /// A clock the test moves, waking each sleeper whose deadline it reaches.
    final class StepClock: MeshClock {
        private struct State {
            var wall: Int64 = 1_763_000_000_000
            var monotonic: Int64 = 1000
            var sleepers: [Int: (deadline: Int64, wake: CheckedContinuation<Void, any Error>)] = [:]
            var cancelled: Set<Int> = []
            var next = 0
        }

        private enum Wake {
            case now
            case cancel
            case later
        }

        private let state = Lock(State())

        func wallMilliseconds() -> Int64 {
            state.withLock { $0.wall }
        }

        func monotonicMilliseconds() -> Int64 {
            state.withLock { $0.monotonic }
        }

        /// Moves both clocks on by `milliseconds` and wakes every sleeper now due.
        func advance(_ milliseconds: Int64) {
            let due = state.withLock { state in
                state.wall += milliseconds
                state.monotonic += milliseconds
                let now = state.monotonic
                let due = state.sleepers.filter { $0.value.deadline <= now }
                for token in due.keys {
                    state.sleepers[token] = nil
                }
                return due.values.map(\.wake)
            }
            for wake in due {
                wake.resume()
            }
        }

        func sleep(untilMonotonic deadline: Int64) async throws {
            let token = state.withLock { state in
                defer { state.next += 1 }
                return state.next
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let now = state.withLock { state -> Wake in
                        if state.cancelled.remove(token) != nil {
                            return .cancel
                        }
                        guard deadline > state.monotonic else {
                            return .now
                        }
                        state.sleepers[token] = (deadline, continuation)
                        return .later
                    }
                    switch now {
                    case .now:
                        continuation.resume()
                    case .cancel:
                        continuation.resume(throwing: CancellationError())
                    case .later:
                        break
                    }
                }
            } onCancel: {
                let sleeper = state.withLock { state in
                    guard let sleeper = state.sleepers.removeValue(forKey: token) else {
                        state.cancelled.insert(token)
                        return nil as CheckedContinuation<Void, any Error>?
                    }
                    return sleeper.wake
                }
                sleeper?.resume(throwing: CancellationError())
            }
        }
    }

    /// A radio that reports nothing and links nobody: the mesh's relay is its only way out.
    final class SilentRadio: Radio {
        let advertisesServiceData = false
        let dialsGattPeers = false
        let servesDoorbell = false
        let events: AsyncStream<RadioEvent>
        private let continuation: AsyncStream<RadioEvent>.Continuation

        init() {
            (events, continuation) = AsyncStream<RadioEvent>.makeStream()
        }

        deinit {
            continuation.finish()
        }

        func start() {
            // Nothing to power: the radio goes nowhere.
        }

        func stop() {
            // Nothing is open.
        }

        func advertise(_: AdvertPayload) {
            // Nobody hears it.
        }

        func dial(_: RadioAddress, psm _: UInt16) -> ChannelID {
            continuation.yield(.dialFailed(ChannelID(0)))
            return ChannelID(0)
        }

        func write(_: [UInt8], to _: ChannelID) {
            // No channel is ever open.
        }

        func writeKeyShare(_: [UInt8], sealer _: LinkSealer?, to _: ChannelID) {
            // No channel is ever open.
        }

        func seal(_: ChannelID, with _: LinkSealer) {
            // No channel is ever open.
        }

        func close(_: ChannelID) {
            // No channel is ever open.
        }
    }
#endif
