import KnitCrypto
import KnitStore
public import KnitWire

/// What a session reset came to (``MeshEngine/sendSessionReset(to:now:cause:)``).
public enum RatchetResetAttempt: Sendable, Equatable {
    /// The reset was sealed, persisted with the chain it spent, and then flooded: `reRooted` under a fresh root, or else
    /// marked under the session held.
    case sent(EncEnvelope, reRooted: Bool)
    /// Nothing was sealed or sent, for this reason, in the words of Android's debug bridge where it has them.
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

    /// Seals a session reset toward `peer` and floods it (`sendSessionReset`, `InboundPipeline.kt:1914-1961`): what the
    /// reset heuristic sends when a peer's frames will not open (``handleRatchetDirect(_:_:sender:route:)``), and the
    /// control surface's forced reset, the escape hatch for a pair that wedged before a fix shipped
    /// (`MeshManager.forceRatchetReset`, `MeshManager.kt:929`). The gates are the peer material an X3DH initiation needs,
    /// each refusing in Android's words; past them ``RatchetSessions/sealResetDm(to:prekey:plaintext:aad:now:cause:)``
    /// may still decline, or mark the init it holds, since it never seals a reset the peer would refuse (knit-next ADR
    /// 2026-09.qerd). A decline sends nothing.
    ///
    /// The reset goes as Kotlin's `originate` sends it: a chat to `peer` under a fresh id, its `sentAt` the `now` its AAD
    /// names, signed once, carried in our own custody under the same quotas as everyone's, and flooded, with no message
    /// row (``originate(_:)``). It goes only once the facade's unit has committed, so the chain it spent stands before the
    /// frame is on the air. With the switch off nothing is sealed, so no session starts that would outlive the flip (ADR
    /// 2026-10.5sk9).
    @discardableResult
    func sendSessionReset(to peer: NodeId, now: Int64, cause: RatchetResetPolicy.Cause) -> RatchetResetAttempt {
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
        let aad = MessageCrypto.header(id: id, senderId: nodeId.string, sentAt: now, thread: peer.string)
        let sealing = ratchet.sealResetDm(
            to: bundle, prekey: prekey, plaintext: RatchetSessions.resetPlaintext, aad: aad, now: now, cause: cause)
        switch sealing {
        case .settled(.sealed(let envelope, let plan)):
            let reRooted = plan.action == .reRoot
            originate(chatEnvelope(id: id, sentAt: now, recipient: peer, group: nil, content: ChatContent(enc: envelope)))
            log.log(.info, "ratchet reset to \(peer) sent \(reRooted ? "under a fresh root" : "under the session held") as \(id)")
            return .sent(envelope, reRooted: reRooted)
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
