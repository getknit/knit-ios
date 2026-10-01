import Foundation
import KnitControl
import Testing

/// The router pins that decide where a debug build's bridge listens over Wi-Fi.
@Suite struct RouterPinTests {
    private let home = RouterFacts(
        interface: "en0",
        address: "192.168.50.23",
        prefixLength: 24,
        gateway: "192.168.50.1",
        router6: "FE80::1A2B:3CFF:FE4D:5E6F%en0"
    )

    private func facts(
        address: String = "192.168.50.23",
        prefixLength: Int = 24,
        gateway: String? = "192.168.50.1",
        router6: String? = "fe80::1a2b:3cff:fe4d:5e6f"
    ) -> RouterFacts {
        RouterFacts(interface: "en0", address: address, prefixLength: prefixLength, gateway: gateway, router6: router6)
    }

    // MARK: Pinning

    @Test func aPinKeepsTheSubnetTheGatewayAndTheRouterWithoutItsScope() throws {
        let pin = try #require(RouterPin(home))
        #expect(pin.subnet == "192.168.50.0/24")
        #expect(pin.gateway == "192.168.50.1")
        #expect(pin.router6 == "fe80::1a2b:3cff:fe4d:5e6f")
        #expect(pin.warnings.isEmpty)
    }

    @Test func theRoutersAddressLosesItsScopeEvenWhenIOSWritesItTwice() {
        #expect(facts(router6: "FE80::2205:B6FF:FE01:8AE1%en0%en0").router6 == "fe80::2205:b6ff:fe01:8ae1")
        #expect(facts(router6: "%en0").router6 == nil)
        #expect(facts(router6: nil).router6 == nil)
    }

    @Test func nothingIsPinnedWithoutAGatewayOrAnAddressOrAPrefix() {
        #expect(RouterPin(facts(gateway: nil)) == nil)
        #expect(RouterPin(facts(gateway: "router")) == nil)
        #expect(RouterPin(facts(address: "192.168.50")) == nil)
        #expect(RouterPin(facts(address: "192.168.50.256")) == nil)
        #expect(RouterPin(facts(address: "192.168..23")) == nil)
        #expect(RouterPin(facts(prefixLength: 0)) == nil)
        #expect(RouterPin(facts(prefixLength: 33)) == nil)
    }

    @Test func theSubnetFollowsThePrefixLength() throws {
        let cases: [(RouterFacts, String)] = [
            (facts(address: "10.47.12.9", prefixLength: 8), "10.0.0.0/8"),
            (facts(address: "172.20.5.9", prefixLength: 16), "172.20.0.0/16"),
            (facts(address: "192.168.50.23", prefixLength: 24), "192.168.50.0/24"),
            (facts(address: "192.168.50.6", prefixLength: 30), "192.168.50.4/30"),
            (facts(address: "192.168.50.6", prefixLength: 32), "192.168.50.6/32"),
            (facts(address: "255.255.255.255", prefixLength: 1), "128.0.0.0/1"),
        ]
        for (network, subnet) in cases {
            let pin = try #require(RouterPin(network))
            #expect(pin.subnet == subnet, "\(network.address)/\(network.prefixLength)")
        }
    }

    @Test func aPinWarnsWhenItRestsOnIPv4Alone() throws {
        let noRouter = try #require(RouterPin(facts(router6: nil)))
        #expect(noRouter.router6 == nil)
        #expect(noRouter.warnings == ["the network has no IPv6 router, so the pin rests on the IPv4 gateway and subnet alone"])
        let generic = try #require(RouterPin(facts(router6: "FE80::1%en0")))
        #expect(generic.warnings == ["the IPv6 router is the generic fe80::1, so the pin rests on the IPv4 gateway and subnet alone"])
        #expect(try #require(RouterPin(facts(router6: "%en0"))).router6 == nil)
    }

    // MARK: Matching

    @Test func theSameNetworkMatchesWhereverThePhoneSitsOnIt() throws {
        let pin = try #require(RouterPin(home))
        #expect(pin.matches(home))
        #expect(pin.matches(facts(address: "192.168.50.200")))
        #expect(pin.matches(facts(router6: "fe80::1a2b:3cff:fe4d:5e6f%en1")))
    }

