import KnitAppCore
import Testing

/// Every range a link card's fetch refuses, at its edges, and the rule that refuses a whole name: every case of
/// knit-next's `PublicAddressPolicyTest.kt` and `OkHttpPreviewFetcherDnsTest.kt`, then the first and last address of each
/// refused block beside the addresses just outside it (ADR 2026-11.hcvg).
@Suite struct PublicAddressPolicyTests {
    // MARK: PublicAddressPolicyTest.kt

    /// `theIpv4PrivateAndSpecialRangesAreRefusedAtTheirEdges`, its refused half.
    @Test(arguments: [
        "0.0.0.0", "0.255.255.255", "10.0.0.0", "10.255.255.255", "127.0.0.1", "127.255.255.255",
        "100.64.0.0", "100.127.255.255", "169.254.0.1", "169.254.255.255",
        "172.16.0.0", "172.31.255.255", "192.0.0.1", "192.168.0.0", "192.168.255.255",
        "198.18.0.0", "198.19.255.255", "224.0.0.1", "239.255.255.255", "240.0.0.1", "255.255.255.255",
    ])
    func theIPv4PrivateAndSpecialRangesAreRefusedAtTheirEdges(literal: String) throws {
        #expect(try !isPublic(literal))
    }

    /// `theIpv4PrivateAndSpecialRangesAreRefusedAtTheirEdges`, its allowed half.
    @Test(arguments: [
        "11.0.0.0", "9.255.255.255", "100.63.255.255", "100.128.0.0", "169.253.255.255", "169.255.0.0",
        "172.15.255.255", "172.32.0.0", "192.0.1.1", "192.167.255.255", "192.169.0.0", "198.17.255.255",
        "198.20.0.0", "223.255.255.255", "8.8.8.8", "1.1.1.1",
    ])
    func theIPv4AddressesBesideThoseRangesAreAllowed(literal: String) throws {
        #expect(try isPublic(literal))
    }

    /// `theIpv6LocalAndSpecialRangesAreRefused`, its refused half.
    @Test(arguments: ["::", "::1", "fc00::1", "fdff:ffff::1", "fe80::1", "febf::1", "fec0::1", "ff02::1", "ff00::"])
    func theIPv6LocalAndSpecialRangesAreRefused(literal: String) throws {
        #expect(try !isPublic(literal))
    }

    /// `theIpv6LocalAndSpecialRangesAreRefused`, its allowed half.
    @Test(arguments: ["fe00::1", "fe7f::1", "2606:4700::1111", "2001:4860:4860::8888", "fbff::1"])
    func theIPv6AddressesBesideThoseRangesAreAllowed(literal: String) throws {
        #expect(try isPublic(literal))
    }

    /// `anEmbeddedIpv4IsJudgedByTheIpv4Rules`, its refused half: the IPv4-mapped and IPv4-compatible forms, NAT64 and
    /// 6to4 each carry an IPv4 address that must not slip past.
    @Test(arguments: [
        "::ffff:10.0.0.1", "::ffff:127.0.0.1", "::ffff:192.168.1.1", "::10.0.0.1",
        "64:ff9b::a00:1", "64:ff9b::7f00:1", "2002:0a00:1::", "2002:c0a8:101::",
    ])
    func anEmbeddedPrivateIPv4IsRefusedByTheIPv4Rules(literal: String) throws {
        #expect(try !isPublic(literal))
    }

    /// `anEmbeddedIpv4IsJudgedByTheIpv4Rules`, its allowed half.
    @Test(arguments: ["::ffff:8.8.8.8", "::ffff:1.1.1.1", "64:ff9b::808:808", "2002:808:808::"])
    func anEmbeddedPublicIPv4IsAllowedByTheIPv4Rules(literal: String) throws {
        #expect(try isPublic(literal))
    }

    /// `anAddressOfAnyOtherLengthIsRefused`.
    @Test(arguments: [[], [8, 8, 8], [8, 8, 8, 8, 8], [UInt8](repeating: 0x20, count: 17)] as [[UInt8]])
    func anAddressOfAnyOtherLengthIsRefused(address: [UInt8]) {
        #expect(!PublicAddressPolicy.isPublic(address))
    }

