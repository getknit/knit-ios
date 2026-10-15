import KnitCrypto
import KnitStore
public import KnitWire

/// What the control surface's forced reset came to (``MeshEngine/sealRatchetReset(to:)``).
public enum RatchetResetAttempt: Sendable, Equatable {
    /// The reset was sealed and persisted with the chain it spent, `reRooted` under a fresh root or else marked under
    /// the session held. P4c only seals it: nothing is sent until P5 wires the ratchet into the mesh.
    case sealed(EncEnvelope, reRooted: Bool)
    /// Nothing was sealed, for this reason, in the words of Android's debug bridge where it has them.
    case declined(String)
}

extension MeshEngine {
    /// Every pinned peer's ratchet state, in node id order (`MeshManager.ratchetState`, `MeshManager.kt:906-927`): the
    /// control surface's `ratchet` reply.
    func ratchetPeers() -> [RatchetPeerState] {
        stores.peers.allPeers().sorted { $0.nodeId < $1.nodeId }.map { peer in
            RatchetPeerState(peer: peer, session: ratchet.session(of: peer.nodeId), localEpochs: ratchet.localEpochs(of: peer.nodeId))
        }
    }

    /// Seals a session reset toward `peer` with no heuristic in front of it, the escape hatch for a pair that wedged
    /// before a fix shipped (`MeshManager.forceRatchetReset` and `InboundPipeline.sendSessionReset`,
    /// `InboundPipeline.kt:1902-1961`). The gates are the peer material an X3DH initiation needs, each refusing in
    /// Android's words; past them ``RatchetSessions/sealResetDm(to:prekey:plaintext:aad:now:cause:)`` may still decline,
    /// or mark the init it holds, since it never seals a reset the peer would refuse.
    ///
    /// With the ratchet's switch off nothing is sealed: the switch keeps the ratchet from every peer, so no session starts
    /// that would outlive the flip (ADR 2026-10.5sk9). In P4c a sealed reset is persisted and answered, never sent: P5
    /// floods it as a chat frame under the id and stamp it was sealed with.
    func sealRatchetReset(to peer: NodeId) -> RatchetResetAttempt {
        guard configuration.ratchet else {
            return .declined("the ratchet is off")
        }
        guard let record = stores.peers.peer(peer) else {
            return .declined("no peer row")
        }
        guard Capabilities(rawValue: record.capabilities ?? 0).contains(.ratchet) else {
            return .declined("peer is not ratchet-capable")
        }
        guard let bundle = PublicKeyBundle(encoded: record.publicKey) else {
            return .declined("no pinned pubKey")
        }
        guard let pinned = record.prekey else {
            return .declined("no pinned prekey id")
        }
        guard let prekey = PeerPrekey(verifying: pinned, signedBy: bundle) else {
            return .declined("no pinned prekey pub")
        }
        let id = newFrameId()
        let sentAt = clock.wallMilliseconds()
        let aad = MessageCrypto.header(id: id, senderId: nodeId.string, sentAt: sentAt, thread: peer.string)
        let sealing = ratchet.sealResetDm(to: bundle, prekey: prekey, plaintext: RatchetSessions.resetPlaintext, aad: aad, now: sentAt)
        switch sealing {
        case .settled(.sealed(let envelope, let plan)):
            let reRooted = plan.action == .reRoot
            log.log(
                .info, "ratchet reset to \(peer) sealed \(reRooted ? "under a fresh root" : "under the session held") as \(id), not sent")
            return .sealed(envelope, reRooted: reRooted)
        case .settled(.declined(let reason, _)):
            return .declined(reason)
        case .failed:
            return .declined("the store failed")
        default:
            // No prekey X25519 takes; a joined answer needs a unit the caller opened, and this opens none.
            return .declined("sealResetDm refused (unusable prekey)")
        }
    }
}
