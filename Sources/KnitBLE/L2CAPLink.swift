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
    /// here runs on the ``StreamThread``; the radio reaches it only through ``write(_:)``, ``writeDigest(_:)``,
    /// ``writeFileRecord(_:)`` and ``close()``.
    ///
    /// The channel object is held for the link's whole life: CoreBluetooth closes a channel whose last reference goes.
    /// The link reads and writes only its streams, so tests run it over a bound stream pair instead.
    ///
    /// A far end that stops reading fills the stream, and `hasSpaceAvailable` never comes again. So past
    /// ``LinkOutbox/maximumQueuedBytes`` waiting the link closes itself and reports its end, as BlueZ's channels do, rather
    /// than hold what the link manager queues until iOS ends Knit for its memory (ADR 2026-10.f5zs). Each byte the stream
    /// takes is counted in the radio's ``OutboxLevels``, which counted it queued when the radio was handed it.
    ///
    /// Reads are bounded the other way by the channel's inbound credit (``InboxCredits``): the link stops reading once
    /// 256 KiB it delivered wait unprocessed, and leaves the rest in the input stream, where iOS's own buffer fills and
    /// L2CAP's credits hold the far end back. The stream says `hasBytesAvailable` again only after a read, so a resume
    /// below half comes from the radio (``resumeReading(unprocessed:)``), never from the stream (ADR 2026-10.f5zs).
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
        private let levels: OutboxLevels
        private let credits: InboxCredits
        private let log: any KnitLog
        private let received: @Sendable ([UInt8]) -> Void
        private let ended: @Sendable () -> Void
        private let wroteFileRecord: @Sendable () -> Void
        private var outbox = LinkOutbox()
        private var isOpen = false
        private var isClosed = false
        /// Whether the last drain left bytes waiting for the stream's space, so a stall is logged once.
        private var isWaiting = false

        /// A link over `channel`'s streams. `received` hears every read; `ended` hears once that the far side closed it, it
        /// failed, or it closed itself overfull, and never after ``close()``; `wroteFileRecord` hears each FILE record's
        /// last byte go out. `levels` hears each byte written, and `credits` each byte read and is asked before each read.
        convenience init(
            id: ChannelID,
            channel: CBL2CAPChannel,
            thread: StreamThread,
            levels: OutboxLevels,
            credits: InboxCredits,
            log: any KnitLog,
            received: @escaping @Sendable ([UInt8]) -> Void,
            ended: @escaping @Sendable () -> Void,
            wroteFileRecord: @escaping @Sendable () -> Void
        ) {
            self.init(
                id: id,
                input: channel.inputStream,
                output: channel.outputStream,
                owner: channel,
                thread: thread,
                levels: levels,
                credits: credits,
                log: log,
                received: received,
                ended: ended,
                wroteFileRecord: wroteFileRecord
            )
        }

        /// A link over `input` and `output`, holding `owner` for as long as it lives.
        init(
            id: ChannelID,
            input: InputStream?,
            output: OutputStream?,
            owner: AnyObject?,
            thread: StreamThread,
            levels: OutboxLevels,
            credits: InboxCredits,
            log: any KnitLog,
            received: @escaping @Sendable ([UInt8]) -> Void,
            ended: @escaping @Sendable () -> Void,
            wroteFileRecord: @escaping @Sendable () -> Void
        ) {
            self.id = id
            self.input = input
            self.output = output
            self.owner = owner
            self.thread = thread
            self.levels = levels
            self.credits = credits
            self.log = log
            self.received = received
            self.ended = ended
            self.wroteFileRecord = wroteFileRecord
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
                drainWithinBound()
            }
        }

        /// Writes a FILE record after everything written before, and reports its last byte out
        /// (``LinkOutbox/appendFileRecord(_:)``).
        func writeFileRecord(_ record: [UInt8]) {
            thread.perform { [self] in
                guard !isClosed else {
                    return
                }
                outbox.appendFileRecord(record)
                drainWithinBound()
            }
        }

        /// Writes a DIGEST record after everything written before, or in the place of the one still waiting
        /// (``LinkOutbox/offerDigest(_:)``).
        func writeDigest(_ record: [UInt8]) {
            thread.perform { [self] in
                guard !isClosed else {
                    return
                }
                let before = outbox.queuedBytes
                if outbox.offerDigest(record) {
                    log.log(.debug, "ble \(id) digest of \(record.count) bytes replaced the one waiting")
                    // The radio counted the whole record; the one it replaced will never be written.
                    levels.discarded(record.count - (outbox.queuedBytes - before), on: id)
                }
                drainWithinBound()
            }
        }

        /// Reads again once the radio's consumer has brought the channel below half its credit, with `unprocessed` bytes
        /// still waiting on it: the stream will not say `hasBytesAvailable` again until the link reads, so it reads now.
        func resumeReading(unprocessed: Int) {
            thread.perform { [self] in
                guard isOpen, !isClosed else {
                    return
                }
                log.log(.debug, "ble \(id) reads resumed: \(unprocessed) bytes unprocessed")
                readAvailable()
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
                    // At the input's end the far end can send no more, so whatever a paused read left is all there is,
                    // and goes on before the end, past the credit: nothing the far end sent is dropped.
                    if event == .endEncountered, stream === input {
                        // What a paused read left, for the trial to see that the end dropped none of it.
                        let past = readAvailable(pastCredit: true)
                        log.log(.debug, "ble \(id) read \(past) bytes past its credit at its end")
                    }
                    shutDown()
                    ended()
                }
            default:
                break
            }
        }

        /// Reads in 64 KiB gulps while the stream has bytes, asking the channel's credit before each, and stops at it
        /// unless `pastCredit`: what is left waits in the stream until ``resumeReading(unprocessed:)``. Answers how many bytes
        /// it delivered.
        @discardableResult
        private func readAvailable(pastCredit: Bool = false) -> Int {
            guard !isClosed, let input else {
                return 0
            }
            var delivered = 0
            var buffer = [UInt8](repeating: 0, count: Self.readSize)
            while input.hasBytesAvailable {
                if !pastCredit {
                    switch credits.gate(id) {
                    case .read:
                        break
                    case .pause(let unprocessed):
                        log.log(.debug, "ble \(id) reads paused: \(unprocessed) bytes unprocessed")
                        return delivered
                    case .paused:
                        return delivered
                    }
                }
                let count = input.read(&buffer, maxLength: buffer.count)
                guard count > 0 else {
                    break
                }
                log.log(.debug, "ble \(id) read \(count)")
                // Counted before it is delivered, so the consumer never reports bytes the credit has not seen.
                credits.delivered(count, on: id)
                delivered += count
                received(Array(buffer[0..<count]))
            }
            // A stream that reached its end while reads were paused need not say so again after the read a resume makes,
            // so the end is taken from the stream's status as well as from its event.
            if !pastCredit, input.streamStatus == .atEnd {
                log.log(.debug, "ble \(id) ended")
                shutDown()
                ended()
            }
            return delivered
        }

        /// Closes the link and reports its end when the far end has stopped reading (``LinkOutbox/isOverfull``), and
        /// otherwise writes what the stream takes. The end goes to the radio, which reports the channel closed, so the link
        /// manager retires it.
        private func drainWithinBound() {
            guard !outbox.isOverfull else {
                log.log(.warning, "ble \(id) stopped reading; closing it")
                shutDown()
                ended()
                return
            }
            drain()
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
                let finishedFileRecord = outbox.wrote(count)
                levels.wrote(count, on: id)
                log.log(.debug, "ble \(id) wrote \(count), \(outbox.queuedBytes) waiting")
                if finishedFileRecord {
                    wroteFileRecord()
                }
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
            // The credit dies with the link, however it ended, so nothing waits on a count no consumer will bring down.
            credits.close(id)
            for stream in [input, output].compactMap(\.self) as [Stream] {
                stream.delegate = nil
                stream.close()
                stream.remove(from: .current, forMode: .default)
            }
            outbox.removeAll()
        }
    }
#endif