    // MARK: OkHttpPreviewFetcherDnsTest.kt, as `BoundDns`'s rule

    /// `aNameThatResolvesPrivatelyIsRefusedWithoutASocket`: Android's lookup refuses the name, so OkHttp opens no socket.
    @Test func aNameThatResolvesPrivatelyIsRefused() throws {
        #expect(try !PublicAddressPolicy.allPublic([Literal.require("10.0.0.1")]))
    }

    /// `aRedirectOntoAPrivateNameIsRefusedOnThatHop`: every hop looks its host up again, so a public page that redirects
    /// the fetch inward is fetched, and the private name it points at is refused on the next hop.
    @Test func aRedirectOntoAPrivateNameIsRefusedOnThatHop() throws {
        let hops = [[try Literal.require("1.1.1.1")], [try Literal.require("192.168.1.1")]]
        #expect(hops.map(PublicAddressPolicy.allPublic) == [true, false])
    }

    /// `aNameThatResolvesPubliclyIsFetched`, the control: the rule lets a public name through, so the refusals above are
    /// the rule's.
    @Test func aNameThatResolvesPubliclyIsFetched() throws {
        #expect(try PublicAddressPolicy.allPublic([Literal.require("1.1.1.1")]))
    }

    /// `BoundDns.lookup` throws on an empty answer, so a name with no address is refused.
    @Test func aNameWithNoAddressIsRefused() {
        #expect(!PublicAddressPolicy.allPublic([]))
    }

    /// Mixed public and private records are how a rebinding attack looks, so one refused address anywhere in the answer
    /// refuses the name.
    @Test(arguments: [
        ["10.0.0.1", "8.8.8.8", "2606:4700::1111"],
        ["8.8.8.8", "fe80::1", "2606:4700::1111"],
        ["8.8.8.8", "2606:4700::1111", "::ffff:127.0.0.1"],
    ])
    func oneRefusedAddressAnywhereRefusesTheName(literals: [String]) throws {
        #expect(try !PublicAddressPolicy.allPublic(literals.map(Literal.require)))
    }

    /// An address of the wrong length in an answer refuses the name like a private one.
    @Test func oneMalformedAddressRefusesTheName() throws {
        #expect(try !PublicAddressPolicy.allPublic([Literal.require("8.8.8.8"), [8, 8, 8]]))
    }

    /// An answer of public IPv4 and IPv6 addresses is fetched.
    @Test func anAnswerThatIsPublicInBothFamiliesIsFetched() throws {
        let literals = ["8.8.8.8", "1.1.1.1", "2606:4700::1111", "2001:4860:4860::8888"]
        #expect(try PublicAddressPolicy.allPublic(literals.map(Literal.require)))
    }

    // MARK: The edges of every block

