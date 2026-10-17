public import KnitWire

extension Mesh {
    /// Every pinned peer's DM ratchet state, for the control surface's `ratchet` (ADR 2026-10.5sk9).
    public func ratchetPeers() -> [RatchetPeerState] {
        engine.ratchetPeers()
    }

    /// How our DMs were sealed so far, with the ratchet or v1 in its stead, and our reactions, with the ratchet or in the
    /// clear, under Android's metric names (phases P5b and P5e).
    public var seals: RatchetSealCounts { engine.seals }

    /// How our receipts and ticks were sealed so far, and how many room ticks rode, under Android's metric names (phase
    /// P5d).
    public var receipts: RatchetReceiptCounts { engine.receipts }

    /// How many inits our sealed profile answered so far, under Android's metric name (phase P5e).
    public var answers: RatchetAnswerCounts { engine.answers }

    /// How the group form went so far, seeds held, replayed and adopted, key requests sent, and our group frames sealed with
    /// it or v1 in its stead and the seeds they sent, under Android's metric names (phases P6a2 and P6b; read by the control
    /// surface since P7d).
    public var groupCounts: RatchetGroupCounts { engine.groupCounts }

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
