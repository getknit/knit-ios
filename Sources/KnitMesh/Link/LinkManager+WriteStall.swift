public import KnitWire

/// Closing a live link whose writes have stalled (ADR 2026-10.f5zs): a neighbour that stops reading would otherwise
/// hold whatever we queue for it until iOS ends Knit for its memory, since nothing else watches a live link's writes.
/// The decision is ``WriteStallWatch``'s; this is its wiring. The engine reads the same levels to hold a reply round.
extension LinkManager {
    // MARK: MeshTransport

    /// What waits unwritten on the live link to `peer`, read from the radio at its entry points (``Radio/outboxLevel(on:)``),
    /// on the channel ``send(_:to:)`` writes to. 0 when unlinked.
    public func queuedBytes(to peer: NodeId) -> Int {
        liveChannel(to: peer).map { radio.outboxLevel(on: $0).queuedBytes } ?? 0
    }

    /// Whether the frame with `key` crossed the live link to `peer`, either way, inside the window (``LinkCrossings``), on
    /// the channel ``send(_:to:)`` writes to. Records nothing. False when unlinked.
    public func hasCrossed(_ key: String, to peer: NodeId) -> Bool {
        liveChannel(to: peer).map { crossings.hasCrossed(link: $0, key: key, now: clock.monotonicMilliseconds()) } ?? false
    }

    // MARK: The stall close

    /// Runs the write-stall check if it is due, and retires every link it finds stalled.
    ///
    /// The retire backs off nobody. Android closes a stalled write as silent, and redials at once rather than through its
    /// backoff (`closeSilent`, `BluetoothMeshTransport.kt:2996-3011` at knit-next `e63f15f4`): the stall says the
    /// connection under the link is gone or its reader is stuck, not that the peer cannot be dialed. A backoff would buy
    /// little anyway, as a link coming up clears its peer's streak.
    func checkWriteStalls(now: Int64) -> [Event] {
        let check = stallWatch.check(now: now, level: { radio.outboxLevel(on: $0) }, exempt: isExemptFromStallClose)
        switch check {
        case .notDue:
            return []
        case .late(let milliseconds):
            log.log(.debug, "link write check ran \(milliseconds) ms late, so every link's stall count starts again")
            return []
        case .checked(let stalled):
            return stalled.flatMap { stall in
                log.log(.warning, "link \(stall.link) write stalled for \(stall.milliseconds) ms")
                return retire(stall.link, backingOff: false, now: now)
            }
        }
    }

    /// Whether the link on `id` is left alone by the stall close: its HELLO carries `CAP_DOORBELL` and its peer looks like
    /// an iPhone, which iOS suspends with its link up and reading nothing by design. Android exempts every `CAP_DOORBELL`
    /// link for that reason (`LinkSilence.kt:39`, set from the HELLO at `BluetoothMeshTransport.kt:2744`), and backs a
    /// dialer's claim of the bit with its own evidence at admission (`doorbellTrusted`, `BleAdmissionPolicy.kt:85-99`).
    ///
    /// This manager cannot tell how a sighting was heard, only what it carried, so it reads the evidence it has: a peer
    /// looks like an iPhone unless it was heard through service data while linked, or was when the link came up. Service
    /// data carries custody's digest cue, and a GATT payload is served with the cue zeroed (ADR 2026-09.xzpt), so a cue is
    /// what marks service data. So a peer sighted only through its GATT payload, and one never sighted (accepted
    /// unsighted, or backgrounded out of presence), is exempt. The reading errs one way: the cue folds custody's ids by
    /// XOR, so a phone with nothing in custody advertises 0 and reads as a GATT payload. That costs nothing honest, as
    /// only a link whose HELLO claims the bit is judged by it: Android never sends the bit (`DoorbellPolicy.kt:61-64`),
    /// nor does knit-peer's `android` profile, so every link to them gets the close whatever their cue. A fork claiming
    /// the bit under the id of an Android phone in range loses the exemption once that phone's advert is heard with a
    /// cue.
    func isExemptFromStallClose(_ id: ChannelID) -> Bool {
        guard let link = liveLinks.first(where: { $0.channel == id }) else {
            return false
        }
        return link.neighbor.capabilities.contains(.doorbell) && !link.heardServiceData
    }

    /// Whether `advert` came as service data rather than a GATT payload: it carries a digest cue (ADR 2026-09.xzpt), or it
    /// is blinded, which no GATT payload can be and whose writer zeroes the cue (ADR 2026-11.sv5t).
    static func isServiceData(_ advert: AdvertPayload) -> Bool {
        advert.digestCue != 0 || advert.blinded
    }
}