    @Test func anyOtherValueIsAnotherNetwork() throws {
        let pin = try #require(RouterPin(home))
        #expect(!pin.matches(facts(gateway: "192.168.50.254")))
        #expect(!pin.matches(facts(gateway: nil)))
        #expect(!pin.matches(facts(address: "192.168.51.23")))
        #expect(!pin.matches(facts(prefixLength: 16)))
        #expect(!pin.matches(facts(prefixLength: 0)))
        #expect(!pin.matches(facts(address: "nowhere")))
        #expect(!pin.matches(facts(router6: "fe80::99")))
        #expect(!pin.matches(facts(router6: nil)))
    }

    @Test func aPinWithoutARouterTakesAnyRouter() throws {
        let pin = try #require(RouterPin(facts(router6: nil)))
        #expect(pin.matches(home))
        #expect(pin.matches(facts(router6: nil)))
    }

    @Test func onlyAddressesInsideTheSubnetGetIn() throws {
        let pin = try #require(RouterPin(home))
        #expect(pin.admits("192.168.50.10"))
        #expect(pin.admits("192.168.50.255"))
        #expect(pin.admits("192.168.50.10%en0"))
        #expect(!pin.admits("192.168.51.10"))
        #expect(!pin.admits("10.0.0.5"))
        #expect(!pin.admits("fe80::5"))
        let narrow = try #require(RouterPin(facts(address: "192.168.50.6", prefixLength: 30, gateway: "192.168.50.5")))
        #expect(narrow.admits("192.168.50.7"))
        #expect(!narrow.admits("192.168.50.8"))
    }

    // MARK: The pin list

    @Test func pinningTheSameNetworkAgainReplacesItsPin() throws {
        var pins = RouterPins()
        #expect(pins.match(home) == nil)
        #expect(pins.match(nil) == nil)
        let first = pins.pin(facts(router6: nil))
        let second = pins.pin(home)
        #expect(first != nil)
        #expect(first != second)
        #expect(pins.pins == [try #require(second)])
        let other = pins.pin(facts(address: "10.47.12.9", prefixLength: 24, gateway: "10.47.12.1", router6: nil))
        #expect(pins.pins == [try #require(second), try #require(other)])
        #expect(pins.match(home) == second)
        #expect(pins.pin(facts(gateway: nil)) == nil)
        #expect(pins.pins.count == 2)
    }

    @Test func unpinningRemovesWhatTheNetworkMatches() throws {
        var pins = RouterPins()
        let pin = try #require(RouterPin(home))
        #expect(pins.pin(home) == pin)
        #expect(pins.unpin(facts(gateway: "192.168.50.254")).isEmpty)
        #expect(pins.unpin(home) == [pin])
        #expect(pins.pins.isEmpty)
        _ = pins.pin(home)
        #expect(pins.clear() == [pin])
        #expect(pins.pins.isEmpty)
    }

    @Test func pinsSurviveASaveAndALoad() throws {
        var pins = RouterPins()
        _ = pins.pin(home)
        _ = pins.pin(facts(address: "10.47.12.9", gateway: "10.47.12.1", router6: nil))
        let data = try JSONEncoder().encode(pins)
        #expect(try JSONDecoder().decode(RouterPins.self, from: data) == pins)
        let saved = String(bytes: try JSONEncoder().encode(pins.pins[1]), encoding: .utf8)
        #expect(saved?.contains(#""subnet":"10.47.12.0\/24""#) == true)
    }

    @Test func aDamagedPinLoadsAsNothing() {
        let damaged = [
            #"[{"subnet":"192.168.50.0","gateway":"192.168.50.1"}]"#,
            #"[{"subnet":"192.168.50.0/40","gateway":"192.168.50.1"}]"#,
            #"[{"subnet":"192.168.50.7/24","gateway":"192.168.50.1"}]"#,
            #"[{"subnet":"192.168.50.0/24","gateway":"gateway"}]"#,
            #"[{"subnet":"192.168.50.0/x","gateway":"192.168.50.1"}]"#,
            #"{"subnet":"192.168.50.0/24","gateway":"192.168.50.1"}"#,
        ]
        for text in damaged {
            #expect(throws: DecodingError.self, "\(text)") { try JSONDecoder().decode(RouterPins.self, from: Data(text.utf8)) }
        }
        let saved = #"[{"subnet":"192.168.50.0/24","gateway":"192.168.50.1","router6":"FE80::7%en0"}]"#
        #expect(throws: Never.self) {
            let pins = try JSONDecoder().decode(RouterPins.self, from: Data(saved.utf8))
            #expect(pins.pins.first?.router6 == "fe80::7")
        }
    }
}
