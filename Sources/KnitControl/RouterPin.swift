import Foundation

/// What the phone's Wi-Fi path says about the network it is on: its own IPv4 address there and the prefix length,
/// the IPv4 gateway, and the IPv6 router's link-local address when the network has one. A debug build's bridge
/// listens on Wi-Fi only on a network whose facts match a ``RouterPin``.
public struct RouterFacts: Equatable, Sendable {
    /// The Wi-Fi interface's name, for the log.
    public let interface: String
    /// The phone's IPv4 address on it, dotted.
    public let address: String
    /// The prefix length of its netmask.
    public let prefixLength: Int
    /// The IPv4 gateway, dotted, when the network has one.
    public let gateway: String?
    /// The IPv6 router's link-local address, when the network has one, lowercased and without its scope.
    public let router6: String?

    /// Facts as the phone read them. iOS writes a link-local gateway's scope twice (`fe80::1%en0%en0`), and a pin
    /// keeps none, so the router's address loses its scope here.
    public init(interface: String, address: String, prefixLength: Int, gateway: String?, router6: String?) {
        self.interface = interface
        self.address = address
        self.prefixLength = prefixLength
        self.gateway = gateway
        self.router6 = RouterPin.normal(router6)
    }

    /// The facts as a reply shows them, with the subnet they put the phone on.
    var json: JSONValue {
        let subnet = IPv4.parse(address).flatMap { value in IPv4.subnet(value, prefixLength) }
        return .object([
            "interface": .string(interface),
            "address": .string(address),
            "subnet": .text(subnet),
            "gateway": .text(gateway),
            "router6": .text(router6),
        ])
    }
}

/// A Wi-Fi network the bridge may listen on, pinned over USB: its subnet and IPv4 gateway, and its IPv6 router's
/// link-local address when it had one. That address usually comes from the router's MAC, so it tells one router
/// from another where the IPv4 values often do not. A network matches when every recorded value is equal.
public struct RouterPin: Equatable, Sendable {
    private let network: UInt32
    private let prefixLength: Int
    private let gatewayAddress: UInt32
    /// The IPv6 router's link-local address, lowercased and without its scope; nil when the network had none.
    public let router6: String?

    /// The pin for the network `facts` describe, or nil when they give no IPv4 gateway and subnet to pin.
    public init?(_ facts: RouterFacts) {
        guard let address = IPv4.parse(facts.address), let via = facts.gateway.flatMap(IPv4.parse),
            let mask = IPv4.mask(facts.prefixLength)
        else {
            return nil
        }
        self.init(network: address & mask, prefixLength: facts.prefixLength, gateway: via, router6: facts.router6)
    }

    private init(network: UInt32, prefixLength: Int, gateway: UInt32, router6: String?) {
        self.network = network
        self.prefixLength = prefixLength
        gatewayAddress = gateway
        self.router6 = router6
    }

    /// The pinned subnet, as `192.168.50.0/24`.
    public var subnet: String {
        "\(IPv4.text(network))/\(prefixLength)"
    }

    /// The pinned IPv4 gateway, dotted.
    public var gateway: String {
        IPv4.text(gatewayAddress)
    }

    /// Why this pin is weaker than it looks: with no IPv6 router, or one at the generic `fe80::1`, it rests on the
    /// IPv4 gateway and subnet alone, which many networks share.
    public var warnings: [String] {
        switch router6 {
        case nil:
            ["the network has no IPv6 router, so the pin rests on the IPv4 gateway and subnet alone"]
        case .some(Self.genericRouter):
            ["the IPv6 router is the generic \(Self.genericRouter), so the pin rests on the IPv4 gateway and subnet alone"]
        default:
            []
        }
    }

    /// Whether the phone, as `facts` describe its network, is on this pinned one.
    public func matches(_ facts: RouterFacts) -> Bool {
        guard let address = IPv4.parse(facts.address), let via = facts.gateway.flatMap(IPv4.parse),
            let mask = IPv4.mask(facts.prefixLength)
        else {
            return false
        }
        return facts.prefixLength == prefixLength && address & mask == network && via == gatewayAddress
            && (router6 == nil || router6 == facts.router6)
    }

    /// Whether a connection from `remote`, a dotted IPv4 address, comes from inside the pinned subnet.
    public func admits(_ remote: String) -> Bool {
        guard let address = IPv4.parse(remote), let mask = IPv4.mask(prefixLength) else {
            return false
        }
        return address & mask == network
    }

    var json: JSONValue {
        .object(["subnet": .string(subnet), "gateway": .string(gateway), "router6": .text(router6)])
    }

