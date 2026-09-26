#if os(Linux)
    import CBluetoothShim
    import Glibc

    /// LE credit-based L2CAP sockets bound to one adapter's address, as spike (e) proved them on `hci1`
    /// (`.agents/context/linux-peer.md`): `SOCK_SEQPACKET`, a dynamic PSM, `BT_SECURITY_LOW` because Android's
    /// channel is insecure, and no root.
    ///
    /// Every socket binds to the adapter's address before it listens or dials, so the kernel can use no other
    /// adapter. That is what keeps the peer off `hci0`.
    public struct L2CAPSockets: SocketProvider {
        /// What each channel offers to receive in one SDU, by default: the largest an LE channel allows, so
        /// Android's 8 KiB writes arrive whole. The radio reads 64 KiB at a time, which holds one.
        public static let largestReceiveMTU: UInt16 = 65_535
        /// Android caps each of its writes at 8 KiB, and so does this.
        static let largestWrite = 8192
        /// The smallest SDU an LE channel must carry, when the kernel will not say.
        static let fallbackSendMTU = 23
        private static let backlog: Int32 = 8

        /// The adapter every socket binds to.
        public let adapter: BluetoothAddress
        /// The receive MTU each socket offers. The kernel also caps the segment size at it.
        public let receiveMTU: UInt16
        /// The largest SDU to write, below what the peer offers, for diagnosing a phone; `nil` writes up to that.
        public let sendMTU: UInt16?

        /// Sockets on the adapter with `adapter`'s address, offering `receiveMTU` and writing SDUs of at most
        /// `sendMTU`, when given.
        public init(adapter: BluetoothAddress, receiveMTU: UInt16 = largestReceiveMTU, sendMTU: UInt16? = nil) {
            self.adapter = adapter
            self.receiveMTU = receiveMTU
            self.sendMTU = sendMTU
        }

        public func listen() throws(SocketError) -> ListeningSocket {
            let descriptor = try Self.open(on: adapter, receiveMTU: receiveMTU)
            do throws(SocketError) {
                guard Glibc.listen(descriptor, Self.backlog) == 0 else {
                    throw SocketError(call: "listen", code: errno)
                }
                var bound = knit_sockaddr_l2()
                var length = Self.addressLength
                let named = withUnsafeMutablePointer(to: &bound) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
                }
                guard named == 0 else {
                    throw SocketError(call: "getsockname", code: errno)
                }
                return ListeningSocket(descriptor: descriptor, psm: UInt16(littleEndian: bound.l2_psm))
            } catch {
                Glibc.close(descriptor)
                throw error
            }
        }

        public func dial(_ target: DialTarget, psm: UInt16) throws(SocketError) -> Int32 {
            let descriptor = try Self.open(on: adapter, receiveMTU: receiveMTU)
            var remote = Self.address(target.address, type: target.isRandom ? KNIT_BDADDR_LE_RANDOM : KNIT_BDADDR_LE_PUBLIC, psm: psm)
            let result = withUnsafePointer(to: &remote) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, Self.addressLength) }
            }
            guard result == 0 || errno == EINPROGRESS else {
                let code = errno
                Glibc.close(descriptor)
                throw SocketError(call: "connect", code: code)
            }
            return descriptor
        }

        public func sendLimit(of descriptor: Int32) -> Int {
            var mtu: UInt16 = 0
            var length = socklen_t(MemoryLayout<UInt16>.size)
            guard getsockopt(descriptor, KNIT_SOL_BLUETOOTH, KNIT_BT_SNDMTU, &mtu, &length) == 0, mtu > 0 else {
                return Self.fallbackSendMTU
            }
            return min(Int(mtu), Self.largestWrite, sendMTU.map(Int.init) ?? Self.largestWrite)
        }

        public func peer(of descriptor: Int32) -> DialTarget? {
            var remote = knit_sockaddr_l2()
            var length = Self.addressLength
            let named = withUnsafeMutablePointer(to: &remote) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(descriptor, $0, &length) }
            }
            guard named == 0 else {
                return nil
            }
            let random = Int32(remote.l2_bdaddr_type) == KNIT_BDADDR_LE_RANDOM
            // bdaddr_t is least significant first.
            let address = withUnsafeBytes(of: remote.l2_bdaddr) { BluetoothAddress(bytes: Array($0.reversed())) }
            return address.map { DialTarget(address: $0, isRandom: random) }
        }

        /// A non-blocking LE socket bound to the adapter, at low security, offering the large receive MTU.
        private static func open(on adapter: BluetoothAddress, receiveMTU: UInt16) throws(SocketError) -> Int32 {
            let kind = Int32(SOCK_SEQPACKET.rawValue) | Int32(SOCK_NONBLOCK.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
            let descriptor = socket(KNIT_AF_BLUETOOTH, kind, KNIT_BTPROTO_L2CAP)
            guard descriptor >= 0 else {
                throw SocketError(call: "socket", code: errno)
            }
            var local = address(adapter, type: KNIT_BDADDR_LE_PUBLIC, psm: 0)
            let bound = withUnsafePointer(to: &local) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, addressLength) }
            }
            var security = knit_bt_security(level: UInt8(KNIT_BT_SECURITY_LOW), key_size: 0)
            let secured = setsockopt(
                descriptor,
                KNIT_SOL_BLUETOOTH,
                KNIT_BT_SECURITY,
                &security,
                socklen_t(MemoryLayout<knit_bt_security>.size)
            )
            guard bound == 0, secured == 0 else {
                let failure = SocketError(call: bound == 0 ? "setsockopt(BT_SECURITY)" : "bind", code: errno)
                Glibc.close(descriptor)
                throw failure
            }
            // A kernel that refuses a larger MTU keeps its default of 672, which still works: Android then writes
            // smaller SDUs.
            var mtu = receiveMTU
            _ = setsockopt(descriptor, KNIT_SOL_BLUETOOTH, KNIT_BT_RCVMTU, &mtu, socklen_t(MemoryLayout<UInt16>.size))
            return descriptor
        }

        private static let addressLength = socklen_t(MemoryLayout<knit_sockaddr_l2>.size)

        private static func address(_ address: BluetoothAddress, type: Int32, psm: UInt16) -> knit_sockaddr_l2 {
            var sockaddr = knit_sockaddr_l2()
            sockaddr.l2_family = sa_family_t(KNIT_AF_BLUETOOTH)
            sockaddr.l2_psm = psm.littleEndian
            // bdaddr_t is six bytes, least significant first; copy them over the tuple Swift imports it as.
            withUnsafeMutableBytes(of: &sockaddr.l2_bdaddr) { raw in
                for (index, byte) in address.littleEndian.prefix(raw.count).enumerated() {
                    raw[index] = byte
                }
            }
            sockaddr.l2_bdaddr_type = UInt8(type)
            return sockaddr
        }
    }
#endif
