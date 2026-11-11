/// Whether an IP address is one a link card's fetch may connect to (`PublicAddressPolicy.kt` in knit-next,
/// ADR 2026-11.hcvg).
///
/// Whoever typed a link chose where the fetch opens its socket, so the fetch must never reach the addresses behind this
/// phone's own interfaces: the loopback, the LAN it is on, a link-local network, a carrier's NAT range. The fetch must ask
/// ``allPublic(_:)`` about every address a host resolves to, on every redirect hop, before it connects, as Android's
/// resolver does.
///
/// The rule reads raw bytes, so its tests need no resolver, and an IPv4 address carried inside an IPv6 one (mapped,
/// compatible, NAT64 or 6to4) is judged by the IPv4 rules instead of slipping past them.
public enum PublicAddressPolicy {
    /// Whether `address`, 4 or 16 bytes in network order, is globally routable (`isPublic`). An address of any other
    /// length is refused.
    public static func isPublic(_ address: [UInt8]) -> Bool {
        switch address.count {
        case IPv4.bytes:
            isPublicV4(address, at: 0)
        case IPv6.bytes:
            isPublicV6(address)
        default:
            false
        }
    }

    /// Whether a host may be fetched, given every address it resolves to (`BoundDns.lookup` in `OkHttpPreviewFetcher.kt`):
    /// `false` when there are none, or when any one fails ``isPublic(_:)``. A name with both public and private records is
    /// what a rebinding attack looks like from here, so one private address refuses the whole name.
    public static func allPublic(_ addresses: [[UInt8]]) -> Bool {
        !addresses.isEmpty && addresses.allSatisfy(isPublic)
    }

    /// The IPv4 rules, on the four bytes of `bytes` from `offset` (`isPublicV4`): public unless they fall in one of
    /// ``IPv4/refused``.
    private static func isPublicV4(_ bytes: [UInt8], at offset: Int) -> Bool {
        let address: UInt32 = bigEndian(bytes[offset..<offset + IPv4.bytes])
        return !IPv4.refused.contains { lies(address, in: $0) }
    }

    /// The IPv6 rules (`isPublicV6`): the first of ``IPv6/rules`` whose block holds the address decides, and an address
    /// in none of them is public.
    private static func isPublicV6(_ bytes: [UInt8]) -> Bool {
        let address: UInt128 = bigEndian(bytes)
        let verdict = IPv6.rules.first { lies(address, in: $0.block) }?.verdict
        switch verdict {
        case .refused:
            return false
        case .ipv4(let offset):
            return isPublicV4(bytes, at: offset)
        case nil:
            return true
        }
    }

    /// `bytes` read as one unsigned integer in network order, the first byte the most significant.
    private static func bigEndian<Address: FixedWidthInteger & UnsignedInteger>(_ bytes: some Sequence<UInt8>) -> Address {
        bytes.reduce(Address.zero) { $0 << UInt8.bitWidth | Address($1) }
    }

    /// Whether `address` lies in `block`: whether its leading `prefixLength` bits are the network's.
    private static func lies<Address: FixedWidthInteger & UnsignedInteger>(_ address: Address, in block: Block<Address>) -> Bool {
        let hostBits = Address.bitWidth - block.prefixLength
        return address >> hostBits == block.network >> hostBits
    }

    /// An address block in CIDR form: its first address, and how many leading bits every address in it shares.
    private typealias Block<Address> = (network: Address, prefixLength: Int)

    /// What an IPv6 block makes of an address in it.
    private enum Verdict {
        /// Not public, whatever else the address holds.
        case refused
        /// Judged by the IPv4 rules, on the four bytes the address carries from this offset.
        case ipv4(at: Int)
    }

