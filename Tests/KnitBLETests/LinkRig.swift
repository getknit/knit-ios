#if canImport(CoreBluetooth)
    import Foundation
    @testable import KnitBLE
    import KnitMesh
    import Testing

    /// A link over two bound stream pairs, and the far end of each.
    final class LinkRig {
        let log: CapturingLog
        let received: Bytes
        let ends: Ends
        /// Each FILE record the link reported out.
        let fileWrites: Ends
        let link: L2CAPLink
        let far: FarEnd
        /// The radio's levels, which ``send(_:)`` and its kin count into as the radio's entry points do.
        let levels = OutboxLevels()
        /// The radio's inbound credits, which the link counts its reads into and ``consume(_:)`` takes off.
        let credits = InboxCredits()
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
            let reports = Ends()
            let lines = CapturingLog()
            let streams = StreamThread()
            received = sink
            ends = endings
            fileWrites = reports
            log = lines
            thread = streams
            link = L2CAPLink(
                id: ChannelID(1),
                input: linkInput,
                output: linkOutput,
                owner: nil,
                thread: streams,
                levels: levels,
                credits: credits,
                log: lines,
                received: { sink.append($0) },
                ended: { endings.record() },
                wroteFileRecord: { reports.record() }
            )
            levels.open(ChannelID(1))
            credits.open(ChannelID(1))
            if opens {
                link.open()
            }
        }

        /// The channel's level now.
        var level: OutboxLevel { levels.level(on: ChannelID(1)) }

        /// Hands `bytes` to the link's `write`, or a kin of it, as `BLERadio`'s entry points do: counted queued first.
        func send(_ bytes: [UInt8], by write: (L2CAPLink) -> ([UInt8]) -> Void = L2CAPLink.write) {
            levels.queued(bytes.count, on: ChannelID(1))
            write(link)(bytes)
        }

        /// Reports `count` bytes processed, as `BLERadio.consumed` does: off the credit in place, and a resume kicked to the
        /// link's thread.
        func consume(_ count: Int) {
            if let unprocessed = credits.consumed(count, on: ChannelID(1)) {
                link.resumeReading(unprocessed: unprocessed)
            }
        }

        /// A flood the link always pauses on: it pauses at its first read past the credit, which is under 64 KiB past it,
        /// so at least one byte is left, and what is left never reaches the credit again.
        static let floodBytes = InboxCredits.limitBytes + 65_536

        /// `count` bytes that differ along their length, so an order mixed up shows.
        static func pattern(_ count: Int) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 8)) }
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
    final class FarEnd: NSObject, StreamDelegate, @unchecked Sendable {
        // @unchecked: the streams are touched on `thread` only, and `bytes` behind its lock.
        private let input: InputStream
        private let output: OutputStream
        private let thread = StreamThread()
        private let bytes = Bytes()
        private var reads: Bool
        /// What ``writeAll(_:)`` still has to write, as the stream makes room.
        private var pending: [UInt8] = []
        /// How many of those bytes the stream has taken.
        private var taken = 0

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

        /// Writes all of `chunk`, as the stream makes room for it.
        func writeAll(_ chunk: [UInt8]) {
            thread.perform { [self] in
                pending += chunk
                push()
            }
        }

        /// How many bytes ``writeAll(_:)`` got into the stream, once the far end's thread has run everything handed to it.
        func accepted() async -> Int {
            await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
                thread.perform { [self] in done.resume(returning: taken) }
            }
        }

        /// Returns once the far end's thread has run everything handed to it before.
        func settled() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                thread.perform { done.resume() }
            }
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
            } else if event == .hasSpaceAvailable {
                push()
            }
        }

        private func push() {
            guard !pending.isEmpty else {
                return
            }
            while output.hasSpaceAvailable, !pending.isEmpty {
                let count = output.write(pending, maxLength: pending.count)
                guard count > 0 else {
                    return
                }
                pending.removeFirst(count)
                taken += count
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
#endif
