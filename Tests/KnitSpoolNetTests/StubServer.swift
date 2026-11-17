import Crypto
import Foundation
import KnitSync

/// A WebSocket server on `127.0.0.1` for the adapter's tests (ADR 2026-11.adrq, P5): the oracle for what the socket does on
/// the network. Each connection it accepts plays one ``Answer``, the `n`th connection the `n`th answer and every later one
/// the last, on a thread of its own, and the server records each connection's request head, the bytes it wrote, whether its
/// writes stalled, and when it saw the client's end of the stream (EOF or a reset).
///
/// It binds `127.0.0.1` alone, at a port the kernel picks, read back with `getsockname`, and sets no `SO_REUSEPORT`.
final class StubServer: Sendable {
    /// What a connection is answered with once its request head is read.
    enum Answer: Sendable {
        /// An HTTP answer with no upgrade, its headers as raw bytes.
        case http(status: Int, headers: [(String, [UInt8])])
        /// Nothing: the request is read and never answered.
        case silence
        /// `101 Switching Protocols` with the right `Sec-WebSocket-Accept` and `headers` besides, then `steps`.
        case upgrade(headers: [(String, [UInt8])], steps: [Step])
    }

    /// What an upgraded connection does, in order.
    enum Step: Sendable {
        /// One binary message in one frame.
        case binary([UInt8])
        /// One binary message in one frame, written `chunk` bytes at a time, `pauseMilliseconds` apart.
        case binarySlowly([UInt8], chunk: Int, pauseMilliseconds: Int)
        /// One text message.
        case text(String)
        /// Nothing written for `milliseconds`.
        case pause(milliseconds: Int)
        /// One binary message of `total` bytes, as frames of `frameSize` bytes, the first a binary frame and the rest
        /// continuation frames, the last with FIN.
        case fragments(total: Int, frameSize: Int)
        /// A close frame with `code` and `reason`.
        case close(code: UInt16, reason: [UInt8])
        /// `count` binary messages of `size` bytes, written without blocking until the client stops taking them for
        /// ``stallMilliseconds``.
        case flood(count: Int, size: Int)
        /// One client frame read, unmasked and kept.
        case readFrame
        /// Reads nothing until ``drain()``.
        case holdUnread
        #if canImport(Compression)
            /// One binary message compressed as `permessage-deflate` writes it, RSV1 set, for a client that offered it.
            case deflated([UInt8])
        #endif
    }

    /// One accepted connection, as far as it got.
    struct Connection: Sendable {
        var head = ""
        var written = 0
        var stalled = false
        var frames: [[UInt8]] = []
        /// Whether its flood is over, stalled or written whole.
        var flooded = false
        /// When the client's end of the stream arrived, from when the connection was accepted.
        var endedAfter: Duration?
    }

    /// How long a flood's write may wait for room before it counts as stalled.
    static let stallMilliseconds: Int32 = 1500
    /// The longest request head read.
    private static let maxHead = 16_384
    private static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private struct State {
        var connections: [Connection] = []
        var descriptors: [Int32] = []
        var draining = false
        var stopped = false
    }

    let port: UInt16
    private let listener: Int32
    private let answers: [Answer]
    private let state = Lock(State())
    private let events = StubEvents()

