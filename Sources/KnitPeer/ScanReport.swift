import KnitControl
public import KnitMesh
public import KnitWire

/// What `knit-peer scan` heard: every Knit node in range, by advertised form, with its strongest signal. A node is
/// reported the first time it is heard, and all of them again at the end. A blinding Android's tag is reported under a
/// handle, `~zzzz…<n>`, numbered for the scan, never as the tag (ADR 2026-11.sv5t), its flags saying it is blinded.
public struct ScanReport: Sendable {
    private struct Heard: Sendable {
        var advert: AdvertPayload
        var address: RadioAddress
        var strongest: Int
        var count: Int
        /// A tag's handle number, in the order tags were heard; read for a tag only.
        let handle: Int
    }

    /// An advertised form: a clear id and a tag of the same bytes are two.
    private struct Form: Hashable, Sendable {
        let advertised: NodeId
        let blinded: Bool
    }

    private var heard: [Form: Heard] = [:]
    /// Tags heard so far: the next tag's handle number.
    private var tagsHeard = 0
    private let own: NodeId?

    /// A report that leaves out `own`, the node the scan advertises as, if any.
    public init(own: NodeId?) {
        self.own = own
    }

    /// Takes one sighting, and answers the event line when it is a node not heard before.
    public mutating func take(_ sighting: RadioSighting) -> String? {
        let node = Form(advertised: sighting.advert.advertised, blinded: sighting.advert.blinded)
        guard node.blinded || node.advertised != own else {
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
        let entry = Heard(advert: sighting.advert, address: sighting.address, strongest: sighting.rssi, count: 1, handle: tagsHeard)
        heard[node] = entry
        if node.blinded {
            tagsHeard += 1
        }
        var fields = fields(node, entry)
        fields["event"] = "sighted"
        return JSONValue.object(fields).line
    }

    /// The closing reply: every node heard, clear ids in node id order, then tags in the order heard.
    public var summary: String {
        let clear = heard.filter { !$0.key.blinded }.sorted { $0.key.advertised < $1.key.advertised }
        let tags = heard.filter(\.key.blinded).sorted { $0.value.handle < $1.value.handle }
        let nodes = (clear + tags).map { JSONValue.object(fields($0.key, $0.value)) }
        return JSONValue.object(["reply": "scan", "ok": true, "nodes": .array(nodes)]).line
    }

    private func fields(_ node: Form, _ heard: Heard) -> [String: JSONValue] {
        let peer = node.blinded ? "~zzzz…\(heard.handle)" : node.advertised.string
        return [
            "peer": .string(peer),
            "address": .string(heard.address.rawValue),
            "rssi": .int(Int64(heard.strongest)),
            "adverts": .int(Int64(heard.count)),
            "psm": .int(Int64(heard.advert.psm)),
            "flags": .int(Int64(heard.advert.flags)),
            "capabilities": .string(Capabilities(rawValue: Int64(heard.advert.capabilities)).hex),
        ]
    }
}
