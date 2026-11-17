import Crypto
import Foundation
import KnitSync
import KnitWire

@testable import KnitMesh

/// A `ws://` client over plain TCP, test-only (ADR 2026-11.adrq, P5): what drives the reference daemon from Linux, where
/// FoundationNetworking's WebSocket rides a libcurl built without `ws`. It never ships: no target under `Sources/` can name
/// it (`SpoolNetIsolationTests`).
///
/// It dials `127.0.0.1` and `localhost` alone, checks the upgrade's `Sec-WebSocket-Accept`, masks every frame it writes,
/// refuses a message past ``SpoolRecordLayer/maxInboundRecord`` before buffering more of it, answers a ping, and ends on a
/// close, keeping its code and dropping its reason. It keeps the ``SpoolSocket`` contract: pulled reads, one send at a time,
/// fault words.
final class SpoolTestSockets: SpoolSocketFactory {
    /// What the sockets have done, for a rig waiting until they go quiet.
    struct Activity: Sendable, Equatable {
        var dials = 0
        var received = 0
        var sent = 0
        var sending = 0
    }

    private let activity = Lock(Activity())

    var now: Activity { activity.withLock { $0 } }

    func open(_ url: AcceptedSpoolURL) async -> SpoolDial {
        activity.withLock { $0.dials += 1 }
        return await Self.dial(url.socketURLText, sockets: self)
    }

    func note(_ change: (inout Activity) -> Void) {
        activity.withLock { change(&$0) }
    }

    /// Dials `text` raw, outside the factory's contract: the private relay's case alone, whose `?k=` no `ws://` address the
    /// plane takes may carry.
    static func dial(raw text: String) async -> SpoolDial {
        await dial(text, sockets: nil)
    }

    private static func dial(_ text: String, sockets: SpoolTestSockets?) async -> SpoolDial {
        guard let target = Target(text) else {
            return .failed(SpoolDialFailure(.unreachable))
        }
        return await withCheckedContinuation { continuation in
            Thread {
                continuation.resume(returning: open(target, sockets: sockets))
            }.start()
        }
    }

    /// A loopback address: `ws://127.0.0.1:<port><path>` or `ws://localhost:<port><path>`.
    struct Target {
        let port: UInt16
        let path: String

        init?(_ text: String) {
            let hosts = ["ws://127.0.0.1:", "ws://localhost:"]
            guard let prefix = hosts.first(where: text.hasPrefix) else {
                return nil
            }
            let rest = text.dropFirst(prefix.count)
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard let number = UInt16(digits), number > 0, rest.dropFirst(digits.count).first == "/" else {
                return nil
            }
            port = number
            path = String(rest.dropFirst(digits.count))
        }
    }

    private static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    private static let maxHead = 16_384

