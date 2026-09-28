#if canImport(CoreBluetooth)
    import Foundation
    @testable import KnitBLE
    import KnitMesh
    import KnitSync
    import Testing

    /// ``L2CAPLink`` over bound stream pairs in place of a CoreBluetooth channel: what it writes, what it reads, and how
    /// it ends. The far end runs on a ``StreamThread`` of its own, as the other phone would.
    @Suite(.timeLimit(.minutes(1))) struct L2CAPLinkTests {
        @Test func writesArriveWholeAndInOrder() async throws {
            let rig = try LinkRig()
            rig.link.write([1, 2, 3])
            rig.link.write([4, 5])
            rig.link.write([6])
            #expect(try await rig.far.read(6) == [1, 2, 3, 4, 5, 6])
        }

        @Test func aLongWriteGoesOutInCutsOfAtMost8KiB() async throws {
            let rig = try LinkRig()
            let bytes = (0..<20_000).map { UInt8(truncatingIfNeeded: $0) }
            rig.link.write(bytes)
            #expect(try await rig.far.read(bytes.count) == bytes)
            let cuts = rig.log.all.compactMap(LinkRig.written)
            #expect(cuts.reduce(0, +) == bytes.count)
            #expect(cuts.allSatisfy { $0 <= 8192 })
            #expect(cuts.contains(8192), "a write the stream has room for goes out in whole cuts")
        }

        @Test func whatTheFarEndWritesReachesReceivedInOrder() async throws {
            let rig = try LinkRig()
            rig.far.write([9, 8, 7])
            rig.far.write([6, 5])
            #expect(try await rig.received.take(5) == [9, 8, 7, 6, 5])
        }

        /// A digest that waits behind bytes the far end has not read yet is replaced by a newer one, which goes out in its
        /// place; one already on the stream goes out whole (ADR 2026-09.3ch7).
        @Test func aNewerDigestTakesTheWaitingOnesPlace() async throws {
            let rig = try LinkRig(bufferSize: 1024, farReads: false)
            let backfill = [UInt8](repeating: 0xAA, count: 4096)
            rig.link.write(backfill)
            rig.link.writeDigest([0xD1, 0xD1])
            rig.link.writeDigest([0xD2, 0xD2, 0xD2])
            rig.link.write([0xEE])
            await rig.settled()
            rig.far.startReading()
            #expect(try await rig.far.read(backfill.count + 4) == backfill + [0xD2, 0xD2, 0xD2, 0xEE])
            #expect(rig.log.all.contains { $0.contains("digest of 3 bytes replaced the one waiting") })
        }

        @Test func theFarEndClosingEndsTheLinkOnce() async throws {
            let rig = try LinkRig()
            rig.far.close()
            try await rig.ends.wait()
            rig.link.close()
            rig.link.write([1])
            await rig.settled()
            #expect(rig.ends.times == 1)
        }

        @Test func closingDropsWhatWaitsAndNeverReportsAnEnd() async throws {
            let rig = try LinkRig(bufferSize: 1024, farReads: false)
            rig.link.write([UInt8](repeating: 1, count: 4096))
            await rig.settled()
            rig.link.close()
            rig.link.write([2])
            await rig.settled()
            rig.far.startReading()
            // Whatever the stream held before the close may still arrive; nothing written after it does.
            let arrived = await rig.far.drainAvailable()
            #expect(arrived.count <= 1024)
            #expect(!arrived.contains(2))
            #expect(rig.ends.times == 0)
        }

        @Test func nothingIsWrittenUntilTheStreamsAreOpen() async throws {
            let rig = try LinkRig(opens: false)
            rig.link.write([1, 2])
            await rig.settled()
            #expect(rig.log.all.compactMap(LinkRig.written).isEmpty)
            rig.link.open()
            rig.link.write([3])
            #expect(try await rig.far.read(3) == [1, 2, 3])
        }
    }

    /// A link over two bound stream pairs, and the far end of each.
    private final class LinkRig {
        let log: CapturingLog
        let received: Bytes
        let ends: Ends
        let link: L2CAPLink
        let far: FarEnd
        private let thread: StreamThread

        init(bufferSize: Int = 65_536, farReads: Bool = true, opens: Bool = true) throws {
            var linkInput: InputStream?
            var farOutput: OutputStream?
            Stream.getBoundStreams(withBufferSize: bufferSize, inputStream: &linkInput, outputStream: &farOutput)
            var farInput: InputStream?
            var linkOutput: OutputStream?
            Stream.getBoundStreams(withBufferSize: bufferSize, inputStream: &farInput, outputStream: &linkOutput)
            far = FarEnd(input: try #require(farInput), output: try #require(farOutput), reads: farReads)
            let sink = Bytes()
            let endings = Ends()
            let lines = CapturingLog()
            let streams = StreamThread()
            received = sink
            ends = endings
            log = lines
            thread = streams
            link = L2CAPLink(
                id: ChannelID(1),
                input: linkInput,
                output: linkOutput,
                owner: nil,
                thread: streams,
                log: lines,
                received: { sink.append($0) },
                ended: { endings.record() }
            )
            if opens {
                link.open()
            }
        }

        /// Returns once the link's thread has run everything handed to it before.
        func settled() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                thread.perform { done.resume() }
            }
        }

        /// The byte count of a "wrote" log line.
        static func written(_ line: String) -> Int? {
            guard let range = line.range(of: " wrote ") else {
                return nil
            }
            return Int(line[range.upperBound...].prefix(while: \.isNumber))
        }
    }

    /// The other phone: reads everything the link writes, and writes what a test tells it to.
    private final class FarEnd: NSObject, StreamDelegate, @unchecked Sendable {
        // @unchecked: the streams are touched on `thread` only, and `bytes` behind its lock.
        private let input: InputStream
        private let output: OutputStream
        private let thread = StreamThread()
        private let bytes = Bytes()
        private var reads: Bool

        init(input: InputStream, output: OutputStream, reads: Bool) {
            self.input = input
            self.output = output
            self.reads = reads
            super.init()
            thread.perform { [self] in
                for stream in [self.input, self.output] as [Stream] {
                    stream.delegate = self
                    stream.schedule(in: .current, forMode: .default)
                    stream.open()
                }
            }
        }

        /// The next `count` bytes the link wrote.
        func read(_ count: Int) async throws -> [UInt8] {
            try await bytes.take(count)
        }

        /// Starts reading, for a far end made not to.
        func startReading() {
            thread.perform { [self] in
                reads = true
                pull()
            }
        }

        /// Everything read so far, once the far end's thread has run what it was handed.
        func drainAvailable() async -> [UInt8] {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                thread.perform { [self] in
                    pull()
                    done.resume()
                }
            }
            return bytes.all
        }

        func write(_ chunk: [UInt8]) {
            thread.perform { [self] in
                _ = output.write(chunk, maxLength: chunk.count)
            }
        }

        func close() {
            thread.perform { [self] in
                output.close()
            }
        }

        func stream(_: Stream, handle event: Stream.Event) {
            if event == .hasBytesAvailable {
                pull()
            }
        }

        private func pull() {
            guard reads else {
                return
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                guard count > 0 else {
                    break
                }
                bytes.append(Array(buffer[0..<count]))
            }
        }
    }

    /// Bytes that arrive on one thread and are awaited on another.
    private final class Bytes: Sendable {
        private struct State {
            var bytes: [UInt8] = []
            var waiters: [(count: Int, continuation: CheckedContinuation<[UInt8], any Error>)] = []
        }

        private let state = Lock(State())

        var all: [UInt8] { state.withLock { $0.bytes } }

        func append(_ more: [UInt8]) {
            let ready = state.withLock { state -> [(CheckedContinuation<[UInt8], any Error>, [UInt8])] in
                state.bytes += more
                var ready: [(CheckedContinuation<[UInt8], any Error>, [UInt8])] = []
                while let first = state.waiters.first, state.bytes.count >= first.count {
                    state.waiters.removeFirst()
                    ready.append((first.continuation, Array(state.bytes.prefix(first.count))))
                    state.bytes.removeFirst(first.count)
                }
                return ready
            }
            for (continuation, bytes) in ready {
                continuation.resume(returning: bytes)
            }
        }

        /// The next `count` bytes, as soon as they have all arrived.
        func take(_ count: Int) async throws -> [UInt8] {
            try await withCheckedThrowingContinuation { continuation in
                let ready = state.withLock { state -> [UInt8]? in
                    guard state.waiters.isEmpty, state.bytes.count >= count else {
                        state.waiters.append((count, continuation))
                        return nil
                    }
                    let taken = Array(state.bytes.prefix(count))
                    state.bytes.removeFirst(count)
                    return taken
                }
                if let ready {
                    continuation.resume(returning: ready)
                }
            }
        }
    }

    /// How many times the link reported its end, and a wait for the first.
    private final class Ends: Sendable {
        private struct State {
            var times = 0
            var waiter: CheckedContinuation<Void, any Error>?
        }

        private let state = Lock(State())

        var times: Int { state.withLock { $0.times } }

        func record() {
            let waiter = state.withLock { state in
                state.times += 1
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }

        func wait() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ended = state.withLock { state in
                    if state.times == 0 {
                        state.waiter = continuation
                    }
                    return state.times > 0
                }
                if ended {
                    continuation.resume()
                }
            }
        }
    }

    /// A log that keeps its lines.
    private final class CapturingLog: KnitLog {
        private let lines = Lock<[String]>([])

        var all: [String] { lines.withLock { $0 } }

        func log(_: LogLevel, _ message: @autoclosure () -> String) {
            let line = message()
            lines.withLock { $0.append(line) }
        }
    }
#endif
