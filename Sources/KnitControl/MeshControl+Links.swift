import KnitMesh
import KnitWire

// Apart from the actor only to keep its file inside the lint's length.
extension MeshControl {
    /// The live links, with each one's HELLO version and capabilities, and every peer sighted.
    func links() async -> [String: JSONValue] {
        let links = await mesh.neighbors.map { neighbor -> JSONValue in
            [
                "peer": .string(neighbor.nodeId.string),
                "version": .int(Int64(neighbor.protocolVersion)),
                "capabilities": .string(neighbor.capabilities.hex),
            ]
        }
        let sightings = await mesh.sightings.map { sighting -> JSONValue in
            [
                "peer": .string(sighting.nodeId.string),
                "rssi": .int(Int64(sighting.smoothedRssi.rounded())),
                "dwellMs": .int(sighting.dwellMilliseconds),
                "lastSeenMs": .int(sighting.lastSeenAgoMilliseconds),
                "psm": .int(Int64(sighting.advert.psm)),
                "flags": .int(Int64(sighting.advert.flags)),
            ]
        }
        return ["links": .array(links), "sightings": .array(sightings)]
    }
}