    /// The IPv4 blocks `isPublicV4` refuses.
    private enum IPv4 {
        /// An IPv4 address's length in bytes (`V4_BYTES`).
        static let bytes = 4
        /// 0.0.0.0/8, "this network".
        static let thisNetwork: Block<UInt32> = (0x00_00_00_00, 8)
        /// 10.0.0.0/8, private (RFC 1918).
        static let private10: Block<UInt32> = (0x0A_00_00_00, 8)
        /// 100.64.0.0/10, carrier-grade NAT (RFC 6598).
        static let carrierGradeNAT: Block<UInt32> = (0x64_40_00_00, 10)
        /// 127.0.0.0/8, loopback.
        static let loopback: Block<UInt32> = (0x7F_00_00_00, 8)
        /// 169.254.0.0/16, link-local.
        static let linkLocal: Block<UInt32> = (0xA9_FE_00_00, 16)
        /// 172.16.0.0/12, private (RFC 1918).
        static let private172: Block<UInt32> = (0xAC_10_00_00, 12)
        /// 192.0.0.0/24, IETF protocol assignments.
        static let protocolAssignments: Block<UInt32> = (0xC0_00_00_00, 24)
        /// 192.168.0.0/16, private (RFC 1918).
        static let private192: Block<UInt32> = (0xC0_A8_00_00, 16)
        /// 198.18.0.0/15, benchmarking (RFC 2544).
        static let benchmarking: Block<UInt32> = (0xC6_12_00_00, 15)
        /// 224.0.0.0/4, multicast.
        static let multicast: Block<UInt32> = (0xE0_00_00_00, 4)
        /// 240.0.0.0/4, reserved, with the broadcast address 255.255.255.255 at its end. Kotlin refuses this block and
        /// ``multicast`` with one test, a first byte of 224 or more.
        static let reserved: Block<UInt32> = (0xF0_00_00_00, 4)
        /// Every block above, in `isPublicV4`'s order.
        static let refused = [
            thisNetwork, private10, carrierGradeNAT, loopback, linkLocal, private172, protocolAssignments, private192, benchmarking,
            multicast, reserved,
        ]
    }

    /// The IPv6 blocks `isPublicV6` reads, each with its verdict.
    private enum IPv6 {
        /// An IPv6 address's length in bytes (`V6_BYTES`).
        static let bytes = 16
        /// Where a mapped, compatible or NAT64 address carries its IPv4 address: its last four bytes.
        static let trailingIPv4At = bytes - IPv4.bytes
        /// ::/128, unspecified.
        static let unspecified: Block<UInt128> = (0, 128)
        /// ::1/128, loopback.
        static let loopback: Block<UInt128> = (1, 128)
        /// ::ffff:0:0/96, an IPv4-mapped address (`isV4Mapped`).
        static let ipv4Mapped: Block<UInt128> = (0x0000_0000_0000_0000_0000_FFFF_0000_0000, 96)
        /// ::/96, the deprecated IPv4-compatible form, whose first twelve bytes are zero (`zeroThrough(a, 12)`).
        static let ipv4Compatible: Block<UInt128> = (0, 96)
        /// 64:ff9b::/96, NAT64's well-known prefix (`isNat64`, RFC 6052).
        static let nat64: Block<UInt128> = (0x0064_FF9B_0000_0000_0000_0000_0000_0000, 96)
        /// 2002::/16, 6to4 (RFC 3056), which carries its IPv4 address right after the prefix.
        static let sixToFour: Block<UInt128> = (0x2002_0000_0000_0000_0000_0000_0000_0000, 16)
        /// Where a 6to4 address carries its IPv4 address: the two bytes after its prefix.
        static let sixToFourIPv4At = sixToFour.prefixLength / UInt8.bitWidth
        /// fc00::/7, unique local (RFC 4193).
        static let uniqueLocal: Block<UInt128> = (0xFC00_0000_0000_0000_0000_0000_0000_0000, 7)
        /// fe80::/10, link-local, where Android's Wi-Fi Aware link has its subnet.
        static let linkLocal: Block<UInt128> = (0xFE80_0000_0000_0000_0000_0000_0000_0000, 10)
        /// fec0::/10, site-local: deprecated, and still routable inside a site.
        static let siteLocal: Block<UInt128> = (0xFEC0_0000_0000_0000_0000_0000_0000_0000, 10)
        /// ff00::/8, multicast.
        static let multicast: Block<UInt128> = (0xFF00_0000_0000_0000_0000_0000_0000_0000, 8)
        /// Every block above in `isPublicV6`'s order, which is the order they are tried in.
        static let rules: [(block: Block<UInt128>, verdict: Verdict)] = [
            (unspecified, .refused),
            (loopback, .refused),
            (ipv4Mapped, .ipv4(at: trailingIPv4At)),
            (ipv4Compatible, .ipv4(at: trailingIPv4At)),
            (nat64, .ipv4(at: trailingIPv4At)),
            (sixToFour, .ipv4(at: sixToFourIPv4At)),
            (uniqueLocal, .refused),
            (linkLocal, .refused),
            (siteLocal, .refused),
            (multicast, .refused),
        ]
    }
}
