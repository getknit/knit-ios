#if canImport(Darwin)
    import Foundation
    import KnitCrypto
    import KnitWire
    import Testing

    @testable import KnitMesh
    @testable import KnitSpoolNet

    /// The daemon `KNIT_SPOOL_URL` names, when it is on this machine's loopback.
    enum SpoolNetDaemon {
        static let url = ProcessInfo.processInfo.environment["KNIT_SPOOL_URL"].flatMap { text in
            text.hasPrefix("ws://127.0.0.1:") || text.hasPrefix("ws://localhost:") ? text : nil
        }
    }

    /// The URLSession adapter against the reference daemon (ADR 2026-11.adrq, P5), on the Mac, only when `KNIT_SPOOL_URL`
    /// names a daemon on the Mac's own loopback: Colima there, or skuld's through an ssh tunnel. The plane's suite runs on
    /// Linux through the test socket; this is the shipping socket's own exchange: `hello` both ways, a stamped `sub`, a push
    /// and a pull, and a socket that outlives the daemon's 30 s ping.
    @Suite(
        .serialized, .timeLimit(.minutes(2)),
        .enabled(if: SpoolNetDaemon.url != nil, "KNIT_SPOOL_URL names no daemon on this machine's loopback")
    )
    struct URLSessionDaemonTests {
        /// One connection's records, read and written through the adapter.
        final class Line {
            let socket: any SpoolSocket
            private var serial: Int64 = 1

            init(_ socket: any SpoolSocket) {
                self.socket = socket
            }

            func next() async -> SpoolRecord? {
                while case .binary(let bytes) = await socket.receive() {
                    if let record = SpoolRecord(decoding: bytes) {
                        return record
                    }
                }
                return nil
            }

            func send(_ record: SpoolRecord) async -> Bool {
                guard let bytes = record.encoded else {
                    return false
                }
                return await socket.send(bytes)
            }

            func request() -> Int64 {
                defer { serial += 1 }
                return serial
            }
        }

        /// knit-next's fixture bytes, `(7·i + seed) mod 256`.
        static func fixture(_ count: Int, seed: Int) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: 7 * $0 + seed) }
        }

        private func open(_ dialer: Dialer) async throws -> (Line, SpoolHello) {
            let line = Line(try await dialer.socket(try #require(SpoolNetDaemon.url)))
            guard case .hello(let hello)? = await line.next() else {
                Issue.record("no hello")
                throw CancellationError()
            }
            #expect(await line.send(.hello(.client)))
            return (line, hello)
        }

        /// `hello` both ways, a `sub` the daemon answers with `pow`, the stamp, its digest, a push and a pull byte for byte.
        @Test func aStampedSubAPushAndAPullGoThroughTheAdapter() async throws {
            let dialer = Dialer()
            let (line, hello) = try await open(dialer)
            let keys = try #require(
                ScopeKeys(id: Self.fixture(32, seed: 41), sealKey: Self.fixture(32, seed: 42), nonceKey: Self.fixture(32, seed: 43)))
            let wall = Int64(Date().timeIntervalSince1970 * 1000)
            let day = SpoolPow.utcDay(nowMs: wall)
            let counter = try #require(SpoolPow.mine(scopeId: keys.id, day: day, bits: hello.powBits ?? 0).counter)
            let stamp = (hello.powBits ?? 0) > 0 ? PowStamp(counter: counter, day: day) : nil
            #expect(
                await line.send(
                    .sub(SpoolSub(request: line.request(), subs: [ScopeSub(scope: keys.id, bounds: ScopeFrames.bounds, pow: stamp)]))))
            var digest: SpoolDigest?
            while digest == nil, let record = await line.next() {
                if case .digest(let answer) = record, answer.scope == keys.id {
                    digest = answer
                }
            }
            #expect(digest != nil, "the daemon took the stamped sub")
            let sealed = try #require(
                ScopeCrypto.seal(keys, sig: Self.fixture(64, seed: Int(wall % 200)), signed: Self.fixture(300, seed: 44)))
            let push = line.request()
            #expect(await line.send(.push(SpoolPush(request: push, scope: keys.id, blobId: sealed.blobId, data: sealed.blob))))
            let pull = line.request()
            var served: [UInt8]?
            var pulled = false
            while !pulled, let record = await line.next() {
                switch record {
                case .ok(let ok) where ok.request == push:
                    #expect(await line.send(.pull(SpoolPull(request: pull, scope: keys.id, blobIds: [sealed.blobId]))))
                case .blob(let blob) where blob.blobId == sealed.blobId:
                    served = blob.data
                case .ok(let ok) where ok.request == pull:
                    pulled = true
                default:
                    continue
                }
            }
            #expect(served == sealed.blob, "the daemon served the blob back byte for byte")
            line.socket.close(code: SpoolCloseCode.normal)
        }

        /// A socket left quiet past the daemon's 30 s ping still answers: the task answers the ping, and its request timeout
        /// never ends a quiet socket.
        @Test func aQuietSocketOutlivesTheDaemonsPing() async throws {
            let dialer = Dialer()
            let (line, _) = try await open(dialer)
            // The daemon's ping comes on its own clock, outside the test's: this waits for it, not for an event of ours.
            try await Task.sleep(for: .seconds(35))
            let request = line.request()
            #expect(await line.send(.list(SpoolList(request: request, scope: Self.fixture(32, seed: 9)))))
            var answered = false
            while !answered, let record = await line.next() {
                if case .err(let err) = record, err.request == request {
                    answered = true
                } else if case .list(let list) = record, list.request == request {
                    answered = true
                }
            }
            #expect(answered, "the daemon answered on the same socket")
            line.socket.close(code: SpoolCloseCode.normal)
        }
    }
#endif