    /// Each refused block's first and last address are refused, and the public addresses just outside it are allowed. A
    /// block with no `outside` borders refused addresses, or an end of the address space, on both sides.
    @Test(arguments: [
        Edges("0.0.0.0/8", inside: ["0.0.0.0", "0.255.255.255"], outside: ["1.0.0.0"]),
        Edges("10.0.0.0/8", inside: ["10.0.0.0", "10.255.255.255"], outside: ["9.255.255.255", "11.0.0.0"]),
        Edges("100.64.0.0/10", inside: ["100.64.0.0", "100.127.255.255"], outside: ["100.63.255.255", "100.128.0.0"]),
        Edges("127.0.0.0/8", inside: ["127.0.0.0", "127.255.255.255"], outside: ["126.255.255.255", "128.0.0.0"]),
        Edges("169.254.0.0/16", inside: ["169.254.0.0", "169.254.255.255"], outside: ["169.253.255.255", "169.255.0.0"]),
        Edges("172.16.0.0/12", inside: ["172.16.0.0", "172.31.255.255"], outside: ["172.15.255.255", "172.32.0.0"]),
        Edges("192.0.0.0/24", inside: ["192.0.0.0", "192.0.0.255"], outside: ["191.255.255.255", "192.0.1.0"]),
        Edges("192.168.0.0/16", inside: ["192.168.0.0", "192.168.255.255"], outside: ["192.167.255.255", "192.169.0.0"]),
        Edges("198.18.0.0/15", inside: ["198.18.0.0", "198.19.255.255"], outside: ["198.17.255.255", "198.20.0.0"]),
        Edges("224.0.0.0/4", inside: ["224.0.0.0", "239.255.255.255"], outside: ["223.255.255.255"]),
        Edges("240.0.0.0/4", inside: ["240.0.0.0", "255.255.255.255"], outside: []),
        Edges("::/128", inside: ["::"], outside: []),
        Edges("::1/128", inside: ["::1"], outside: []),
        Edges(
            "fc00::/7",
            inside: ["fc00::", "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"],
            outside: ["fbff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "fe00::"]
        ),
        Edges(
            "fe80::/10",
            inside: ["fe80::", "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff"],
            outside: ["fe7f:ffff:ffff:ffff:ffff:ffff:ffff:ffff"]
        ),
        Edges("fec0::/10", inside: ["fec0::", "feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"], outside: []),
        Edges("ff00::/8", inside: ["ff00::", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"], outside: []),
    ])
    func everyRefusedBlockEndsWhereItsRangeEnds(edges: Edges) throws {
        for literal in edges.inside {
            #expect(try !isPublic(literal), "\(literal) is in \(edges.block)")
        }
        for literal in edges.outside {
            #expect(try isPublic(literal), "\(literal) is outside \(edges.block)")
        }
    }

    /// Inside a mapped, compatible, NAT64 or 6to4 block the address it carries decides, read from where that block puts
    /// it. Just outside the block nothing is read, and these addresses are public.
    @Test(arguments: [
        ("::ffff:0.0.0.0", false), ("::ffff:255.255.255.255", false), ("::fffe:a00:1", true),
        ("::0.0.0.2", false), ("::255.255.255.255", false), ("::8.8.8.8", true), ("::1:0:0", true),
        ("64:ff9b::", false), ("64:ff9b::ffff:ffff", false), ("64:ff9a:ffff:ffff:ffff:ffff:ffff:ffff", true),
        ("64:ff9b::1:0:0", true),
        ("2002::", false), ("2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff", false),
        ("2001:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true), ("2003::", true),
        // 6to4 reads the two bytes after its prefix, not the last four.
        ("2002:808:808::a00:1", true), ("2002:a00:1::808:808", false),
    ])
    func anEmbeddedIPv4IsReadWhereItsBlockPutsItAndOnlyThere(literal: String, isPublic expected: Bool) throws {
        #expect(try isPublic(literal) == expected)
    }

    /// Kotlin reads an embedded address only inside 64:ff9b::/96. An address under NAT64's local-use prefix 64:ff9b:1::/48
    /// (RFC 8215) falls in no block, so it is public even when it carries 10.0.0.1. The port keeps Kotlin's verdict.
    @Test func theLocalUseNAT64PrefixGoesUnreadAsInKotlin() throws {
        #expect(try isPublic("64:ff9b:1::a00:1"))
    }

    /// Java's `InetAddress.getByName` turns `::ffff:a.b.c.d` into a 4-byte address, so the Kotlin test judged the mapped
    /// cases by the IPv4 path alone. Here the literal keeps its 16 bytes, and the IPv6 path reaches the same verdict.
    @Test(arguments: ["0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.1.1", "192.0.0.8", "198.18.0.1", "224.0.0.1", "8.8.8.8"])
    func aMappedAddressIsJudgedAsItsIPv4(literal: String) throws {
        #expect(try isPublic("::ffff:" + literal) == isPublic(literal))
    }

    /// Only the length refuses these: the same bytes at 4 or 16 are public.
    @Test(arguments: [1, 2, 6, 8, 12, 15, 32])
    func anyLengthButFourOrSixteenIsRefused(length: Int) {
        #expect(PublicAddressPolicy.isPublic([8, 8, 8, 8]))
        #expect(PublicAddressPolicy.isPublic([UInt8](repeating: 0x20, count: 16)))
        #expect(!PublicAddressPolicy.isPublic([UInt8](repeating: 8, count: length)))
        #expect(!PublicAddressPolicy.isPublic([UInt8](repeating: 0x20, count: length)))
    }

    // MARK: The literal parser

    /// The parser the cases above lean on reads each literal into the bytes Java reads, a mapped literal apart.
    @Test func theLiteralParserReadsWhatJavaReads() throws {
        #expect(try Literal.require("192.168.1.1") == [192, 168, 1, 1])
        #expect(try Literal.require("::") == [UInt8](repeating: 0, count: 16))
        #expect(try Literal.require("::1") == [UInt8](repeating: 0, count: 15) + [1])
        #expect(try Literal.require("64:ff9b::a00:1") == [0, 0x64, 0xFF, 0x9B] + [UInt8](repeating: 0, count: 8) + [10, 0, 0, 1])
        #expect(try Literal.require("2002:c0a8:101::") == [0x20, 0x02, 0xC0, 0xA8, 0x01, 0x01] + [UInt8](repeating: 0, count: 10))
        #expect(try Literal.require("::ffff:10.0.0.1") == [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 10, 0, 0, 1])
        #expect(try Literal.require("1:2:3:4:5:6:7:8") == [0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8])
    }

    @Test(arguments: [
        "", "1.2.3", "1.2.3.4.5", "256.0.0.1", "1..2.3", "1::2::3", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "12345::", "::g", ":::",
    ])
    func theLiteralParserRefusesMalformedText(literal: String) {
        #expect(Literal.bytes(literal) == nil)
    }

    /// One refused block's edges: its first and last address, and the public addresses just outside it.
    struct Edges: CustomTestStringConvertible {
        let block: String
        let inside: [String]
        let outside: [String]

        var testDescription: String { block }

        init(_ block: String, inside: [String], outside: [String]) {
            self.block = block
            self.inside = inside
            self.outside = outside
        }
    }

    /// Whether the policy calls `literal` public, failing the test when it is no address.
    private func isPublic(_ literal: String) throws -> Bool {
        try PublicAddressPolicy.isPublic(Literal.require(literal))
    }
}

/// Address literals read into raw bytes, in place of the `InetAddress.getByName` the Kotlin tests parse with. Unlike Java,
/// an IPv4-mapped literal keeps its 16 bytes, so the policy's IPv6 path judges it.
private enum Literal {
    /// The bytes of `text`, failing the test when it is no address.
    static func require(_ text: String) throws -> [UInt8] {
        try #require(bytes(text), "\(text) is no address")
    }

    /// The bytes of `text`, a dotted IPv4 literal or an IPv6 one with `::` and a trailing dotted quad, or `nil`.
    static func bytes(_ text: String) -> [UInt8]? {
        text.contains(":") ? ipv6(text) : ipv4(text[...])
    }

    private static func ipv4(_ text: Substring) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        return parts.count == 4 && octets.count == 4 ? octets : nil
    }

    private static func ipv6(_ text: String) -> [UInt8]? {
        let halves = text.split(separator: "::", omittingEmptySubsequences: false)
        guard halves.count <= 2, let head = groups(halves[0]), let tail = groups(halves.count == 2 ? halves[1] : "") else {
            return nil
        }
        let gap = 8 - head.count - tail.count
        guard halves.count == 2 ? gap >= 1 : gap == 0 else {
            return nil
        }
        let words = head + [UInt16](repeating: 0, count: gap) + tail
        return words.flatMap { [UInt8(truncatingIfNeeded: $0 >> 8), UInt8(truncatingIfNeeded: $0)] }
    }

    /// The 16-bit groups on one side of `::`, a trailing dotted quad read as two groups, or `nil` when one is malformed.
    private static func groups(_ text: Substring) -> [UInt16]? {
        guard !text.isEmpty else {
            return []
        }
        var parts = text.split(separator: ":", omittingEmptySubsequences: false)
        var quad: [UInt16] = []
        if let last = parts.last, last.contains(".") {
            guard let octets = ipv4(last) else {
                return nil
            }
            quad = [UInt16(octets[0]) << 8 | UInt16(octets[1]), UInt16(octets[2]) << 8 | UInt16(octets[3])]
            parts.removeLast()
        }
        let words = parts.compactMap { $0.count <= 4 ? UInt16($0, radix: 16) : nil }
        return words.count == parts.count ? words + quad : nil
    }
}
