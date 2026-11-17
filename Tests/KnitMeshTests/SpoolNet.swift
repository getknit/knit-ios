import KnitSync
import KnitWire
import Testing

@testable import KnitMesh

/// Test sockets over one ``FakeSpool`` (ADR 2026-11.adrq, P4b1): the ``SpoolSocketFactory`` two ``Mesh``es dial in the
/// connection tests, in place of a later phase's `URLSessionWebSocketTask` adapter.
///
/// A socket hands its reader one message per ``SpoolSocket/receive()``, from what the spool sent on its connection, and
/// counts a receive that came while another was waiting (``overlappingReceives``), which the plane's pull-based reader must
/// never do. A send writes straight into the spool and returns, unless ``neverReads`` holds it until the socket closes.
/// Dials can be refused (``refusals``) or held until released (``holdsOpens``), and ``advance(to:)`` moves the spool's clock.
final class SpoolNet: SpoolSocketFactory {
    struct Socket {
        let connection: FakeSpool.Connection
        let tag: Int
        var queue: [SpoolSocketMessage] = []
        var reader: CheckedContinuation<SpoolSocketMessage, Never>?
        var end: SpoolSocketEnd?
        var stuck: [CheckedContinuation<Bool, Never>] = []
    }

    struct State {
        let spool: FakeSpool
        var sockets: [Int: Socket] = [:]
        var nextSocket = 1
        var refusals: [SpoolDialFailure] = []
        var holdsOpens = false
        var held: [CheckedContinuation<Void, Never>] = []
        var neverReads = false
        var dials = 0
        var receives = 0
        var sends = 0
        var overlapping = 0
        var sent: [(tag: Int, record: SpoolRecord)] = []
        var flood: [UInt8]?
        var floodDelivered = 0
    }

    /// The factory one mesh dials through: its sockets carry `tag`, so a test reads what each mesh sent.
    struct Door: SpoolSocketFactory {
        let net: SpoolNet
        let tag: Int

        func open(_ url: AcceptedSpoolURL) async -> SpoolDial {
            await net.open(url, tag: tag)
        }
    }

    /// The door for the mesh numbered `tag`.
    func door(_ tag: Int) -> Door {
        Door(net: self, tag: tag)
    }

    /// Every record the mesh numbered `tag` sent, in order.
    func sent(by tag: Int) -> [SpoolRecord] {
        state.withLock { $0.sent.filter { $0.tag == tag }.map(\.record) }
    }

    /// The bytes the spool served the sockets of the mesh numbered `tag`.
    func served(to tag: Int) -> Int {
        state.withLock { state in
            state.sockets.values.filter { $0.tag == tag }.reduce(0) { $0 + (state.spool.servedTo[$1.connection] ?? 0) }
        }
    }

    /// Forgets the records sent so far.
    func forgetSent() {
        state.withLock { $0.sent.removeAll() }
    }

    /// Closes every open socket from the spool's side with `code`.
    func dropAll(code: Int = SpoolCloseCode.goingAway) {
        state.withLock { state in
            for id in state.sockets.keys {
                guard let socket = state.sockets[id], socket.end == nil else {
                    continue
                }
                Self.pull(&state, id)
                state.sockets[id]?.queue.append(.closed(SpoolSocketEnd(.closed, code: code)))
                state.spool.drop(socket.connection)
            }
        }
        wake()
    }

    let state: Lock<State>

    init(spool: FakeSpool) {
        state = Lock(State(spool: spool))
    }

    /// Runs `body` on the spool, then hands every waiting reader what arrived.
    func withSpool<T>(_ body: (FakeSpool) -> T) -> T {
        let result = state.withLock { body($0.spool) }
        wake()
        return result
    }

    /// Moves the spool's clock to `wall`.
    func advance(to wall: Int64) {
        withSpool { $0.advance(to: wall) }
    }

