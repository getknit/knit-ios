import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire

/// The JSON shapes of what a reply or an event names: a peer, a message, a carried frame, the mesh's tables.
internal enum ControlLines {
    /// A pinned peer, with the name Android would show and the safety number both sides should read. `bundle` is ours.
    static func fields(of peer: PeerRecord, bundle: PublicKeyBundle) -> [String: JSONValue] {
        let node = peer.nodeId.string
        return [
            "peer": .string(node),
            "name": .string(peer.name),
            "displayName": .string(Alias.displayName(stored: peer.name, nodeId: node)),
            "alias": .string(Alias.alias(for: node)),
            "status": .string(peer.status),
            "openToChat": .bool(peer.openToChat),
            "verified": .bool(peer.verified),
            "capabilities": .text(peer.capabilities.map { Capabilities(rawValue: $0).hex }),
            "safetyNumber": .string(
                SafetyNumber.compute(
                    selfNodeId: bundle.nodeId.string,
                    selfBundle: bundle.encoded,
                    peerNodeId: node,
                    peerBundle: peer.publicKey
                )
            ),
        ]
    }

    static func fields(of record: MessageRecord) -> [String: JSONValue] {
        [
            "id": .string(record.id),
            "from": .string(record.senderId.string),
            "to": .text(record.recipientId?.string),
            "conv": .string(record.conversationId),
            "body": .string(record.body),
            "sentAt": .int(record.sentAt),
            "arrivedAt": record.arrivedAt.map(JSONValue.int) ?? .null,
            "delivered": .bool(record.delivered),
            "pendingKey": .bool(record.pendingKey),
        ]
    }

    /// A carried frame's addressing, for the `custody` reply.
    static func describe(_ envelope: RelayEnvelope) -> JSONValue {
        .object([
            "id": .string(envelope.id),
            "type": .string(envelope.type.rawValue),
            "from": .string(envelope.senderId),
            "to": .text(envelope.recipientId),
            "group": .text(envelope.group?.id),
            "sentAt": .int(envelope.sentAt),
        ])
    }

    /// A `link` event for each peer that came up or went down between `before` and `after`.
    static func linkChanges(from before: [Neighbor], to after: [Neighbor]) -> [String] {
        let was = Set(before.map(\.nodeId))
        let now = Set(after.map(\.nodeId))
        let ups = after.filter { !was.contains($0.nodeId) }.map { neighbor in
            JSONValue.object([
                "event": "link", "peer": .string(neighbor.nodeId.string), "up": true,
                "version": .int(Int64(neighbor.protocolVersion)), "capabilities": .string(neighbor.capabilities.hex),
            ])
            .line
        }
        let downs = before.filter { !now.contains($0.nodeId) }.map { neighbor in
            JSONValue.object(["event": "link", "peer": .string(neighbor.nodeId.string), "up": false]).line
        }
        return ups + downs
    }

    /// The mesh's in-memory tables, which a soak watches level off.
    static func describe(_ footprint: MeshFootprint) -> JSONValue {
        [
            "seen": .int(Int64(footprint.seen)),
            "pendingRelays": .int(Int64(footprint.pendingRelays)),
            "tombstones": .int(Int64(footprint.tombstones)),
            "earlyReceipts": .int(Int64(footprint.earlyReceipts)),
            "parked": .int(Int64(footprint.parked)),
            "owedTicks": .int(Int64(footprint.owedTicks)),
            "cachedProfiles": .int(Int64(footprint.cachedProfiles)),
            "missingKeys": .int(Int64(footprint.missingKeys)),
            "channels": .int(Int64(footprint.channels)),
            "crossings": .int(Int64(footprint.crossings)),
        ]
    }

    static func describe(_ counters: Router.Counters) -> JSONValue {
        [
            "admitted": .int(Int64(counters.admitted)),
            "deduplicated": .int(Int64(counters.deduplicated)),
            "refused": .int(Int64(counters.refused)),
            "relayed": .int(Int64(counters.relayed)),
            "suppressed": .int(Int64(counters.suppressed)),
            "handedOn": .int(Int64(counters.handedOn)),
        ]
    }
}
