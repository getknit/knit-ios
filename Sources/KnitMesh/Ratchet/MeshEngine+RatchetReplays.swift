import KnitStore
import KnitWire

/// The DM ratchet's replays and sweeps, with the switch on (ADR 2026-10.5sk9, phase P5a): the copies whose open's unit
/// failed, opened again at the sweep; the start's replay out of our own custody; and the retention sweeps.
extension MeshEngine {
    /// Opens again every copy whose unit failed since the last sweep, oldest first, by the route it came: for a frame off
    /// a link, its first verdict. A copy another copy of its id already committed is gone (``RatchetReplay/forget(_:)``).
    /// The rest are decided by their row, read in a unit of its own: a row lets the copy go, so a DM delivered another
    /// way, or deleted since, is not acknowledged again; a read the store fails fails the unit and keeps the copy; with no
    /// row, the copy opens again. Each goes through ``handleChat(_:route:)`` as it came, so the router's
    /// dedup, which marked its id when it arrived, is no part of it.
    func replayFailedRatchetOpens() {
        let kept = ratchetReplay.take()
        guard configuration.ratchet, !kept.isEmpty else {
            return
        }
        for copy in kept {
            // The body answers the copy to open again, or none once its row exists, never `nil`, which would abandon the unit.
            let unread = stores.transactor.atomically { () -> RatchetReplay.Kept?? in
                .some(stores.messages.contains(copy.envelope.id) ? nil : copy)
            }
            switch unread {
            case .committed(let copy?):
                handleChat(copy.envelope, route: copy.route)
            case .committed(nil):
                continue
            case .joined, .abandoned, .failed:
                log.log(.warning, "mesh ratchet frame \(copy.envelope.id) kept for the next replay: a store failed")
                ratchetReplay.keep(copy.envelope, route: copy.route)
            }
        }
    }

    /// Opens again, at start, every ratchet DM to us that our own custody holds with no row, oldest first: a failed unit's
    /// copy died with the process that kept it, and custody holds the first bytes stored under its id. It only delivers
    /// (``RatchetInbound/Origin/startReplay``): it holds the era, and applies no reaction and no profile. Most of what it
    /// finds is machinery already opened: a ctl frame from the era we hold drops as `DUPLICATE`, and one from an era the
    /// pair has since left can open again under the root that era left draining, since leaving it purged the receive
    /// state that spent it; a receipt then flips nothing new, and a reset's marker applies nothing. The rest are frames a
    /// failed unit or a closed switch left unread.
    func replayCustodiedRatchetMessages() {
        guard configuration.ratchet else {
            return
        }
        let me = ExactKey(nodeId.string)
        for carried in stores.custody.liveFrames(now: clock.wallMilliseconds()).reversed() {
            let envelope = carried.envelope
            guard envelope.isDirect, envelope.recipientId.map(ExactKey.init) == me, !stores.messages.contains(envelope.id),
                let enc = (try? ChatContent(decoding: envelope.payload))?.enc, RatchetInbound.isDirectRatchet(enc)
            else {
                continue
            }
            // Custody verified it, and the chat door reads the block list and the rest again. Custody kept no hop, so a
            // photo it carries is asked of its author first.
            handleChat(envelope, route: RatchetInbound.Route(carried: carried, origin: .startReplay))
        }
    }

    /// The ratchet's retention sweeps, the DM ratchet's and then the group form's, at start and then hourly, with the switch
    /// on, as Android's `sweepKeyRetention` runs both (`MeshManager.kt:988-993`): each in a unit of its own, never inside a
    /// DM's, since on the database each truncates the write-ahead log once it commits, and no send may wait behind that.
    func sweepRatchet() {
        guard configuration.ratchet else {
            return
        }
        let now = clock.wallMilliseconds()
        if !ratchet.sweep(now: now) {
            log.log(.warning, "mesh ratchet sweep failed: a store failed")
        }
        if !groupRatchet.sweep(now: now) {
            log.log(.warning, "mesh group ratchet sweep failed: a store failed")
        }
    }
}
