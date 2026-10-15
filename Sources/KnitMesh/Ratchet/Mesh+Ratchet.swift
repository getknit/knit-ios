public import KnitWire

extension Mesh {
    /// Every pinned peer's DM ratchet state, for the control surface's `ratchet` (ADR 2026-10.5sk9).
    public func ratchetPeers() -> [RatchetPeerState] {
        engine.ratchetPeers()
    }

    /// Seals a DM ratchet reset toward `peer` past the heuristic, for the control surface's `ratchet` with `reset`. It is
    /// persisted and answered, and not sent before P5 (``MeshEngine/sealRatchetReset(to:)``).
    public func sealRatchetReset(to peer: NodeId) -> RatchetResetAttempt {
        engine.sealRatchetReset(to: peer)
    }
}
