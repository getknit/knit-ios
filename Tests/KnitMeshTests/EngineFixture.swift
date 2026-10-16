import KnitCrypto
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire

@testable import KnitMesh

/// One engine under test, on a clock and a transport the test controls.
struct EngineFixture {
    /// Two days into the epoch's 2025, so a stamp of 0 is long dead and every TTL has room.
    static let start: Int64 = 1_756_200_000_000

    let me: TestPeer
    let clock: ManualClock
    let transport: RecordingTransport
    let stores: MeshStores
    let log = RecordingLog()
    let engine: MeshEngine

    /// An engine for `me`, keeping `prekeys` when given, its wall clock at `wall`, started unless told otherwise. It draws
    /// frame ids and jitter from `seed`, which two engines that talk to each other must not share, or their ids collide.
    /// Its ratchet draws from `ratchetEngine` when a vector replay passes one, and from the system's generator otherwise.
    init(
        _ me: TestPeer,
        stores: MeshStores = .inMemory(),
        configuration: MeshConfiguration = MeshConfiguration(),
        prekeys: PrekeyRing? = nil,
        wall: Int64 = Self.start,
        started: Bool = true,
        seed: UInt64 = 7,
        ratchetEngine: RatchetEngine = RatchetEngine()
    ) {
        self.me = me
        clock = ManualClock(wall: wall, monotonic: 1000)
        transport = RecordingTransport()
        self.stores = stores
        engine = MeshEngine(
            identity: me.keys,
            prekeys: prekeys,
            deviceTag: "0011223344556677",
            stores: stores,
            transport: transport,
            clock: clock,
            random: SeededGenerator(seed: seed),
            configuration: configuration,
            log: log,
            ratchetEngine: ratchetEngine
        )
        if started {
            engine.start()
        }
    }

    /// Links `peers`, as the link layer would before telling the engine, each with the capabilities its HELLO claimed.
    func link(_ peers: TestPeer..., capabilities: Capabilities = .local) {
        for peer in peers {
            let neighbor = Neighbor(nodeId: peer.nodeId, capabilities: capabilities)
            transport.neighbors.append(neighbor)
            engine.linkUp(neighbor)
        }
    }

    /// Takes `peer`'s link down, as the link layer would before telling the engine.
    func unlink(_ peer: TestPeer) {
        transport.neighbors.removeAll { $0.nodeId == peer.nodeId }
        engine.linkDown(peer.nodeId)
    }

    /// Pins `peer`'s profile by delivering it from `peer` itself.
    func pin(_ peer: TestPeer) throws {
        deliver(try peer.profile(publishedAt: clock.wallMilliseconds()), from: peer)
    }

    /// Hands the engine a frame from `neighbor`.
    func deliver(_ frame: TestFrame, from neighbor: TestPeer) {
        engine.receive(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: neighbor.nodeId))
    }

    /// Moves time on and fires whatever is due.
    func advance(_ milliseconds: Int64) {
        clock.advance(milliseconds)
        engine.advance()
    }
}

/// A frame and its decoded envelope.
struct TestFrame: Equatable {
    var wire: WireEnvelope
    var envelope: RelayEnvelope
}

/// A peer that signs its own frames, with fixed keys.
struct TestPeer: Equatable {
    let keys: IdentityKeys

    init(seed: Int) {
        let signing = fixtureBytes(32, seed: seed)
        guard let made = IdentityKeys(signingSeed: signing, agreementScalar: fixtureBytes(32, seed: seed + 100)) else {
            fatalError("fixed seeds make valid keys")
        }
        keys = made
    }

    /// A peer with `keys`, such as a vector's identity.
    init(keys: IdentityKeys) {
        self.keys = keys
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.nodeId == rhs.nodeId }

    var nodeId: NodeId { keys.nodeId }

    func signed(_ envelope: RelayEnvelope, relay: Bool = true) throws -> TestFrame {
        let signed = envelope.encoded
        return TestFrame(wire: WireEnvelope(relay: relay, sig: try keys.signature(for: signed), signed: signed), envelope: envelope)
    }

    func profile(
        name: String = "Peer",
        version: Int64? = nil,
        publishedAt: Int64,
        relay: Bool = true,
        avatarHash: String? = nil,
        deviceTag: String? = nil,
        capabilities: Int64 = 0xFFF,
        prekey: PrekeyInfo? = nil
    ) throws -> TestFrame {
        let content = ProfileContent(
            name: name,
            status: "",
            avatarHash: avatarHash,
            pubKey: keys.bundle.encoded,
            deviceTag: deviceTag,
            protoVersion: WireProtocol.version,
            capabilities: capabilities,
            prekey: prekey,
            version: version
        )
        let envelope = RelayEnvelope(
            type: .profile,
            id: "profile-\(nodeId)-\(publishedAt)",
            senderId: nodeId.string,
            sentAt: publishedAt,
            payload: content.encoded
        )
        return try signed(envelope, relay: relay)
    }

    /// Prekey `id` as this peer would publish it, signed by its own key, its pair fixed by `id`.
    func prekey(id: Int) throws -> PrekeyInfo {
        let pair = try RatchetCrypto.KeyPair(privateKey: fixtureBytes(32, seed: 200 + id))
        return try SignedPrekey.mint(id: id, signedBy: keys, createdAt: 0) { pair }.info
    }

