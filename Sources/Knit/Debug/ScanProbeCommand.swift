#if os(iOS) && DEBUG
    import Foundation
    import KnitBLE
    import KnitControl
    import KnitMesh

    /// `{"cmd":"scan-filter","on":true}`: the scan probe of P8's scan-filter check (``ScanProbe``). Only the iPhone's
    /// radio has one, so the bridge answers it rather than ``MeshControl``. `on` turns the probe on, forgetting what it
    /// matched, or off; either way, or with `on` left out, the reply lists what it matched.
    internal struct ScanProbeCommand: Decodable {
        static let name = "scan-filter"

        let cmd: String
        let on: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let tag: String?

        /// The command on `line`, when it is this one.
        static func parse(_ line: String) -> Self? {
            guard let command = try? JSONDecoder().decode(Self.self, from: Data(line.utf8)), command.cmd == name else {
                return nil
            }
            return command
        }

        /// Does what it asks of `radio`, and answers with the probe as it then stands.
        func answer(_ radio: BLERadio?) async -> String {
            var reply: [String: JSONValue] = ["reply": .string(Self.name)]
            if let tag {
                reply["tag"] = .string(tag)
            }
            guard let radio else {
                reply["ok"] = false
                reply["error"] = "this build has no Bluetooth radio"
                return JSONValue.object(reply).line
            }
            if let on {
                radio.probeScan(on)
            }
            let probe = await radio.probeReport()
            reply["ok"] = true
            reply["on"] = .bool(probe.isOn)
            reply["away"] = .bool(probe.isAway)
            reply["awaySince"] = probe.awaySince.map(JSONValue.int) ?? .null
            reply["now"] = .int(SystemClock().wallMilliseconds())
            reply["matches"] = .array(probe.matched.map(Self.describe))
            return JSONValue.object(reply).line
        }

        private static func describe(_ match: ScanProbe.Match) -> JSONValue {
            .object([
                "peripheral": .string(match.peripheral),
                "node": .text(match.node),
                "serviceData": .bool(match.serviceData),
                "listed": .bool(match.listed),
                "overflow": .bool(match.overflow),
                "count": .int(Int64(match.count)),
                "awayCount": .int(Int64(match.awayCount)),
                "firstAt": .int(match.firstAt),
                "lastAt": .int(match.lastAt),
                "firstAwayAt": match.firstAwayAt.map(JSONValue.int) ?? .null,
                "rssi": .int(Int64(match.rssi)),
            ])
        }
    }
#endif
