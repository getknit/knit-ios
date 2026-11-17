#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// TCP on `127.0.0.1` alone, in blocking calls, for the stub server and its raw client. A write never raises `SIGPIPE`: Linux
/// passes `MSG_NOSIGNAL`, and a Mac sets `SO_NOSIGPIPE` on each socket.
enum Loopback {
    #if canImport(Glibc)
        private static let stream = Int32(SOCK_STREAM.rawValue)
        private static let sendFlags = Int32(MSG_NOSIGNAL)
    #else
        private static let stream = SOCK_STREAM
        private static let sendFlags: Int32 = 0
    #endif

    /// `127.0.0.1`, in network order.
    private static let loopback = UInt32(0x7F00_0001).bigEndian
    private static let backlog: Int32 = 16

    /// A socket listening on `127.0.0.1` at a port the kernel picks, and that port. No `SO_REUSEPORT`.
    static func listen() -> (descriptor: Int32, port: UInt16)? {
        let descriptor = socket(AF_INET, stream, 0)
        guard descriptor >= 0 else {
            return nil
        }
        quiet(descriptor)
        var address = Self.address(port: 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listenSocket(descriptor, backlog) == 0, let port = port(of: descriptor) else {
            _ = closeSocket(descriptor)
            return nil
        }
        return (descriptor, port)
    }

    /// The next connection, or `nil` once the listener is shut.
    static func accept(_ listener: Int32) -> Int32? {
        let descriptor = acceptConnection(listener)
        guard descriptor >= 0 else {
            return nil
        }
        quiet(descriptor)
        return descriptor
    }

    /// A connection to `127.0.0.1:port`, or `nil`.
    static func connect(port: UInt16) -> Int32? {
        let descriptor = socket(AF_INET, stream, 0)
        guard descriptor >= 0 else {
            return nil
        }
        quiet(descriptor)
        var address = Self.address(port: port)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connectSocket(descriptor, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            _ = closeSocket(descriptor)
            return nil
        }
        return descriptor
    }

    /// Writes all of `bytes`. Answers how many went before an error, or a non-blocking socket's full buffer.
    @discardableResult
    static func write(_ descriptor: Int32, _ bytes: [UInt8]) -> Int {
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes[sent...].withUnsafeBytes { raw in
                send(descriptor, raw.baseAddress, raw.count, sendFlags)
            }
            guard wrote > 0 else {
                if wrote < 0, errno == EINTR {
                    continue
                }
                return sent
            }
            sent += wrote
        }
        return sent
    }

    /// Up to `limit` bytes, or `nil` at the end of the stream or an error.
    static func read(_ descriptor: Int32, limit: Int = 65_536) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: limit)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in recv(descriptor, raw.baseAddress, raw.count, 0) }
            if count < 0, errno == EINTR {
                continue
            }
            return count > 0 ? Array(buffer[..<count]) : nil
        }
    }

    /// Exactly `count` bytes, or `nil` if the stream ends first.
    static func read(_ descriptor: Int32, exactly count: Int) -> [UInt8]? {
        var bytes: [UInt8] = []
        while bytes.count < count {
            guard let more = read(descriptor, limit: count - bytes.count) else {
                return nil
            }
            bytes += more
        }
        return bytes
    }

    /// Makes writes on `descriptor` return at once when its buffer is full, or block again.
    static func setBlocking(_ descriptor: Int32, _ blocking: Bool) {
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, blocking ? flags & ~O_NONBLOCK : flags | O_NONBLOCK)
    }

    /// Whether `descriptor` can take a write within `milliseconds`.
    static func waitWritable(_ descriptor: Int32, milliseconds: Int32) -> Bool {
        var entry = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        return poll(&entry, 1, milliseconds) == 1 && entry.revents & Int16(POLLOUT) != 0
    }

    /// Ends both directions, which wakes a blocked read or accept, then closes.
    static func close(_ descriptor: Int32) {
        shutdown(descriptor)
        _ = closeSocket(descriptor)
    }

    /// Ends both directions and keeps the descriptor: a blocked read on it returns.
    static func shutdown(_ descriptor: Int32) {
        _ = shutdownSocket(descriptor, Int32(SHUT_RDWR))
    }

    /// Ends our direction alone: the peer reads the end of the stream, and we can still read.
    static func shutdownWrite(_ descriptor: Int32) {
        _ = shutdownSocket(descriptor, Int32(SHUT_WR))
    }

    private static func address(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: loopback)
        return address
    }

    private static func port(of descriptor: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return named == 0 ? UInt16(bigEndian: address.sin_port) : nil
    }

    /// No `SIGPIPE` from this socket, on a Mac; Linux passes `MSG_NOSIGNAL` on each send instead.
    private static func quiet(_ descriptor: Int32) {
        #if canImport(Darwin)
            var on: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #else
            _ = descriptor
        #endif
    }
}

// The C calls under their own names, where `Loopback`'s methods of the same name would shadow them.
private func listenSocket(_ descriptor: Int32, _ backlog: Int32) -> Int32 {
    listen(descriptor, backlog)
}

private func acceptConnection(_ listener: Int32) -> Int32 {
    accept(listener, nil, nil)
}

private func connectSocket(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    connect(descriptor, address, length)
}

private func closeSocket(_ descriptor: Int32) -> Int32 {
    close(descriptor)
}

private func shutdownSocket(_ descriptor: Int32, _ how: Int32) -> Int32 {
    shutdown(descriptor, how)
}