    private static let genericRouter = "fe80::1"

    /// An IPv6 address as a pin keeps it: lowercased, without the `%en0` scope a link-local address carries.
    static func normal(_ address: String?) -> String? {
        guard let address, let bare = address.split(separator: "%", omittingEmptySubsequences: false).first, !bare.isEmpty else {
            return nil
        }
        return bare.lowercased()
    }
}

extension RouterPin: Codable {
    /// A pin as the phone saves it.
    private struct Saved: Codable {
        var subnet: String
        var gateway: String
        var router6: String?
    }

    /// A subnet is an address and a prefix length.
    private static let subnetParts = 2

    /// A pin as the phone saved it; one that does not parse is refused, so a damaged pin admits nothing.
    public init(from decoder: any Decoder) throws {
        let saved = try Saved(from: decoder)
        let parts = saved.subnet.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == Self.subnetParts, let network = IPv4.parse(String(parts[0])), let prefixLength = Int(parts[1]),
            let mask = IPv4.mask(prefixLength), network & mask == network, let via = IPv4.parse(saved.gateway)
        else {
            let why = "not a pin: \(saved.subnet) via \(saved.gateway)"
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: why))
        }
        self.init(network: network, prefixLength: prefixLength, gateway: via, router6: Self.normal(saved.router6))
    }

    public func encode(to encoder: any Encoder) throws {
        try Saved(subnet: subnet, gateway: gateway, router6: router6).encode(to: encoder)
    }
}

/// Every network the bridge may listen on over Wi-Fi, as the phone keeps them.
public struct RouterPins: Equatable, Sendable {
    /// The pins, oldest first.
    public private(set) var pins: [RouterPin]

    /// The pins given, none by default.
    public init(_ pins: [RouterPin] = []) {
        self.pins = pins
    }

    /// The pin the network `facts` describe matches, if any.
    public func match(_ facts: RouterFacts?) -> RouterPin? {
        facts.flatMap { facts in pins.first { $0.matches(facts) } }
    }

    /// Pins the network `facts` describe, in place of any pin with the same subnet and gateway; nil when there is
    /// nothing to pin.
    public mutating func pin(_ facts: RouterFacts) -> RouterPin? {
        guard let pin = RouterPin(facts) else {
            return nil
        }
        pins.removeAll { $0.subnet == pin.subnet && $0.gateway == pin.gateway }
        pins.append(pin)
        return pin
    }

    /// Removes every pin the network `facts` describe matches, and returns them.
    public mutating func unpin(_ facts: RouterFacts) -> [RouterPin] {
        let removed = pins.filter { $0.matches(facts) }
        pins.removeAll { $0.matches(facts) }
        return removed
    }

    /// Removes every pin, and returns them.
    @discardableResult
    public mutating func clear() -> [RouterPin] {
        let removed = pins
        pins = []
        return removed
    }

    var json: JSONValue {
        .array(pins.map(\.json))
    }
}

extension RouterPins: Codable {
    /// The pins as the phone saved them: a JSON array.
    public init(from decoder: any Decoder) throws {
        pins = try decoder.singleValueContainer().decode([RouterPin].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(pins)
    }
}

/// Dotted IPv4 addresses as 32-bit numbers, for subnet arithmetic.
internal enum IPv4 {
    private static let octets = 4
    private static let bits = 32
    private static let octetBits = 8
    private static let octetMask: UInt32 = 0xFF

    /// `192.168.50.23` as a number, ignoring a `%scope`; nil when it is not four octets.
    static func parse(_ text: String) -> UInt32? {
        guard let bare = text.split(separator: "%", omittingEmptySubsequences: false).first else {
            return nil
        }
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == octets else {
            return nil
        }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else {
                return nil
            }
            value = value << octetBits | UInt32(octet)
        }
        return value
    }

    /// A number as a dotted address.
    static func text(_ value: UInt32) -> String {
        stride(from: bits - octetBits, through: 0, by: -octetBits).map { shift in String(value >> UInt32(shift) & octetMask) }
            .joined(separator: ".")
    }

    /// The netmask of a prefix length from 1 to 32, or nil for any other.
    static func mask(_ prefixLength: Int) -> UInt32? {
        guard (1...bits).contains(prefixLength) else {
            return nil
        }
        return UInt32.max << UInt32(bits - prefixLength)
    }

    /// The subnet `address` is on, as `192.168.50.0/24`.
    static func subnet(_ address: UInt32, _ prefixLength: Int) -> String? {
        mask(prefixLength).map { mask in "\(text(address & mask))/\(prefixLength)" }
    }
}
