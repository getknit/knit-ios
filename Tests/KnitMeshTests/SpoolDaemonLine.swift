import Foundation
import KnitCrypto
import KnitWire
import Testing

@testable import KnitMesh

/// One raw connection to the reference daemon, outside the plane (ADR 2026-11.adrq, P5): the records a test writes itself,
/// in order, over a ``SpoolTestSocket``, for the cases a member of the plane cannot play: pushing a blob the Kotlin vectors
/// sealed, reading back what the daemon serves, and pushing as Android does into a scope this port left.
final class SpoolDaemonLine {
    enum Failure: Error {
        case closed
        case refused(String)
    }

    let socket: any SpoolSocket
    let hello: SpoolHello
    private var serial: Int64 = 1

    private init(socket: any SpoolSocket, hello: SpoolHello) {
        self.socket = socket
        self.hello = hello
    }

    deinit {
        socket.close(code: SpoolCloseCode.normal)
    }

    /// Dials `text` raw, reads the daemon's `hello` and answers it.
    static func open(_ text: String) async throws -> SpoolDaemonLine {
        guard case .opened(let socket) = await SpoolTestSockets.dial(raw: text) else {
            throw Failure.closed
        }
        guard case .binary(let bytes) = await socket.receive(), case .hello(let hello)? = SpoolRecord(decoding: bytes) else {
            throw Failure.closed
        }
        guard let reply = SpoolRecord.hello(.client).encoded, await socket.send(reply) else {
            throw Failure.closed
        }
        return SpoolDaemonLine(socket: socket, hello: hello)
    }

    /// The next record, or `nil` once the socket ended.
    func next() async -> SpoolRecord? {
        while true {
            switch await socket.receive() {
            case .binary(let bytes):
                if let record = SpoolRecord(decoding: bytes) {
                    return record
                }
            case .text:
                continue
            case .closed:
                return nil
            }
        }
    }

    private func send(_ record: SpoolRecord) async throws {
        guard let bytes = record.encoded, await socket.send(bytes) else {
            throw Failure.closed
        }
    }

    private func nextRequest() -> Int64 {
        defer { serial += 1 }
        return serial
    }

    /// Subscribes `scope`, mining a stamp at the daemon's bits when it asks for one, and answers its first digest.
    @discardableResult
    func subscribe(_ scope: [UInt8], wall: Int64) async throws -> SpoolDigest {
        var stamp: PowStamp?
        for _ in 0..<2 {
            try await send(.sub(SpoolSub(request: nextRequest(), subs: [ScopeSub(scope: scope, bounds: ScopeFrames.bounds, pow: stamp)])))
            reading: while let record = await next() {
                switch record {
                case .digest(let digest) where digest.scope == scope:
                    return digest
                case .err(let err) where err.code == SpoolErrorCode.pow && stamp == nil:
                    let day = SpoolPow.utcDay(nowMs: wall)
                    let counter = try #require(SpoolPow.mine(scopeId: scope, day: day, bits: hello.powBits ?? 0).counter)
                    stamp = PowStamp(counter: counter, day: day)
                    break reading
                case .err(let err):
                    throw Failure.refused(err.code)
                default:
                    continue
                }
            }
        }
        throw Failure.closed
    }

    /// Pushes `blob` into `scope` and answers whether the daemon took it.
    func push(_ blob: [UInt8], into scope: [UInt8]) async throws -> Bool {
        let request = nextRequest()
        try await send(.push(SpoolPush(request: request, scope: scope, blobId: ScopeCrypto.blobId(of: blob), data: blob)))
        while let record = await next() {
            switch record {
            case .ok(let ok) where ok.request == request:
                return true
            case .err(let err) where err.request == request:
                return false
            default:
                continue
            }
        }
        throw Failure.closed
    }

    /// The ids the daemon lists live in `scope`.
    func list(_ scope: [UInt8]) async throws -> [[UInt8]] {
        let request = nextRequest()
        try await send(.list(SpoolList(request: request, scope: scope)))
        while let record = await next() {
            if case .list(let list) = record, list.request == request {
                return list.blobIds ?? []
            }
            if case .err(let err) = record, err.request == request {
                throw Failure.refused(err.code)
            }
        }
        throw Failure.closed
    }

    /// The blobs `ids` names in `scope`, as the daemon serves them, by id.
    func pull(_ ids: [[UInt8]], from scope: [UInt8]) async throws -> [[UInt8]: [UInt8]] {
        let request = nextRequest()
        try await send(.pull(SpoolPull(request: request, scope: scope, blobIds: ids)))
        var served: [[UInt8]: [UInt8]] = [:]
        while let record = await next() {
            switch record {
            case .blob(let blob) where blob.scope == scope:
                served[blob.blobId] = blob.data
            case .ok(let ok) where ok.request == request:
                return served
            case .err(let err) where err.request == request:
                throw Failure.refused(err.code)
            default:
                continue
            }
        }
        throw Failure.closed
    }
}
