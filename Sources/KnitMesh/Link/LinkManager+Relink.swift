import KnitWire

/// The relink window's wiring (``RelinkWindow``): where the radio's close opens it, and where a dialer below us passes
/// through it. A proven registration closes it (``register(_:_:proven:now:)``), and a radio that goes off forgets it.
extension LinkManager {
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
        case .connecting, .awaitingHello:
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
