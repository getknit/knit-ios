public import KnitMesh
public import KnitWire

/// What `knit-peer scan` heard: every Knit node in range, by node id, with its strongest signal. A node is reported
/// the first time it is heard, and all of them again at the end.
public struct ScanReport: Sendable {
    private struct Heard: Sendable {
        var advert: AdvertPayload
        var address: RadioAddress
        var strongest: Int
        var count: Int
    }

    private var heard: [NodeId: Heard] = [:]
    private let own: NodeId?

    /// A report that leaves out `own`, the node the scan advertises as, if any.
    public init(own: NodeId?) {
        self.own = own
    }

    /// Takes one sighting, and answers the event line when it is a node not heard before.
    public mutating func take(_ sighting: RadioSighting) -> String? {
        let node = sighting.advert.nodeId
        guard node != own else {
            return nil
        }
        if var known = heard[node] {
            known.advert = sighting.advert
            known.address = sighting.address
            known.strongest = max(known.strongest, sighting.rssi)
            known.count += 1
            heard[node] = known
            return nil
        }
        let entry = Heard(advert: sighting.advert, address: sighting.address, strongest: sighting.rssi, count: 1)
        heard[node] = entry
        var fields = Self.fields(node, entry)
        fields["event"] = "sighted"
        return JSONValue.object(fields).line
    }

    /// The closing reply: every node heard, in node id order.
    public var summary: String {
        let nodes = heard.sorted { $0.key < $1.key }.map { JSONValue.object(Self.fields($0.key, $0.value)) }
        return JSONValue.object(["reply": "scan", "ok": true, "nodes": .array(nodes)]).line
    }

    private static func fields(_ node: NodeId, _ heard: Heard) -> [String: JSONValue] {
        [
            "peer": .string(node.string),
            "address": .string(heard.address.rawValue),
            "rssi": .int(Int64(heard.strongest)),
            "adverts": .int(Int64(heard.count)),
            "psm": .int(Int64(heard.advert.psm)),
            "flags": .int(Int64(heard.advert.flags)),
            "capabilities": .string(Capabilities(rawValue: Int64(heard.advert.capabilities)).hex),
        ]
    }
}