    /// A server answering its connections with `answers` (at least one), or `nil` when no port could be bound.
    init?(_ answers: [Answer]) {
        guard !answers.isEmpty, let (listener, port) = Loopback.listen() else {
            return nil
        }
        self.listener = listener
        self.port = port
        self.answers = answers
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    deinit {
        stop()
    }

    /// The address the stub answers at, with `query` after the path if given.
    func url(query: String? = nil) -> String {
        "ws://127.0.0.1:\(port)/spool/v1" + (query.map { "?\($0)" } ?? "")
    }

    /// Every connection accepted so far.
    var connections: [Connection] { state.withLock { $0.connections } }

    /// Lets every connection held by ``Step/holdUnread`` read again, to its end.
    func drain() {
        state.withLock { $0.draining = true }
        events.changed()
    }

    /// Stops accepting and ends every connection. Each connection's descriptor is shut under the lock its thread closes it
    /// under, so a number the system has since handed to another socket is never touched.
    func stop() {
        let stopping = state.withLock { state -> Bool in
            guard !state.stopped else {
                return false
            }
            state.stopped = true
            state.draining = true
            for descriptor in state.descriptors {
                Loopback.shutdown(descriptor)
            }
            return true
        }
        if stopping {
            Loopback.close(listener)
        }
        events.changed()
    }

    /// Waits until `count` connections were accepted, at most `timeout`.
    func accepted(_ count: Int, within timeout: Duration) async -> Bool {
        await events.wait(within: timeout) { self.connections.count >= count }
    }

    /// Waits until connection `index` saw the client's end, at most `timeout`; answers how long after its accept.
    func ended(_ index: Int, within timeout: Duration) async -> Duration? {
        _ = await events.wait(within: timeout) { self.endedAfter(index) != nil }
        return endedAfter(index)
    }

    /// Waits until connection `index`'s flood stalled or wrote everything, at most `timeout`, and answers the connection.
    func flooded(_ index: Int, within timeout: Duration) async -> Connection? {
        _ = await events.wait(within: timeout) { self.connection(index)?.flooded == true }
        return connection(index)
    }

    private func connection(_ index: Int) -> Connection? {
        state.withLock { $0.connections.count > index ? $0.connections[index] : nil }
    }

    private func endedAfter(_ index: Int) -> Duration? {
        connection(index)?.endedAfter
    }

    // MARK: Serving

    private func acceptLoop() {
        while let descriptor = Loopback.accept(listener) {
            let index = state.withLock { state -> Int? in
                guard !state.stopped else {
                    return nil
                }
                state.connections.append(Connection())
                state.descriptors.append(descriptor)
                return state.connections.count - 1
            }
            guard let index else {
                Loopback.close(descriptor)
                return
            }
            events.changed()
            let answer = answers[min(index, answers.count - 1)]
            let thread = Thread { [self] in serve(descriptor, index: index, answer: answer) }
            thread.start()
        }
    }

    private func serve(_ descriptor: Int32, index: Int, answer: Answer) {
        let accepted = ContinuousClock.now
        defer {
            state.withLock { state in
                state.descriptors.removeAll { $0 == descriptor }
                Loopback.close(descriptor)
            }
            events.changed()
        }
        guard let head = readHead(descriptor) else {
            record(index) { $0.endedAfter = ContinuousClock.now - accepted }
            return
        }
        record(index) { $0.head = head }
        switch answer {
        case .http(let status, let headers):
            // `Connection: close`, so the client never sends a second request down this one.
            write(descriptor, index, Self.response(status: status, headers: headers + [("Connection", Array("close".utf8))]))
            Loopback.shutdownWrite(descriptor)
        case .silence:
            break
        case .upgrade(let headers, let steps):
            let key = Self.header("Sec-WebSocket-Key", in: head) ?? ""
            let accept = Array((key + Self.acceptGUID).utf8)
            let digest = Data(Insecure.SHA1.hash(data: accept)).base64EncodedString()
            write(descriptor, index, Self.response(status: 101, headers: Self.upgradeHeaders(accept: digest) + headers))
            for step in steps {
                run(step, descriptor, index)
            }
        }
        if case .upgrade(_, let steps) = answer, steps.contains(where: Self.holds) {
            _ = events.blockingWait { self.state.withLock { $0.draining } }
        }
        // Reads until the client's end: data, then EOF or a reset.
        while Loopback.read(descriptor) != nil {
            // Whatever the client still sends is read and dropped.
        }
        record(index) { $0.endedAfter = ContinuousClock.now - accepted }
    }

    private static func holds(_ step: Step) -> Bool {
        if case .holdUnread = step { true } else { false }
    }

    private func run(_ step: Step, _ descriptor: Int32, _ index: Int) {
        switch step {
        case .binary(let bytes):
            write(descriptor, index, Self.frame(opcode: 0x2, bytes))
        case .binarySlowly(let bytes, let chunk, let pauseMilliseconds):
            let frame = Self.frame(opcode: 0x2, bytes)
            var offset = 0
            while offset < frame.count {
                let end = min(offset + chunk, frame.count)
                guard write(descriptor, index, Array(frame[offset..<end])) else {
                    return
                }
                offset = end
                // The server is slow on purpose: this is the peer's pace, not a test waiting.
                Thread.sleep(forTimeInterval: TimeInterval(pauseMilliseconds) / 1000)
            }
        case .text(let text):
            write(descriptor, index, Self.frame(opcode: 0x1, Array(text.utf8)))
        case .pause(let milliseconds):
            // The server is quiet on purpose: this is the peer's pace, not a test waiting.
            Thread.sleep(forTimeInterval: TimeInterval(milliseconds) / 1000)
        case .fragments(let total, let frameSize):
            var sent = 0
            while sent < total {
                let size = min(frameSize, total - sent)
                let opcode: UInt8 = sent == 0 ? 0x2 : 0x0
                guard write(descriptor, index, Self.frame(opcode: opcode, [UInt8](repeating: 0x5A, count: size), fin: sent + size == total))
                else {
                    return
                }
                sent += size
            }
        case .close(let code, let reason):
            write(descriptor, index, Self.frame(opcode: 0x8, [UInt8(code >> 8), UInt8(code & 0xFF)] + reason))
        case .flood(let count, let size):
            flood(descriptor, index, count: count, size: size)
        case .readFrame:
            if let frame = Self.readFrame(descriptor) {
                record(index) { $0.frames.append(frame) }
            }
        case .holdUnread:
            break
        #if canImport(Compression)
            case .deflated(let bytes):
                write(descriptor, index, Self.frame(opcode: 0x2, Self.deflate(bytes), compressed: true))
        #endif
        }
    }

    private func flood(_ descriptor: Int32, _ index: Int, count: Int, size: Int) {
        Loopback.setBlocking(descriptor, false)
        defer {
            Loopback.setBlocking(descriptor, true)
            record(index) { $0.flooded = true }
        }
        let frame = Self.frame(opcode: 0x2, [UInt8](repeating: 0xA5, count: size))
        for _ in 0..<count {
            var offset = 0
            while offset < frame.count {
                let wrote = Loopback.write(descriptor, Array(frame[offset...]))
                offset += wrote
                record(index) { $0.written += wrote }
                if offset < frame.count, !Loopback.waitWritable(descriptor, milliseconds: Self.stallMilliseconds) {
                    record(index) { $0.stalled = true }
                    return
                }
            }
        }
    }

    @discardableResult
    private func write(_ descriptor: Int32, _ index: Int, _ bytes: [UInt8]) -> Bool {
        let wrote = Loopback.write(descriptor, bytes)
        record(index) { $0.written += wrote }
        return wrote == bytes.count
    }

    private func record(_ index: Int, _ change: (inout Connection) -> Void) {
        state.withLock { change(&$0.connections[index]) }
        events.changed()
    }

    /// The request head, up to and including the blank line, as text; `nil` if the stream ends first or runs past
    /// ``maxHead``.
    private func readHead(_ descriptor: Int32) -> String? {
        var bytes: [UInt8] = []
        let end = Array("\r\n\r\n".utf8)
        while !bytes.suffix(end.count).elementsEqual(end) {
            guard bytes.count < Self.maxHead, let byte = Loopback.read(descriptor, limit: 1) else {
                return nil
            }
            bytes += byte
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
