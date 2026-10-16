import KnitMesh
import KnitStore
import KnitWire

extension MeshControl {
    /// Android's `RATCHET` reply (`DebugBridgeReceiver.handleRatchet`, `DebugBridgeReceiver.kt:1450-1502`): a forced reset
    /// first when one is asked for, sealed and flooded as Android's bridge sends one (`MeshManager.forceRatchetReset`), then
    /// every pinned peer's state, after the reset so the dump shows what it did, and the prekey our profile names, which
    /// the peer's dump shows as its `peerPrekeyId`. `seals` adds how our DMs were sealed, and `receipts` how our receipts
    /// and ticks were and how many room ticks rode, under the names of Android's metrics (`MeshMetrics.Seals` and
    /// `MeshMetrics.Receipts`), which its bridge reports apart.
    func ratchet(resetting peer: NodeId?) async -> [String: JSONValue] {
        var reply: [String: JSONValue] = [:]
        if let peer {
            reply["forcedReset"] = .string(peer.string)
            switch await mesh.sendRatchetReset(to: peer) {
            case .sent(_, let reRooted):
                reply["declined"] = .null
                reply["reRooted"] = .bool(reRooted)
            case .declined(let reason):
                reply["declined"] = .string(reason)
            }
        }
        reply["prekeyId"] = stores.ownProfile.load().prekeyId.map { .int(Int64($0)) } ?? .null
        reply["peers"] = .array(await mesh.ratchetPeers().map { .object(ControlLines.fields(of: $0)) })
        reply["seals"] = ControlLines.describe(await mesh.seals)
        reply["receipts"] = ControlLines.describe(await mesh.receipts)
        return reply
    }
}
