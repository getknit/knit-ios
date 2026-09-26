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
    /// here runs on the ``StreamThread``; the radio reaches it only through ``write(_:)`` and ``close()``.
    ///
    /// The channel object is held for the link's whole life: CoreBluetooth closes a channel whose last reference goes.
    internal final class L2CAPLink: NSObject, StreamDelegate, @unchecked Sendable {
        // @unchecked: every mutable member is touched on the stream thread only.
        private static let readSize = 65_536
        /// The most one stream write takes; the link manager's records are already cut to this (`maxWriteBytes`).
        private static let writeSize = 8192

        let id: ChannelID
        private let channel: CBL2CAPChannel
        private let thread: StreamThread
        private let received: @Sendable ([UInt8]) -> Void
        private let ended: @Sendable () -> Void
        private var pending: [UInt8] = []
        private var written = 0
        private var isOpen = false
        private var isClosed = false

        /// A link over `channel`. `received` hears every read; `ended` hears once that the far side closed it or it
        /// failed, and never after ``close()``.
        init(
            id: ChannelID,
            channel: CBL2CAPChannel,
            thread: StreamThread,
            received: @escaping @Sendable ([UInt8]) -> Void,
            ended: @escaping @Sendable () -> Void
        ) {
            self.id = id
            self.channel = channel
            self.thread = thread
            self.received = received
            self.ended = ended
        }

        /// Opens both streams on the stream thread.
        func open() {
            thread.perform { [self] in
                guard !isClosed, let input = channel.inputStream, let output = channel.outputStream else {
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
                pending += bytes
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

        func stream(_: Stream, handle event: Stream.Event) {
            switch event {
            case .hasBytesAvailable:
                readAvailable()
            case .hasSpaceAvailable:
                drain()
            case .endEncountered, .errorOccurred:
                if !isClosed {
                    shutDown()
                    ended()
                }
            default:
                break
            }
        }

        private func readAvailable() {
            guard let input = channel.inputStream else {
                return
            }
            var buffer = [UInt8](repeating: 0, count: Self.readSize)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                guard count > 0 else {
                    break
                }
                received(Array(buffer[0..<count]))
            }
        }

        private func drain() {
            guard isOpen, let output = channel.outputStream else {
                return
            }
            while written < pending.count, output.hasSpaceAvailable {
                let chunk = Array(pending[written..<min(written + Self.writeSize, pending.count)])
                let count = output.write(chunk, maxLength: chunk.count)
                guard count > 0 else {
                    break
                }
                written += count
            }
            if written == pending.count {
                pending.removeAll(keepingCapacity: true)
                written = 0
            }
        }

        private func shutDown() {
            guard !isClosed else {
                return
            }
            isClosed = true
            for stream in [channel.inputStream, channel.outputStream].compactMap(\.self) as [Stream] {
                stream.delegate = nil
                stream.close()
                stream.remove(from: .current, forMode: .default)
            }
            pending = []
        }
    }
#endif
