/// A relay address this build may dial (ADR 2026-11.adrq, P4b1): the only form a socket factory takes, built by one
/// factory and printed as its host alone.
///
/// ``init(_:allowCleartext:)`` takes the text through ``SpoolURL/canonical(_:)``, then requires, in order: a scheme this
/// build dials (``SpoolURL/isAcceptable(_:allowCleartext:)``), a plain address (``SpoolURL/isPlain(_:)``: printable ASCII,
/// no `@` and no `\` in the authority), no fragment, and at most ``maxBytes`` bytes. `ws://` is taken only when the caller
/// allows cleartext *and* the build is a debug one, only to a loopback or private address literal (or `localhost`), and
/// never with a `k=` token; a release build refuses `ws://` whatever the caller asks.
///
/// The text leaves through ``socketURLText`` alone, which the socket factory reads (and a later phase's Keychain layer).
/// Everywhere else a relay is its handle. ``description`` and ``debugDescription`` give the host (``SpoolURL/host(_:)``),
/// the mirror has no children, and there is no `Codable`, no string literal and no memberwise initializer, so neither a
/// log line, `String(reflecting:)` nor `dump` carries a token, user info or a path.
public struct AcceptedSpoolURL: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The longest address taken, in UTF-8 bytes.
    public static let maxBytes = 256

    private static let cleartextScheme = Array("ws://".utf8)
    private static let tokenName = Array("k".utf8)
    private static let asciiCaseBit: UInt8 = 0x20
    private static let byteRadix = 256
    private static let ipv4Parts = 4
    private static let ipv4Bits = 8
    private static let ipv6Groups = 8
    private static let maxHexDigits = 4
    /// An IPv6 literal's two sides of its one `::`.
    private static let compressionHalves = 2

    private let text: String

    /// The address, or `nil` when `raw` breaks any rule above. `allowCleartext` is the caller's debug setting; a release
    /// build refuses `ws://` whatever it says.
    public init?(_ raw: String, allowCleartext: Bool) {
        #if DEBUG
            self.init(raw, allowCleartext: allowCleartext, debugBuild: true)
        #else
            self.init(raw, allowCleartext: allowCleartext, debugBuild: false)
        #endif
    }

    /// The address as a build of the given kind takes it: `debugBuild` is the compile-time value in production, and a test
    /// passes `false` to reach the release rule.
    init?(_ raw: String, allowCleartext: Bool, debugBuild: Bool) {
        let cleartext = allowCleartext && debugBuild
        let canonical = SpoolURL.canonical(raw)
        let bytes = Array(canonical.utf8)
        guard bytes.count <= Self.maxBytes, SpoolURL.isAcceptable(canonical, allowCleartext: cleartext), SpoolURL.isPlain(canonical),
            !bytes.contains(UInt8(ascii: "#"))
        else {
            return nil
        }
        if bytes.starts(with: Self.cleartextScheme) {
            guard !Self.carriesToken(bytes), Self.isLocal(host: Self.hostName(bytes)) else {
                return nil
            }
        }
        text = canonical
    }

    /// The text the socket factory dials. The one way out for it: grep for this name to find every reader.
    public var socketURLText: String { text }

    /// The host and port alone.
    public var description: String { SpoolURL.host(text) }

    public var debugDescription: String { description }

    /// No children: a mirror of the text would hand `dump` the token.
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// Whether the query may carry a token: a parameter named `k` in either case, or any key holding a `%`, which a server
    /// may decode to one.
    private static func carriesToken(_ bytes: [UInt8]) -> Bool {
        guard let query = bytes.firstIndex(of: UInt8(ascii: "?")) else {
            return false
        }
        return bytes[(query + 1)...].split(separator: UInt8(ascii: "&")).contains { parameter in
            let key = parameter.prefix { $0 != UInt8(ascii: "=") }
            return key.contains(UInt8(ascii: "%")) || (parameter.count > key.count && key.map(asciiLowercase).elementsEqual(tokenName))
        }
    }

    private static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte | asciiCaseBit : byte
    }

    /// The host of a URL already known plain, without its port, brackets kept for an IPv6 literal.
    private static func hostName(_ bytes: [UInt8]) -> [UInt8] {
        let rest = bytes.dropFirst(cleartextScheme.count)
        let authority = Array(rest.prefix { $0 != UInt8(ascii: "/") && $0 != UInt8(ascii: "?") })
        if authority.first == UInt8(ascii: "[") {
            return authority.firstIndex(of: UInt8(ascii: "]")).map { Array(authority[...$0]) } ?? authority
        }
        return Array(authority.prefix { $0 != UInt8(ascii: ":") })
    }

    /// Whether `host` names this phone or the network it is on: `localhost`, an IPv4 literal in ``LocalBlocks/ipv4``, or an
    /// IPv6 literal in ``LocalBlocks/ipv6``. A name that is not a literal cannot be judged without a lookup, so it is
    /// refused.
    static func isLocal(host: [UInt8]) -> Bool {
        if host.elementsEqual("localhost".utf8) {
            return true
        }
        if host.first == UInt8(ascii: "["), host.last == UInt8(ascii: "]") {
            return ipv6(host.dropFirst().dropLast()).map { address in LocalBlocks.ipv6.contains { lies(address, in: $0) } } ?? false
        }
        return ipv4(host).map { address in LocalBlocks.ipv4.contains { lies(address, in: $0) } } ?? false
    }

    /// An address block in CIDR form: its first address, and how many leading bits every address in it shares.
    private typealias Block<Address> = (network: Address, prefixLength: Int)

    /// The blocks a cleartext debug relay may sit in: the phone itself and the networks it is on.
    private enum LocalBlocks {
        /// 127.0.0.0/8, loopback.
        static let loopback: Block<UInt32> = (0x7F00_0000, 8)
        /// 10.0.0.0/8, private.
        static let private10: Block<UInt32> = (0x0A00_0000, 8)
        /// 172.16.0.0/12, private.
        static let private172: Block<UInt32> = (0xAC10_0000, 12)
        /// 192.168.0.0/16, private.
        static let private192: Block<UInt32> = (0xC0A8_0000, 16)
        /// 169.254.0.0/16, link-local.
        static let linkLocal: Block<UInt32> = (0xA9FE_0000, 16)
        static let ipv4 = [loopback, private10, private172, private192, linkLocal]
        /// ::1/128, loopback.
        static let loopbackV6: Block<UInt128> = (1, 128)
        /// fc00::/7, unique local.
        static let uniqueLocal: Block<UInt128> = (0xFC00_0000_0000_0000_0000_0000_0000_0000, 7)
        /// fe80::/10, link-local.
        static let linkLocalV6: Block<UInt128> = (0xFE80_0000_0000_0000_0000_0000_0000_0000, 10)
        static let ipv6 = [loopbackV6, uniqueLocal, linkLocalV6]
    }

    /// Whether `address` lies in `block`.
    private static func lies<Address: FixedWidthInteger & UnsignedInteger>(_ address: Address, in block: Block<Address>) -> Bool {
        let hostBits = Address.bitWidth - block.prefixLength
        return hostBits >= Address.bitWidth ? true : address >> hostBits == block.network >> hostBits
    }

    /// The decimal digits.
    private static let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
    private static let maxDecimalDigits = 3
    private static let decimalRadix = 10

    /// Four decimal parts of at most three digits, each at most 255, as one number.
    private static func ipv4(_ text: some Collection<UInt8>) -> UInt32? {
        let parts = text.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard parts.count == ipv4Parts else {
            return nil
        }
        var address: UInt32 = 0
        for part in parts {
            // A leading zero reads as octal to some parsers, so a part of more than one digit never starts with one.
            guard (1...maxDecimalDigits).contains(part.count), part.allSatisfy(digits.contains),
                part.count == 1 || part.first != UInt8(ascii: "0")
            else {
                return nil
            }
            let value = part.reduce(0) { $0 * decimalRadix + Int($1 - UInt8(ascii: "0")) }
            guard value < byteRadix else {
                return nil
            }
            address = address << ipv4Bits | UInt32(value)
        }
        return address
    }

    /// Eight groups of at most four hex digits, or fewer with one `::`; no zone and no embedded IPv4.
    private static func ipv6(_ text: some Collection<UInt8>) -> UInt128? {
        let bytes = Array(text)
        let halves = split(bytes, on: Array("::".utf8))
        guard halves.count <= Self.compressionHalves, let head = groups(halves[0]) else {
            return nil
        }
        var groups = head
        if halves.count == Self.compressionHalves {
            guard let tail = Self.groups(halves[1]), head.count + tail.count < ipv6Groups else {
                return nil
            }
            groups += [UInt16](repeating: 0, count: ipv6Groups - head.count - tail.count) + tail
        }
        guard groups.count == ipv6Groups else {
            return nil
        }
        return groups.reduce(UInt128(0)) { $0 << UInt16.bitWidth | UInt128($1) }
    }

    private static func groups(_ text: [UInt8]) -> [UInt16]? {
        guard !text.isEmpty else {
            return []
        }
        var groups: [UInt16] = []
        for group in text.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false) {
            guard (1...maxHexDigits).contains(group.count) else {
                return nil
            }
            var value: UInt16 = 0
            for byte in group {
                guard let digit = hexDigit(byte) else {
                    return nil
                }
                value = value << hexBits | digit
            }
            groups.append(value)
        }
        return groups
    }

    private static let hexBits = 4
    private static let hexLetterBase: UInt16 = 10

    /// One hex digit's value, either case, or `nil`.
    private static func hexDigit(_ byte: UInt8) -> UInt16? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            UInt16(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            UInt16(byte - UInt8(ascii: "a")) + hexLetterBase
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            UInt16(byte - UInt8(ascii: "A")) + hexLetterBase
        default:
            nil
        }
    }

    /// `bytes` split at each `separator`, which must not repeat.
    private static func split(_ bytes: [UInt8], on separator: [UInt8]) -> [[UInt8]] {
        var parts: [[UInt8]] = []
        var start = 0
        var index = 0
        while index + separator.count <= bytes.count {
            if bytes[index..<(index + separator.count)].elementsEqual(separator) {
                parts.append(Array(bytes[start..<index]))
                index += separator.count
                start = index
            } else {
                index += 1
            }
        }
        parts.append(Array(bytes[start...]))
        return parts
    }
}
