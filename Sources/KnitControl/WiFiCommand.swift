import Foundation

/// How a connection reached a debug build's bridge: over USB, through usbmuxd to the phone's loopback, or over Wi-Fi
/// on a pinned network.
public enum BridgeOrigin: Sendable {
    /// The phone's loopback, which only a computer on the USB cable reaches.
    case usb
    /// The phone's Wi-Fi address, on a network pinned over USB.
    case wifi
}

/// The bridge's Wi-Fi commands, which the app answers rather than ``MeshControl``:
///
/// - `{"cmd":"wifi"}`: the network the phone is on, whether it is pinned, the address the bridge listens on over
///   Wi-Fi, and the pins.
/// - `{"cmd":"wifi-pin"}`: pins the network the phone is on, so the bridge listens there.
/// - `{"cmd":"wifi-unpin"}`: unpins it; `"all":true` unpins every network.
///
/// Pins change only over USB, so a connection over Wi-Fi cannot widen where the bridge listens.
public struct WiFiCommand: Equatable, Sendable {
    /// What the command asks.
    public enum Action: Equatable, Sendable {
        /// `wifi`.
        case report
        /// `wifi-pin`.
        case pin
        /// `wifi-unpin`.
        case unpin
        /// `wifi-unpin` with `"all":true`.
        case unpinAll
    }

    /// What it asks.
    public let action: Action
    /// Echoed as `"tag"` on the reply.
    public let tag: String?

    /// A command, as a caller builds one.
    public init(_ action: Action, tag: String? = nil) {
        self.action = action
        self.tag = tag
    }

    private struct Raw: Decodable {
        var cmd: String
        var all: Bool? // swiftlint:disable:this discouraged_optional_boolean
        var tag: String?
    }

    /// The command on `line`, when it is one of these.
    public static func parse(_ line: String) -> Self? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(line.utf8)) else {
            return nil
        }
        switch raw.cmd {
        case "wifi":
            return Self(.report, tag: raw.tag)
        case "wifi-pin":
            return Self(.pin, tag: raw.tag)
        case "wifi-unpin":
            return Self(raw.all == true ? .unpinAll : .unpin, tag: raw.tag)
        default:
            return nil
        }
    }

    /// The name a reply carries back.
    public var name: String {
        switch action {
        case .report:
            "wifi"
        case .pin:
            "wifi-pin"
        case .unpin, .unpinAll:
            "wifi-unpin"
        }
    }

    /// Does what the command asks of `pins`, for a connection that came from `origin`, on the network `facts`
    /// describe (nil when the phone is not on Wi-Fi), and answers. `listening` is the address the bridge listens on
    /// over Wi-Fi, if it does.
    public func answer(from origin: BridgeOrigin, facts: RouterFacts?, pins: inout RouterPins, listening: String?) -> String {
        var reply: [String: JSONValue] = ["reply": .string(name)]
        if let tag {
            reply["tag"] = .string(tag)
        }
        let outcome: Result<[String: JSONValue], Refusal>
        if action == .report {
            outcome = .success([
                "network": facts?.json ?? .null,
                "pinned": .bool(pins.match(facts) != nil),
                "listening": .text(listening),
            ])
        } else if origin != .usb {
            outcome = .failure(.overWiFi)
        } else {
            outcome = change(&pins, on: facts)
        }
        switch outcome {
        case .success(let fields):
            reply.merge(fields) { _, field in field }
            reply["ok"] = true
            reply["pins"] = pins.json
        case .failure(let refusal):
            reply["ok"] = false
            reply["error"] = .string(refusal.rawValue)
        }
        return JSONValue.object(reply).line
    }

    private func change(_ pins: inout RouterPins, on facts: RouterFacts?) -> Result<[String: JSONValue], Refusal> {
        if action == .unpinAll {
            return .success(["removed": .array(pins.clear().map(\.json))])
        }
        guard let facts else {
            return .failure(.notOnWiFi)
        }
        if action == .pin {
            guard let pin = pins.pin(facts) else {
                return .failure(.nothingToPin)
            }
            return .success(["pin": pin.json, "warnings": .array(pin.warnings.map(JSONValue.string))])
        }
        let removed = pins.unpin(facts)
        guard !removed.isEmpty else {
            return .failure(.notPinned)
        }
        return .success(["removed": .array(removed.map(\.json))])
    }

    /// Why a pin did not change.
    private enum Refusal: String, Error {
        case overWiFi = "pins change over USB only"
        case notOnWiFi = "the phone is not on Wi-Fi"
        case nothingToPin = "this Wi-Fi network has no IPv4 gateway and subnet to pin"
        case notPinned = "this network is not pinned"
    }
}