    /// A room post from this peer: `body`, or the whole of `content` when it is given.
    func roomPost(_ body: String, id: String, sentAt: Int64, content: ChatContent? = nil) throws -> TestFrame {
        let payload = (content ?? ChatContent(body: body)).encoded
        return try signed(RelayEnvelope(type: .chat, id: id, senderId: nodeId.string, sentAt: sentAt, payload: payload))
    }

    func directMessage(
        _ body: String,
        to recipient: Self,
        id: String,
        sentAt: Int64,
        content: MessageContent? = nil
    ) throws -> TestFrame {
        let header = MessageCrypto.header(id: id, senderId: nodeId.string, sentAt: sentAt, thread: recipient.nodeId.string)
        let plaintext = (content ?? MessageContent(body: body)).encoded
        guard let sealed = try MessageCrypto.seal(plaintext, header: header, to: [recipient.nodeId: recipient.keys.bundle]) else {
            fatalError("one recipient always seals")
        }
        let envelope = RelayEnvelope(
            type: .chat,
            id: id,
            senderId: nodeId.string,
            sentAt: sentAt,
            recipientId: recipient.nodeId.string,
            payload: ChatContent(enc: sealed).encoded
        )
        return try signed(envelope)
    }

    func receipt(for ackId: String, id: String, sentAt: Int64 = 0, relay: Bool = true) throws -> TestFrame {
        let payload = ReceiptContent(ackId: ackId).encoded
        return try signed(RelayEnvelope(type: .receipt, id: id, senderId: nodeId.string, sentAt: sentAt, payload: payload), relay: relay)
    }

    func keyRequest(for ids: [NodeId], id: String) throws -> TestFrame {
        let envelope = RelayEnvelope(
            type: .keyRequest,
            id: id,
            senderId: nodeId.string,
            payload: KeyRequestContent(nodeIds: ids.map(\.string)).encoded
        )
        return try signed(envelope, relay: false)
    }
}

/// A clock the test moves by hand. A sleeper wakes when the clock passes its deadline, or throws when its task is
/// cancelled. A test that moves the clock while the mesh is still working reads a different time from one moment to
/// the next, so it awaits ``parked(until:)`` first.
final class ManualClock: MeshClock {
    private struct State {
        var wall: Int64
        var monotonic: Int64
        var sleepers: [Int: (deadline: Int64, wake: CheckedContinuation<Void, any Error>)] = [:]
        /// Tests awaiting a sleeper for a deadline.
        var watchers: [Int: (deadline: Int64, wake: CheckedContinuation<Void, Never>)] = [:]
        /// Tokens cancelled before their sleeper or watcher was registered.
        var cancelled: Set<Int> = []
        var nextToken = 0
    }

    private enum Registration {
        /// Parked, waking the tests that awaited this deadline.
        case wait([CheckedContinuation<Void, Never>])
        case wake
        case cancel
    }

    private let state: Lock<State>

    init(wall: Int64, monotonic: Int64) {
        state = Lock(State(wall: wall, monotonic: monotonic))
    }

    func wallMilliseconds() -> Int64 {
        state.withLock { $0.wall }
    }

    func monotonicMilliseconds() -> Int64 {
        state.withLock { $0.monotonic }
    }

    /// Moves both clocks on, and wakes every sleeper now due.
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
            defer { state.nextToken += 1 }
            return state.nextToken
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let registration = state.withLock { state -> Registration in
                    if state.cancelled.remove(token) != nil {
                        return .cancel
                    }
                    guard deadline > state.monotonic else {
                        return .wake
                    }
                    state.sleepers[token] = (deadline, continuation)
                    let watching = state.watchers.filter { $0.value.deadline == deadline }
                    for watcher in watching.keys {
                        state.watchers[watcher] = nil
                    }
                    return .wait(watching.values.map(\.wake))
                }
                switch registration {
                case .wait(let watchers):
                    for watcher in watchers {
                        watcher.resume()
                    }
                case .wake:
                    continuation.resume()
                case .cancel:
                    continuation.resume(throwing: CancellationError())
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

    /// Returns once a sleeper waits for `deadline`: the mesh has finished the work that set its timer, and moving the
    /// clock now cannot land between its reads. Returns early when the test is cancelled, to fail on what follows.
    func parked(until deadline: Int64) async {
        let token = state.withLock { state in
            defer { state.nextToken += 1 }
            return state.nextToken
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked = state.withLock { state in
                    if state.cancelled.remove(token) != nil || state.sleepers.values.contains(where: { $0.deadline == deadline }) {
                        return true
                    }
                    state.watchers[token] = (deadline, continuation)
                    return false
                }
                if parked {
                    continuation.resume()
                }
            }
        } onCancel: {
            let watcher = state.withLock { state in
                guard let watcher = state.watchers.removeValue(forKey: token) else {
                    state.cancelled.insert(token)
                    return nil as CheckedContinuation<Void, Never>?
                }
                return watcher.wake
            }
            watcher?.resume()
        }
    }

    /// How many sleepers wait, for a test that must know a timer is parked.
    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }
}

/// A log that keeps every line, so a test can read what the mesh said and every message is built.
final class RecordingLog: KnitLog {
    private let lines = Lock<[String]>([])

    func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        let line = "\(level) \(message())"
        lines.withLock { $0.append(line) }
    }

    /// Every line so far.
    var all: [String] {
        lines.withLock { $0 }
    }
}

/// SplitMix64, so a run draws the same jitter and frame ids every time.
struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
