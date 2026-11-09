import KnitWire

/// The relink window's wiring (``RelinkWindow``): where the radio's close opens it, where a dialer below us passes
/// through it, and where a peer ours to dial skips its dwell. A proven registration closes it
/// (``register(_:_:proven:now:)``), and a radio that goes off forgets it.
extension LinkManager {
    /// `snapshot`, a peer promotion may pick because ours is the dial (the order, seeking or the impostor's target), as
    /// promotion should see it: with its dwell met while the radio lately closed our proven link to its id and the peer has
    /// been heard since that close, so the first sighting after the close dials it. Any other snapshot is returned as it is.
    ///
    /// Heard since the close, because until the read of an iPhone's new address succeeds, its sighting and its address are
    /// still the old one's: a sighting from before the close, still inside the silence limit at the backoff's wake, would
    /// dial that dead address, time out, forget its payload by rule 1, double the backoff, and leave the new address's
    /// sighting busy behind it (the round 2 review). Such a sighting keeps the dwell it has, as before the window.
    ///
    /// The 2026-11-11 trial (`.agents/context/linux-peer.md`, "Its trial did not reach the window"): after iOS ended the
    /// link at an address change, the iPhone never redialed, and knit-peer above it relinked by its own dial 18 to 59 s
    /// after the drop, each successful read of the new address then waiting out the 12 s dwell that the presence
    /// tracker's 8 s gap reset had restarted. The peer was in range all along; the dwell filters passers-by, and a peer
    /// proven on a link the stack just ended is none.
    ///
    /// The backoff the close booked (``retire(_:backingOff:now:)``, 8 to 12 s) still holds, with its own deadline, so a
    /// flapping link does not redial at once. The silence limit and the RSSI floor still hold too. An unresolved tag names
    /// no id and is left alone, and a head-start peer never comes here: the order says it dials us, and an Android above us
    /// refuses an iPhone dialer it sighted within 12 s. The window's end only makes a candidate less promotable, so it needs
    /// no deadline of its own. The presence tracker is untouched, so nothing outside promotion sees the dwell move.
    func withRelinkDwell(_ snapshot: PresenceTracker.Snapshot, now: Int64) -> PresenceTracker.Snapshot {
        guard let id = snapshot.key.nodeId, let closed = relinkWindow.closed(id, now: now),
            snapshot.lastSeenAgoMilliseconds < now - closed
        else {
            return snapshot
        }
        var relinking = snapshot
        relinking.dwellMilliseconds = max(snapshot.dwellMilliseconds, promotionConfiguration.dwellMilliseconds)
        return relinking
    }

    /// The radio says channel `id` closed, before it is retired: a peer that hung up where its PROOF belonged failed its
    /// proof, and a proven link still registered opens its peer's window. A teardown of ours retired its channel before the
    /// radio's close came, so an eviction, a refusal, a write stall, a bad record or a replacement opens nothing.
    func radioClosed(_ id: ChannelID, now: Int64) {
        guard let channel = channels[id] else {
            return
        }
        switch channel.stage {
        case .awaitingProof(let pending):
            proofFailed(on: id, for: pending.peer, why: "eof")
        case .live(let peer):
            relinkWindow.radioClosed(peer, proven: liveLinks.contains { $0.channel == id && $0.proven }, now: now)
        case .connecting, .awaitingKeyShare, .awaitingHello:
            break
        }
    }

    /// Whether `dialer`, proving itself on `id` where our order says we dial it, relinks through its window: the radio
    /// closed our proven link to it lately, and no attempt of ours to link it is open. Any such attempt keeps "we dial it":
    /// admitting a crossing dial beside it would leave both ends holding a link the other's keep-older retires, and both
    /// links gone (ADR 2026-11.sv5t). The proof makes it the same node, since nothing registers before it verifies; the
    /// window closes only once a link to it registers proven. Logs the admission, a line of its own.
    func relinksOutOfOrder(_ dialer: NodeId, on id: ChannelID, now: Int64) -> Bool {
        relinkWindow.prune(now: now)
        guard relinkWindow.admits(dialer, now: now), !attemptsLink(to: dialer, besides: id) else {
            return false
        }
        log.log(.info, "link \(dialer) relinks out of order on \(id)")
        return true
    }

    /// Whether a channel other than `id` is an attempt to link `peer` not yet registered: a dial of ours of any kind (clear,
    /// tag, head start or seeking) whose target or attribution names `peer`, or whose tag resolves to it now, or any channel,
    /// ours or the peer's, whose PROOF of `peer` is awaited.
    func attemptsLink(to peer: NodeId, besides id: ChannelID) -> Bool {
        channels.contains { entry in
            let channel = entry.value
            guard entry.key != id, !channel.isLive else {
                return false
            }
            if Self.awaitsProof(of: peer, channel) {
                return true
            }
            guard case .dialer(let target) = channel.role else {
                return false
            }
            if target.expected == peer || target.record.peerKey == .node(peer) {
                return true
            }
            return target.form.blinded && aliases.standing(target.form.advertised)?.nodeId == peer
        }
    }
}
