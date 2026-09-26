#if os(Linux)
    import Glibc

    /// The few non-blocking file descriptor calls the radio's loop makes, with `errno` read at once.
    internal enum Descriptor {
        enum ReadResult: Equatable {
            case bytes(Int)
            case wouldBlock
            case ended
            case failed(Int32)
        }

        enum WriteResult: Equatable {
            case wrote(Int)
            case wouldBlock
            case failed(Int32)
        }

        /// Reads one SDU, at most `buffer.count` bytes, into the front of `buffer`.
        static func read(_ descriptor: Int32, into buffer: inout [UInt8]) -> ReadResult {
            while true {
                let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
                if count > 0 {
                    return .bytes(count)
                }
                if count == 0 {
                    return .ended
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    return .wouldBlock
                case let code:
                    return .failed(code)
                }
            }
        }

        /// Writes `bytes` as one SDU. `MSG_NOSIGNAL`, because a peer that hung up must not kill the process with
        /// `SIGPIPE`.
        static func write(_ descriptor: Int32, _ bytes: ArraySlice<UInt8>) -> WriteResult {
            while true {
                let count = bytes.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
                if count >= 0 {
                    return .wrote(count)
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    return .wouldBlock
                case let code:
                    return .failed(code)
                }
            }
        }

        /// Accepts one pending connection, made non-blocking, or `nil` when none is waiting or the call failed. Linux
        /// does not carry the listener's `O_NONBLOCK` over, and `accept4` is a GNU extension Glibc's module hides.
        static func accept(_ listener: Int32) -> Int32? {
            while true {
                let descriptor = Glibc.accept(listener, nil, nil)
                if descriptor >= 0 {
                    makeNonBlocking(descriptor)
                    return descriptor
                }
                guard errno == EINTR else {
                    return nil
                }
            }
        }

        /// Sets `O_NONBLOCK` and `FD_CLOEXEC`, which `pipe2` and `accept4` would set at birth if Glibc's module
        /// exposed them.
        static func makeNonBlocking(_ descriptor: Int32) {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }

        /// A dial's outcome once the socket turns writable: 0 when it opened, otherwise its `errno`.
        static func pendingError(_ descriptor: Int32) -> Int32 {
            var code: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &code, &length) == 0 else {
                return errno
            }
            return code
        }

        static func close(_ descriptor: Int32) {
            _ = Glibc.close(descriptor)
        }
    }

    /// The monotonic clock the radio times its D-Bus calls and re-adverts by.
    internal enum Monotonic {
        private static let millisecondsPerSecond: Int64 = 1000
        private static let nanosecondsPerMillisecond: Int64 = 1_000_000

        static func milliseconds() -> Int64 {
            var now = timespec()
            clock_gettime(CLOCK_MONOTONIC, &now)
            return Int64(now.tv_sec) * millisecondsPerSecond + Int64(now.tv_nsec) / nanosecondsPerMillisecond
        }
    }
#endif
