public import KnitWire

extension Mesh {
    /// Blocks `peer` (``MeshEngine/block(_:)``, ADR 2026-10.5wgg): nothing they send is shown, and their face turns to
    /// their initial, while the mesh carries and relays their frames as before. Settles at once, so the screens hear of
    /// the cleared face.
    public func block(_ peer: NodeId) {
        engine.block(peer)
        // The peer's scopes, and their mining, go in this turn whatever the stores answer (ADR 2026-11.adrq, P4a).
        spool.block(peer, engine: engine)
        settle()
    }

    /// Unblocks `peer` (``MeshEngine/unblock(_:)``): the profile held for them shows again, and the photo it names is
    /// asked for when its bytes are gone.
    public func unblock(_ peer: NodeId) {
        engine.unblock(peer)
        spool.markTableDirty()
        settle()
    }
}