    /// Dial failures handed out in order before any dial opens again.
    func refuse(_ failures: [SpoolDialFailure]) {
        state.withLock { $0.refusals += failures }
    }

    /// Whether a dial waits, cancelled or not, until ``releaseOpens()`` before it opens.
    var holdsOpens: Bool {
        get { state.withLock { $0.holdsOpens } }
        set { state.withLock { $0.holdsOpens = newValue } }
    }

    /// Lets every held dial open.
    func releaseOpens() {
        let held = state.withLock { state in
            defer { state.held.removeAll() }
            return state.held
        }
        for open in held {
            open.resume()
        }
    }

    /// Dials waiting in ``holdsOpens``.
    var heldOpens: Int { state.withLock { $0.held.count } }

    var neverReads: Bool {
        get { state.withLock { $0.neverReads } }
        set { state.withLock { $0.neverReads = newValue } }
    }

    /// Queues `count` copies of `bytes` straight onto every open socket, past the spool: junk the plane must drop.
    func flood(_ bytes: [UInt8], count: Int) {
        state.withLock { state in
            state.flood = bytes
            for id in state.sockets.keys where state.sockets[id]?.end == nil {
                state.sockets[id]?.queue += Array(repeating: .binary(bytes), count: count)
            }
        }
        wake()
    }

    /// Activity so far: dials, receives and sends, for a test to see that nothing moves any more.
    var activity: [Int] {
        state.withLock { state in
            [state.dials, state.receives, state.sends, state.sockets.values.reduce(0) { $0 + $1.queue.count }]
        }
    }

    /// Flood records handed to a reader.
    var floodDelivered: Int { state.withLock { $0.floodDelivered } }

    /// Receives that came while another was waiting on the same socket.
    var overlappingReceives: Int { state.withLock { $0.overlapping } }

    /// Messages waiting on open sockets.
    var queued: Int { state.withLock { $0.sockets.values.reduce(0) { $0 + ($1.end == nil ? $1.queue.count : 0) } } }

    var dials: Int { state.withLock { $0.dials } }
}

extension SpoolNet {
    // MARK: SpoolSocketFactory

    func open(_ url: AcceptedSpoolURL) async -> SpoolDial {
        await open(url, tag: 0)
    }

    func open(_: AcceptedSpoolURL, tag: Int) async -> SpoolDial {
        if holdsOpens {
            await withCheckedContinuation { continuation in
                state.withLock { $0.held.append(continuation) }
            }
        }
        enum Decision {
            case failed(SpoolDialFailure)
            case opened(Int)
        }
        let decision = state.withLock { state -> Decision in
            state.dials += 1
            let id = state.nextSocket
            state.nextSocket += 1
            if !state.refusals.isEmpty {
                return .failed(state.refusals.removeFirst())
            }
            state.sockets[id] = Socket(connection: state.spool.connect(), tag: tag)
            return .opened(id)
        }
        switch decision {
        case .failed(let failure):
            return .failed(failure)
        case .opened(let id):
            wake()
            return .opened(TestSpoolSocket(net: self, id: id))
        }
    }

    // MARK: The sockets' side

    func receive(_ id: Int) async -> SpoolSocketMessage {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> SpoolSocketMessage? in
                state.receives += 1
                Self.pull(&state, id)
                guard var socket = state.sockets[id] else {
                    return .closed(SpoolSocketEnd(.closed))
                }
                if !socket.queue.isEmpty {
                    let message = socket.queue.removeFirst()
                    state.sockets[id] = socket
                    Self.count(message, &state)
                    return message
                }
                if let end = socket.end {
                    return .closed(end)
                }
                if socket.reader != nil {
                    state.overlapping += 1
                }
                socket.reader = continuation
                state.sockets[id] = socket
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }

