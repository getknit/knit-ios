#if os(iOS) && DEBUG
    import Foundation
    import KnitAppCore

    /// The app's ``HostResolver``: `getaddrinfo`, off the main actor, every address of every family it answers with, so
    /// ``PreviewWalk`` can refuse a name when any one of them is not public (ADR 2026-11.hcvg).
    internal struct DarwinHostResolver: HostResolver {
        func addresses(of host: String) async -> [[UInt8]] {
            await Self.resolve(host)
        }

        @concurrent
        private static func resolve(_ host: String) async -> [[UInt8]] {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
                return []
            }
            defer { freeaddrinfo(first) }
            var found: [[UInt8]] = []
            var entry: UnsafeMutablePointer<addrinfo>? = first
            while let current = entry {
                if let address = bytes(of: current.pointee) {
                    found.append(address)
                }
                entry = current.pointee.ai_next
            }
            return found
        }

        /// The raw address `info` holds: 4 bytes for IPv4, 16 for IPv6, `nil` for any other family.
        private static func bytes(of info: addrinfo) -> [UInt8]? {
            guard let address = info.ai_addr else {
                return nil
            }
            switch info.ai_family {
            case AF_INET:
                return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                    withUnsafeBytes(of: inet.pointee.sin_addr) { Array($0) }
                }
            case AF_INET6:
                return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { inet6 in
                    withUnsafeBytes(of: inet6.pointee.sin6_addr) { Array($0) }
                }
            default:
                return nil
            }
        }
    }
#endif
