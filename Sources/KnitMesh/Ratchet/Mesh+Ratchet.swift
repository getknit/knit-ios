public import KnitWire

extension Mesh {
    /// Every pinned peer's DM ratchet state, for the control surface's `ratchet` (ADR 2026-10.5sk9).
    public func ratchetPeers() -> [RatchetPeerState] {
        engine.ratchetPeers()
    }

    /// Seals a DM ratchet reset toward `peer` past the heuristic and floods it, for the control surface's `ratchet` with
    /// `reset`, as Android's debug bridge does (``MeshEngine/sendSessionReset(to:now:cause:)``). The reset is carried as
    /// our own, so it settles the mesh as every other send does, and the advert's digest cue moves with it.
    public func sendRatchetReset(to peer: NodeId) -> RatchetResetAttempt {
        defer { settle() }
        return engine.sendRatchetReset(to: peer)
    }
}

extension MeshEngine {
    /// The control surface's forced reset: asked for directly, so nothing is known about the peer's state, at our clock's
    /// now (`forceRatchetReset`, `MeshManager.kt:929`).
    func sendRatchetReset(to peer: NodeId) -> RatchetResetAttempt {
        sendSessionReset(to: peer, now: clock.wallMilliseconds(), cause: .onDemand)
    }
}
