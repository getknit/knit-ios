import KnitControl
import Testing

/// The bridge's Wi-Fi commands: what they parse from, and what they answer and change.
@Suite struct WiFiCommandTests {
    private let home = RouterFacts(
        interface: "en0",
        address: "192.168.50.23",
        prefixLength: 24,
        gateway: "192.168.50.1",
        router6: "fe80::7"
    )
    private let homePin = #"{"gateway":"192.168.50.1","router6":"fe80::7","subnet":"192.168.50.0/24"}"#

    @Test func theWiFiCommandsParse() {
        let cases: [(String, WiFiCommand)] = [
            (#"{"cmd":"wifi"}"#, WiFiCommand(.report)),
            (#"{"cmd":"wifi","tag":"t1"}"#, WiFiCommand(.report, tag: "t1")),
            (#"{"cmd":"wifi-pin"}"#, WiFiCommand(.pin)),
            (#"{"cmd":"wifi-unpin"}"#, WiFiCommand(.unpin)),
            (#"{"cmd":"wifi-unpin","all":false}"#, WiFiCommand(.unpin)),
            (#"{"cmd":"wifi-unpin","all":true}"#, WiFiCommand(.unpinAll)),
        ]
        for (line, command) in cases {
            #expect(WiFiCommand.parse(line) == command, "\(line)")
        }
        #expect(WiFiCommand.parse(#"{"cmd":"status"}"#) == nil)
        #expect(WiFiCommand.parse("not json") == nil)
        #expect(
            [WiFiCommand.Action.report, .pin, .unpin, .unpinAll].map { WiFiCommand($0).name } == [
                "wifi", "wifi-pin", "wifi-unpin", "wifi-unpin",
            ])
    }

    @Test func theReportSaysWhereThePhoneIsAndWhereItListens() {
        var pins = RouterPins()
        #expect(
            WiFiCommand(.report, tag: "t").answer(from: .wifi, facts: nil, pins: &pins, listening: nil)
                == #"{"listening":null,"network":null,"ok":true,"pinned":false,"pins":[],"reply":"wifi","tag":"t"}"#)
        _ = pins.pin(home)
        #expect(
            WiFiCommand(.report).answer(from: .usb, facts: home, pins: &pins, listening: "192.168.50.23")
                == #"{"listening":"192.168.50.23","network":{"address":"192.168.50.23","gateway":"192.168.50.1","interface":"en0","#
                + #""router6":"fe80::7","subnet":"192.168.50.0/24"},"ok":true,"pinned":true,"pins":[\#(homePin)],"reply":"wifi"}"#)
        let odd = RouterFacts(interface: "en1", address: "odd", prefixLength: 24, gateway: nil, router6: nil)
        #expect(
            WiFiCommand(.report).answer(from: .usb, facts: odd, pins: &pins, listening: nil)
                .contains(#""network":{"address":"odd","gateway":null,"interface":"en1","router6":null,"subnet":null}"#))
    }

    @Test func pinningOverUSBPinsTheNetworkThePhoneIsOn() {
        var pins = RouterPins()
        #expect(
            WiFiCommand(.pin, tag: "p").answer(from: .usb, facts: home, pins: &pins, listening: nil)
                == #"{"ok":true,"pin":\#(homePin),"pins":[\#(homePin)],"reply":"wifi-pin","tag":"p","warnings":[]}"#)
        #expect(pins.match(home) != nil)
        let bare = RouterFacts(interface: "en0", address: "10.47.12.9", prefixLength: 24, gateway: "10.47.12.1", router6: nil)
        #expect(
            WiFiCommand(.pin).answer(from: .usb, facts: bare, pins: &pins, listening: nil)
                .contains(#""warnings":["the network has no IPv6 router, so the pin rests on the IPv4 gateway and subnet alone"]"#))
        #expect(pins.pins.count == 2)
    }

    @Test func pinsChangeOverUSBOnly() {
        var pins = RouterPins()
        _ = pins.pin(home)
        let before = pins
        for action in [WiFiCommand.Action.pin, .unpin, .unpinAll] {
            let line = WiFiCommand(action).answer(from: .wifi, facts: home, pins: &pins, listening: "192.168.50.23")
            #expect(line.contains(#""error":"pins change over USB only""#), "\(action)")
            #expect(line.contains(#""ok":false"#))
            #expect(!line.contains(#""pins""#))
        }
        #expect(pins == before)
    }

    @Test func aPinNeedsANetworkWithAGateway() {
        var pins = RouterPins()
        #expect(
            WiFiCommand(.pin).answer(from: .usb, facts: nil, pins: &pins, listening: nil)
                == #"{"error":"the phone is not on Wi-Fi","ok":false,"reply":"wifi-pin"}"#)
        let noGateway = RouterFacts(interface: "en0", address: "169.254.3.4", prefixLength: 16, gateway: nil, router6: nil)
        #expect(
            WiFiCommand(.pin).answer(from: .usb, facts: noGateway, pins: &pins, listening: nil)
                == #"{"error":"this Wi-Fi network has no IPv4 gateway and subnet to pin","ok":false,"reply":"wifi-pin"}"#)
        #expect(pins.pins.isEmpty)
    }

    @Test func unpinningRemovesThisNetworkOrEvery() {
        var pins = RouterPins()
        #expect(
            WiFiCommand(.unpin).answer(from: .usb, facts: home, pins: &pins, listening: nil)
                == #"{"error":"this network is not pinned","ok":false,"reply":"wifi-unpin"}"#)
        #expect(
            WiFiCommand(.unpin).answer(from: .usb, facts: nil, pins: &pins, listening: nil)
                == #"{"error":"the phone is not on Wi-Fi","ok":false,"reply":"wifi-unpin"}"#)
        _ = pins.pin(home)
        #expect(
            WiFiCommand(.unpin).answer(from: .usb, facts: home, pins: &pins, listening: nil)
                == #"{"ok":true,"pins":[],"removed":[\#(homePin)],"reply":"wifi-unpin"}"#)
        _ = pins.pin(home)
        #expect(
            WiFiCommand(.unpinAll).answer(from: .usb, facts: nil, pins: &pins, listening: nil)
                == #"{"ok":true,"pins":[],"removed":[\#(homePin)],"reply":"wifi-unpin"}"#)
        #expect(pins.pins.isEmpty)
    }
}
