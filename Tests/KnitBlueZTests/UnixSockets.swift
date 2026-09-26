#if os(Linux)
    import Foundation
    import Glibc
    @testable import KnitBlueZ

    /// Unix sequenced-packet sockets in place of L2CAP: the same message boundaries, and no adapter. The radio's
    /// listener is `<directory>/listener`, and a dial to a device goes to `<directory>/<address>-<psm>`, where the
    /// test's ``RemoteListener`` waits.
    struct UnixSockets: SocketProvider {
        static let psm: UInt16 = 0x80

        let directory: String
        /// The largest write, small enough that a record has to be split.
        let limit: Int
        /// Makes ``listen()`` fail, as a missing adapter would.
        let failsToListen: Bool
        /// Who every accepted channel claims to come from, as an L2CAP socket's peer address says.
        let acceptedPeer: DialTarget?

        init(directory: String, limit: Int = 100, failsToListen: Bool = false, acceptedPeer: DialTarget? = nil) {
            self.directory = directory
            self.limit = limit
            self.failsToListen = failsToListen
            self.acceptedPeer = acceptedPeer
        }

        var listenerPath: String { directory + "/listener" }

        static func path(for target: DialTarget, psm: UInt16, in directory: String) -> String {
            "\(directory)/\(target.address)-\(psm)"
        }

        func listen() throws(SocketError) -> ListeningSocket {
            guard !failsToListen else {
                throw SocketError(call: "bind", code: EADDRNOTAVAIL)
            }
            unlink(listenerPath)
            let descriptor = try Self.socket()
            guard Self.withAddress(listenerPath, { Glibc.bind(descriptor, $0, $1) }) == 0, Glibc.listen(descriptor, 8) == 0 else {
                let code = errno
                Glibc.close(descriptor)
                throw SocketError(call: "bind", code: code)
            }
            return ListeningSocket(descriptor: descriptor, psm: Self.psm)
        }

        func dial(_ target: DialTarget, psm: UInt16) throws(SocketError) -> Int32 {
            let descriptor = try Self.socket()
            let result = Self.withAddress(Self.path(for: target, psm: psm, in: directory)) { connect(descriptor, $0, $1) }
            guard result == 0 || errno == EINPROGRESS || errno == EAGAIN else {
                let code = errno
                Glibc.close(descriptor)
                throw SocketError(call: "connect", code: code)
            }
            return descriptor
        }

        func sendLimit(of _: Int32) -> Int {
            limit
        }

        func peer(of _: Int32) -> DialTarget? {
            acceptedPeer
        }

        static func socket(blocking: Bool = false) throws(SocketError) -> Int32 {
            let kind = Int32(SOCK_SEQPACKET.rawValue) | (blocking ? 0 : Int32(SOCK_NONBLOCK.rawValue))
            let descriptor = Glibc.socket(AF_UNIX, kind, 0)
            guard descriptor >= 0 else {
                throw SocketError(call: "socket", code: errno)
            }
            return descriptor
        }

        static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                for (index, byte) in bytes.prefix(raw.count - 1).enumerated() {
                    raw[index] = byte
                }
            }
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
        }

        /// A short, fresh directory: a Unix socket path must fit in 108 bytes.
        static func temporaryDirectory() -> String {
            var template = Array("/tmp/knit-bluez-XXXXXX".utf8CString)
            return template.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress, let made = mkdtemp(base) else {
                    return "/tmp"
                }
                return String(cString: made)
            }
        }
    }

    /// One end of a channel, held by the test: blocking, with every read bounded by a timeout.
    final class RemoteEnd {
        let descriptor: Int32

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit {
            Glibc.close(descriptor)
        }

        /// Dials the radio's listener, as a phone would.
        static func dial(_ sockets: UnixSockets) throws -> RemoteEnd {
            let dialing = try UnixSockets.socket(blocking: true)
            guard UnixSockets.withAddress(sockets.listenerPath, { connect(dialing, $0, $1) }) == 0 else {
                Glibc.close(dialing)
                throw SocketError(call: "connect", code: errno)
            }
            return RemoteEnd(descriptor: dialing)
        }

        /// Hangs up, as a phone that walked away would.
        func hangUp() {
            _ = shutdown(descriptor, Int32(SHUT_RDWR))
        }

        /// Sends one SDU.
        func send(_ bytes: [UInt8]) {
            _ = bytes.withUnsafeBytes { Glibc.send(descriptor, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
        }

        /// The next SDU, or `nil` at end of stream or when nothing comes within the timeout.
        func receive(timeoutMilliseconds: Int32 = 2000) -> [UInt8]? {
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, timeoutMilliseconds) > 0 else {
                return nil
            }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            return count > 0 ? Array(buffer[0..<count]) : nil
        }

        /// Whether the other side has closed.
        func sawEnd(timeoutMilliseconds: Int32 = 2000) -> Bool {
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, timeoutMilliseconds) > 0 else {
                return false
            }
            var byte: UInt8 = 0
            return recv(descriptor, &byte, 1, Int32(MSG_PEEK)) == 0
        }
    }

    /// A listener where a device the radio dials is waiting.
    final class RemoteListener {
        let descriptor: Int32

        init(for target: DialTarget, psm: UInt16, in directory: String) throws {
            let path = UnixSockets.path(for: target, psm: psm, in: directory)
            unlink(path)
            descriptor = try UnixSockets.socket(blocking: true)
            guard UnixSockets.withAddress(path, { Glibc.bind(descriptor, $0, $1) }) == 0, Glibc.listen(descriptor, 4) == 0 else {
                throw SocketError(call: "bind", code: errno)
            }
        }

        deinit {
            Glibc.close(descriptor)
        }

        /// The next dial, once it arrives.
        func accept(timeoutMilliseconds: Int32 = 2000) -> RemoteEnd? {
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, timeoutMilliseconds) > 0 else {
                return nil
            }
            let accepted = Glibc.accept(descriptor, nil, nil)
            return accepted >= 0 ? RemoteEnd(descriptor: accepted) : nil
        }
    }
#endif
