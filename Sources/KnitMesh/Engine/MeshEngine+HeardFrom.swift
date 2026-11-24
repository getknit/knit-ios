import KnitStore
import KnitWire

/// The engine's side of ``HeardFrom``: which verified frames are noted, and the bank (knit-next ADR 2026-10.k8ge).
extension MeshEngine {
    /// Notes that `sender` was heard, if `wire` is evidence of it (`MeshManager.noteVerified`, `MeshManager.kt:941-954` at
    /// `2e91518e3`). Called right after a frame verified, by the radio's ``deliver(_:from:)`` and the spool's door alone,
    /// with `sender` the id that verification checked against the key: never the raw `senderId`. Memory only, no write.
    ///
    /// Our own frames come back, over the radio and from the spool, verified against our own key, and are not a peer heard.
    /// A sender with no row is not noted either: a profile verifies against its own in-band key before anything pins it, so
    /// a flood of fresh identities would otherwise fill the buffer and push an honest namesake's stamp out. The profile that
    /// pins a sender stamps its new row itself (``profileRecord``). Every other signed frame verified against the pinned
    /// row, so only a profile reads the row here.
    func noteHeard(_ wire: WireEnvelope, _ envelope: RelayEnvelope, sender: NodeId) {
        guard HeardFrom.isEvidence(wire, envelope), sender != nodeId else {
            return
        }
        guard envelope.type != .profile || stores.peers.peer(sender) != nil else {
            return
        }
        heardFrom.note(sender, at: HeardFrom.heardAt(envelope, now: clock.wallMilliseconds()))
    }

    /// Banks the stamps noted since the last bank (`PeerRepository.flushSeen`): on the engine's 60 s timer, as Android's
    /// metrics tick runs it, and at ``Mesh/stop()``. One write for the whole bank, outside any store unit, and one
    /// ``MeshEvent/peersHeard(_:)`` naming the rows it moved, when it moved any. A failed write keeps every stamp for the
    /// next bank. The log line counts and names nobody: a dated trail of when strangers were about would sit in the
    /// unified log (knit-ios #56).
    func bankHeard() {
        let due = heardFrom.takeDue { stores.peers.lastSeenStamps() }
        guard !due.isEmpty else {
            return
        }
        guard let changed = stores.peers.markSeen(due, gate: HeardFrom.gateMilliseconds) else {
            heardFrom.settle(due, written: false)
            log.log(.debug, "mesh could not bank \(due.count) last-heard stamps; kept for the next bank")
            return
        }
        heardFrom.settle(due, written: true)
        log.log(.debug, "mesh banked \(changed.count) of \(due.count) last-heard stamps")
        if !changed.isEmpty {
            events.append(.peersHeard(changed))
        }
    }

    /// What the engine settles as the mesh stops (``Mesh/stop()``): the typing cues lapse, and the last-heard stamps bank, as
    /// Android flushes them at stop (`MeshManager.kt:2127`) rather than lose up to a minute of them to the timer that will
    /// not fire.
    func meshStopping() {
        forgetTyping()
        bankHeard()
    }

    /// Banks the stamps when the bank's timer is due, and sets it again.
    func bankHeardIfDue(now: Int64, timers due: inout Timers) {
        guard now >= due.seenBank else {
            return
        }
        bankHeard()
        due.seenBank = now + configuration.seenBankMilliseconds
    }
}
