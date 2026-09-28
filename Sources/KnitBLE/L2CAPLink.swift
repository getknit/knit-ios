#if canImport(CoreBluetooth)
    import CoreBluetooth
    import Foundation
    import KnitMesh

    /// The one thread every L2CAP stream runs on (`.agents/context/architecture.md`): a run loop that stays up with
    /// nothing scheduled, and takes work from any thread through ``perform(_:)``.
    internal final class StreamThread: @unchecked Sendable {
        // @unchecked: `loop` is written once, on the thread, before `init` returns, and only read after.
        private var loop: CFRunLoop?

        init() {
            let ready = DispatchSemaphore(value: 0)
            let thread = Thread { [weak self] in
                self?.loop = CFRunLoopGetCurrent()
                // A port keeps the run loop from returning while no stream is scheduled.
                RunLoop.current.add(NSMachPort(), forMode: .default)
                ready.signal()
                while true {
                    RunLoop.current.run(mode: .default, before: .distantFuture)
                }
            }
            thread.name = "app.getknit.knit.l2cap"
            thread.qualityOfService = .userInitiated
            thread.start()
            ready.wait()
        }

        /// Runs `block` on the stream thread, after everything handed to it before.
        func perform(_ block: @escaping @Sendable () -> Void) {
            guard let loop else {
                return
            }
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
            CFRunLoopWakeUp(loop)
        }
    }

    /// One L2CAP channel's two streams, read as one byte stream in 64 KiB gulps and written in order. Everything
    /// here runs on the ``StreamThread``; the radio reaches it only through ``write(_:)``, ``writeDigest(_:)`` and
    /// ``close()``.
    ///
    /// The channel object is held for the link's whole life: CoreBluetooth closes a channel whose last reference goes.
    /// The link reads and writes only its streams, so tests run it over a bound stream pair instead.
    internal final class L2CAPLink: NSObject, StreamDelegate, @unchecked Sendable {
        // @unchecked: every mutable member is touched on the stream thread only.
        private static let readSize = 65_536
        /// The most one stream write takes, Android's own cap: the link manager cuts its records to this
        /// (`maxWriteBytes`), and ``drain()`` cuts a digest, which comes whole.
        private static let writeSize = 8192

        let id: ChannelID
        // periphery:ignore - held, never read: CoreBluetooth closes a channel once its last reference goes
        /// What keeps the streams open: the channel, for a real link.
        private let owner: AnyObject?
        private let input: InputStream?
        private let output: OutputStream?
        private let thread: StreamThread
        private let log: any KnitLog
        private let received: @Sendable ([UInt8]) -> Void
        private let ended: @Sendable () -> Void
        private var outbox = LinkOutbox()
        private var isOpen = false
        private var isClosed = false
        /// Whether the last drain left bytes waiting for the stream's space, so a stall is logged once.
        private var isWaiting = false

        /// A link over `channel`'s streams. `received` hears every read; `ended` hears once that the far side closed it
        /// or it failed, and never after ``close()``.
        convenience init(
            id: ChannelID,
            channel: CBL2CAPChannel,
            thread: StreamThread,
            log: any KnitLog,
            received: @escaping @Sendable ([UInt8]) -> Void,
            ended: @escaping @Sendable () -> Void
        ) {
            self.init(
                id: id,
                input: channel.inputStream,
                output: channel.outputStream,
                owner: channel,
                thread: thread,
                log: log,
                received: received,
                ended: ended
            )
        }

        /// A link over `input` and `output`, holding `owner` for as long as it lives.
        init(
            id: ChannelID,
            input: InputStream?,
            output: OutputStream?,
            owner: AnyObject?,
            thread: StreamThread,
            log: any KnitLog,
            received: @escaping @Sendable ([UInt8]) -> Void,
            ended: @escaping @Sendable () -> Void
        ) {
            self.id = id
            self.input = input
            self.output = output
            self.owner = owner
            self.thread = thread
            self.log = log
            self.received = received
            self.ended = ended
        }

        /// Opens both streams on the stream thread.
        func open() {
            thread.perform { [self] in
                guard !isClosed, let input, let output else {
                    return
                }
                for stream in [input, output] as [Stream] {
                    stream.delegate = self
                    stream.schedule(in: .current, forMode: .default)
                    stream.open()
                }
                isOpen = true
            }
        }

        /// Writes `bytes` after everything written before.
        func write(_ bytes: [UInt8]) {
            thread.perform { [self] in
                guard !isClosed else {
                    return
                }
                outbox.append(bytes)
                drain()
            }
        }

        /// Writes a DIGEST record after everything written before, or in the place of the one still waiting
        /// (``LinkOutbox/offerDigest(_:)``).
        func writeDigest(_ record: [UInt8]) {
            thread.perform { [self] in
                guard !isClosed else {
                    return
                }
                if outbox.offerDigest(record) {
                    log.log(.debug, "ble \(id) digest of \(record.count) bytes replaced the one waiting")
                }
                drain()
            }
        }

        /// Closes both streams. What was still waiting to be written is dropped: the link manager closes a link only
        /// when it is done with it.
        func close() {
            thread.perform { [self] in
                shutDown()
            }
        }

        func stream(_ stream: Stream, handle event: Stream.Event) {
            switch event {
            case .openCompleted:
                log.log(.debug, "ble \(id) \(stream === input ? "input" : "output") open")
            case .hasBytesAvailable:
                readAvailable()
            case .hasSpaceAvailable:
                drain()
            case .endEncountered, .errorOccurred:
                log.log(.debug, "ble \(id) \(event == .endEncountered ? "ended" : "failed: \(String(describing: stream.streamError))")")
                if !isClosed {
                    shutDown()
                    ended()
                }
            default:
                break
            }
        }

        private func readAvailable() {
            guard let input else {
                return
            }
            var buffer = [UInt8](repeating: 0, count: Self.readSize)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                guard count > 0 else {
                    break
                }
                log.log(.debug, "ble \(id) read \(count)")
                received(Array(buffer[0..<count]))
            }
        }

        private func drain() {
            guard isOpen, let output else {
                return
            }
            while output.hasSpaceAvailable, let next = outbox.next(atMost: Self.writeSize) {
                let chunk = Array(next)
                let count = output.write(chunk, maxLength: chunk.count)
                guard count > 0 else {
                    log.log(.debug, "ble \(id) write of \(chunk.count) returned \(count)")
                    break
                }
                outbox.wrote(count)
                log.log(.debug, "ble \(id) wrote \(count), \(outbox.queuedBytes) waiting")
            }
            if outbox.isEmpty {
                isWaiting = false
            } else if !isWaiting {
                isWaiting = true
                log.log(.debug, "ble \(id) waits for space with \(outbox.queuedBytes) bytes")
            }
        }

        private func shutDown() {
            guard !isClosed else {
                return
            }
            isClosed = true
            for stream in [input, output].compactMap(\.self) as [Stream] {
                stream.delegate = nil
                stream.close()
                stream.remove(from: .current, forMode: .default)
            }
            outbox.removeAll()
        }
    }
#endif