    func send(_ bytes: [UInt8], _ id: Int) async -> Bool {
        enum Write {
            case closed
            case written
            case held
        }
        let write = state.withLock { state -> Write in
            guard let socket = state.sockets[id], socket.end == nil else {
                return .closed
            }
            state.sends += 1
            if let record = SpoolRecord(decoding: bytes) {
                state.sent.append((socket.tag, record))
            }
            guard !state.neverReads else {
                return .held
            }
            state.spool.receive(bytes, from: socket.connection)
            return .written
        }
        switch write {
        case .closed:
            return false
        case .written:
            wake()
            return true
        case .held:
            break
        }
        return await withCheckedContinuation { continuation in
            let closed = state.withLock { state -> Bool in
                guard state.sockets[id]?.end == nil else {
                    return true
                }
                state.sockets[id]?.stuck.append(continuation)
                return false
            }
            if closed {
                continuation.resume(returning: false)
            }
        }
    }

    func close(_ id: Int, code: Int) {
        typealias Waiting = (CheckedContinuation<SpoolSocketMessage, Never>?, [CheckedContinuation<Bool, Never>])
        let (reader, stuck) = state.withLock { state -> Waiting in
            guard var socket = state.sockets[id], socket.end == nil else {
                return (nil, [])
            }
            state.spool.drop(socket.connection)
            let end = SpoolSocketEnd(.cancelled, code: code)
            socket.end = end
            socket.queue.removeAll()
            let reader = socket.reader
            let stuck = socket.stuck
            socket.reader = nil
            socket.stuck = []
            state.sockets[id] = socket
            return (reader, stuck)
        }
        reader?.resume(returning: .closed(SpoolSocketEnd(.cancelled, code: code)))
        for send in stuck {
            send.resume(returning: false)
        }
    }

    /// Moves what the spool sent each socket onto its queue, a spool close as the socket's end.
    static func pull(_ state: inout State, _ id: Int) {
        guard var socket = state.sockets[id], socket.end == nil else {
            return
        }
        for outgoing in state.spool.take(socket.connection) {
            switch outgoing {
            case .record(let bytes):
                socket.queue.append(.binary(bytes))
            case .close(let code):
                socket.queue.append(.closed(SpoolSocketEnd(.closed, code: code)))
                state.spool.drop(socket.connection)
            }
        }
        state.sockets[id] = socket
    }

    static func count(_ message: SpoolSocketMessage, _ state: inout State) {
        if case .binary(let bytes) = message, bytes == state.flood {
            state.floodDelivered += 1
        }
    }

    /// Hands each waiting reader its next message.
    func wake() {
        let due = state.withLock { state -> [(CheckedContinuation<SpoolSocketMessage, Never>, SpoolSocketMessage)] in
            var due: [(CheckedContinuation<SpoolSocketMessage, Never>, SpoolSocketMessage)] = []
            for id in state.sockets.keys {
                Self.pull(&state, id)
                guard var socket = state.sockets[id], let reader = socket.reader, !socket.queue.isEmpty else {
                    continue
                }
                socket.reader = nil
                let message = socket.queue.removeFirst()
                Self.count(message, &state)
                due.append((reader, message))
                state.sockets[id] = socket
            }
            return due
        }
        for (reader, message) in due {
            reader.resume(returning: message)
        }
    }
}

/// One socket of a ``SpoolNet``.
final class TestSpoolSocket: SpoolSocket, CustomStringConvertible, CustomReflectable {
    private let net: SpoolNet
    private let id: Int

    init(net: SpoolNet, id: Int) {
        self.net = net
        self.id = id
    }

    var description: String { "test socket \(id)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }

    func receive() async -> SpoolSocketMessage {
        await net.receive(id)
    }

    func send(_ bytes: [UInt8]) async -> Bool {
        await net.send(bytes, id)
    }

    func close(code: Int) {
        net.close(id, code: code)
    }
}

/// Every access a socket task makes goes through ``SpoolNet``'s lock, and a test reads the spool only once its rig has
/// settled, so no two threads touch it at once; TSan runs over the suites that share it.
extension FakeSpool: @unchecked Sendable {}
