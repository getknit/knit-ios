import KnitMesh
import KnitWire

extension ControlLines {
    /// One peer's DM ratchet state under the keys of Android's debug bridge `RATCHET` (`DebugBridgeReceiver.kt:1468-1499`),
    /// so one script reads both phones: our epochs as `"epoch@createdAt"`, the most recently minted first, and the root
    /// only as its hash.
    static func fields(of state: RatchetPeerState) -> [String: JSONValue] {
        [
            "peer": .string(state.peer.string),
            "name": .string(state.name),
            "capRatchet": .bool(state.capRatchet),
            "peerPrekeyId": state.peerPrekeyId.map { .int(Int64($0)) } ?? .null,
            "peerPrekeyPinned": .bool(state.peerPrekeyPinned),
            "hasSession": .bool(state.hasSession),
            "confirmed": .bool(state.confirmed),
            "sendEpoch": .int(Int64(state.sendEpoch)),
            "lastResetSentAt": .int(state.lastResetSentAt),
            "establishedAt": .int(state.establishedAt),
            "weAreInitiator": .bool(state.weAreInitiator),
            "highestPeAcked": .int(Int64(state.highestPeAcked)),
            "rootHash": .text(state.rootHash),
            "prevRootExpiresAt": .int(state.prevRootExpiresAt),
            "hasPeerInitAnchor": .bool(state.hasPeerInitAnchor),
            "localEpochs": .array(state.localEpochs.map { .string("\($0.epoch)@\($0.createdAt)") }),
        ]
    }
}
