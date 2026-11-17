#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Blocking TCP to `127.0.0.1`. A write never raises `SIGPIPE`: Linux passes `MSG_NOSIGNAL`, and a Mac sets `SO_NOSIGPIPE`.
enum SpoolTestTCP {
    #if canImport(Glibc)
        private static let stream = Int32(SOCK_STREAM.rawValue)
        private static let sendFlags = Int32(MSG_NOSIGNAL)
    #else
        private static let stream = SOCK_STREAM
        private static let sendFlags: Int32 = 0
    #endif

    static func connect(port: UInt16) -> Int32? {
        let descriptor = socket(AF_INET, stream, 0)
        guard descriptor >= 0 else {
            return nil
        }
        #if canImport(Darwin)
            var on: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
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

    static func write(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes[sent...].withUnsafeBytes { raw in send(descriptor, raw.baseAddress, raw.count, sendFlags) }
            guard wrote > 0 else {
                if wrote < 0, errno == EINTR {
                    continue
                }
                return false
            }
            sent += wrote
        }
        return true
    }

    static func read(_ descriptor: Int32, exactly count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let read = bytes[got...].withUnsafeMutableBytes { raw in recv(descriptor, raw.baseAddress, raw.count, 0) }
            if read < 0, errno == EINTR {
                continue
            }
            guard read > 0 else {
                return nil
            }
            got += read
        }
        return bytes
    }

    static func shutdown(_ descriptor: Int32) {
        _ = shutdownSocket(descriptor, Int32(SHUT_RDWR))
    }

    static func close(_ descriptor: Int32) {
        shutdown(descriptor)
        _ = closeSocket(descriptor)
    }
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
