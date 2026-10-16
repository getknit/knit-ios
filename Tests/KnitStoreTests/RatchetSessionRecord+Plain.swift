import KnitStore
import KnitWire

extension RatchetSessionRecord {
    /// A confirmed session with `peer` on a root of 32 bytes of `root`, every other field at its plainest: what the store
    /// unit's tests write to the DM ratchet's store (``StoreTransactorTests``).
    static func plain(with peer: NodeId, root: UInt8) -> Self {
        Self(peerId: peer, confirmed: true, weAreInitiator: true, root: [UInt8](repeating: root, count: 32), establishedAt: 1)
    }
}

extension GroupRecvChainRecord {
    /// A receive chain for epoch 1 minted at `mintedAt`: what the store unit's tests write to the group form's store
    /// (``StoreTransactorTests``).
    static func plain(mintedAt: Int64) -> Self {
        Self(epoch: 1, mintedAt: mintedAt, chainKey: [UInt8](repeating: 9, count: 32), next: 0, lastUsedAt: mintedAt)
    }
}