    /// Connects, upgrades and checks the answer, on the calling thread.
    private static func open(_ target: Target, sockets: SpoolTestSockets?) -> SpoolDial {
        guard let descriptor = SpoolTestTCP.connect(port: target.port) else {
            return .failed(SpoolDialFailure(.unreachable))
        }
        var nonce = SystemRandomNumberGenerator()
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &nonce) }).base64EncodedString()
        let request =
            "GET \(target.path) HTTP/1.1\r\nHost: 127.0.0.1:\(target.port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        guard SpoolTestTCP.write(descriptor, Array(request.utf8)), let head = readHead(descriptor) else {
            SpoolTestTCP.close(descriptor)
            return .failed(SpoolDialFailure(.unreachable))
        }
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first.flatMap { line in line.split(separator: " ").dropFirst().first.flatMap { Int($0) } }
        guard status == 101 else {
            SpoolTestTCP.close(descriptor)
            let retryAfter = header("Retry-After", in: lines).map { SpoolRetryAfter(header: Array($0.utf8)) }
            return .failed(SpoolDialFailure(.http, status: status, retryAfter: retryAfter))
        }
        let expected = Data(Insecure.SHA1.hash(data: Array((key + acceptGUID).utf8))).base64EncodedString()
        guard header("Sec-WebSocket-Accept", in: lines) == expected else {
            SpoolTestTCP.close(descriptor)
            return .failed(SpoolDialFailure(.protocolError))
        }
        return .opened(SpoolTestSocket(descriptor: descriptor, sockets: sockets))
    }

    private static func readHead(_ descriptor: Int32) -> String? {
        var bytes: [UInt8] = []
        let end = Array("\r\n\r\n".utf8)
        while !bytes.suffix(end.count).elementsEqual(end) {
            guard bytes.count < maxHead, let byte = SpoolTestTCP.read(descriptor, exactly: 1) else {
                return nil
            }
            bytes += byte
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func header(_ name: String, in lines: [String]) -> String? {
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == name.lowercased() else {
                continue
            }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

/// One test socket: reads on a thread of its own, one message per ``receive()``, and writes under one lock, so a pong never
/// splits a frame being sent.
final class SpoolTestSocket: SpoolSocket {
    private struct State {
        var end: SpoolSocketEnd?
        var closedByUs = false
    }

    private let descriptor: Int32
    private let sockets: SpoolTestSockets?
    private let state = Lock(State())
    private let writing = Lock(())
    private let reads = DispatchQueue(label: "spool test socket reads")

    init(descriptor: Int32, sockets: SpoolTestSockets?) {
        self.descriptor = descriptor
        self.sockets = sockets
    }

    deinit {
        SpoolTestTCP.close(descriptor)
    }

    func receive() async -> SpoolSocketMessage {
        if let end = state.withLock({ $0.end }) {
            return .closed(end)
        }
        let message = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                reads.async { [self] in
                    continuation.resume(returning: readMessage())
                }
            }
        } onCancel: {
            close(code: SpoolCloseCode.normal)
        }
        if case .closed(let end) = message {
            return .closed(
                state.withLock { state in
                    state.end = state.end ?? end
                    return state.end ?? end
                })
        }
        sockets?.note { $0.received += 1 }
        return message
    }

    func send(_ bytes: [UInt8]) async -> Bool {
        guard state.withLock({ $0.end == nil }) else {
            return false
        }
        sockets?.note { $0.sending += 1 }
        let sent = await withCheckedContinuation { continuation in
            Thread { [self] in
                continuation.resume(returning: write(opcode: Opcode.binary, bytes))
            }.start()
        }
        sockets?.note { activity in
            activity.sending -= 1
            activity.sent += 1
        }
        return sent
    }

    func close(code: Int) {
        let first = state.withLock { state -> Bool in
            guard !state.closedByUs else {
                return false
            }
            state.closedByUs = true
            state.end = state.end ?? SpoolSocketEnd(.cancelled)
            return true
        }
        guard first else {
            return
        }
        let wire = UInt16(clamping: code)
        _ = write(opcode: Opcode.close, [UInt8(wire >> 8), UInt8(wire & 0xFF)])
        SpoolTestTCP.shutdown(descriptor)
    }

    private enum Opcode {
        static let continuation: UInt8 = 0x0
        static let text: UInt8 = 0x1
        static let binary: UInt8 = 0x2
        static let close: UInt8 = 0x8
        static let ping: UInt8 = 0x9
        static let pong: UInt8 = 0xA
    }

    /// The next whole message, on the reads queue.
    private func readMessage() -> SpoolSocketMessage {
        var payload: [UInt8] = []
        var kind: UInt8?
        while true {
            guard let head = SpoolTestTCP.read(descriptor, exactly: 2) else {
                return .closed(state.withLock { $0.end } ?? SpoolSocketEnd(.unreachable))
            }
            let fin = head[0] & 0x80 != 0
            let opcode = head[0] & 0x0F
            guard head[1] & 0x80 == 0, let length = readLength(head[1] & 0x7F) else {
                return fail()
            }
            if opcode >= Opcode.close {
                guard length <= 125, let body = SpoolTestTCP.read(descriptor, exactly: length) else {
                    return fail()
                }
                switch opcode {
                case Opcode.ping:
                    _ = write(opcode: Opcode.pong, body)
                    continue
                case Opcode.pong:
                    continue
                case Opcode.close:
                    let end = SpoolSocketEnd(.closed, code: body.count >= 2 ? Int(body[0]) << 8 | Int(body[1]) : nil)
                    state.withLock { $0.end = $0.end ?? end }
                    close(code: SpoolCloseCode.normal)
                    return .closed(end)
                default:
                    return fail()
                }
            }
            // The cap holds before a byte past it is read.
            guard payload.count + length <= SpoolRecordLayer.maxInboundRecord else {
                return fail()
            }
            guard let body = SpoolTestTCP.read(descriptor, exactly: length) else {
                return .closed(state.withLock { $0.end } ?? SpoolSocketEnd(.unreachable))
            }
            if opcode != Opcode.continuation {
                kind = opcode
            }
            payload += body
            if fin {
                return kind == Opcode.text ? .text(byteCount: payload.count) : .binary(payload)
            }
        }
    }

    private func readLength(_ short: UInt8) -> Int? {
        switch short {
        case 126:
            return SpoolTestTCP.read(descriptor, exactly: 2).map { Int($0[0]) << 8 | Int($0[1]) }
        case 127:
            return SpoolTestTCP.read(descriptor, exactly: 8).flatMap { bytes in
                let value = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                return value <= UInt64(Int32.max) ? Int(value) : nil
            }
        default:
            return Int(short)
        }
    }

    private func fail() -> SpoolSocketMessage {
        let end = SpoolSocketEnd(.protocolError)
        state.withLock { $0.end = $0.end ?? end }
        close(code: Self.tooBig)
        return .closed(end)
    }

    /// RFC 6455's "message too big".
    private static let tooBig = 1009

    /// Writes one masked frame. Answers whether it went.
    private func write(opcode: UInt8, _ payload: [UInt8]) -> Bool {
        var draw = SystemRandomNumberGenerator()
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255, using: &draw) }
        var frame: [UInt8] = [0x80 | opcode]
        switch payload.count {
        case ..<126:
            frame.append(0x80 | UInt8(payload.count))
        case ..<65_536:
            frame += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default:
            frame.append(0x80 | 127)
            frame += (0..<8).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) }
        }
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        return writing.withLock { _ in SpoolTestTCP.write(descriptor, frame) }
    }
}
