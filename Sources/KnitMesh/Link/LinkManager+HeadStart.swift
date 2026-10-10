import KnitWire

/// The head start: a node at the front that iOS may suspend dials a flagged peer above it once that peer has had
/// ``Configuration/headStartMilliseconds`` to dial first (interop-audit finding AND-2).
///
/// Every Android build since knit-next `713b29d6` advertises `FLAG_DIALS_GATT_PEERS`, so the order says an iPhone whose
/// id sorts below it waits to be dialed. But an open Android holding one link scans every 60 s or more, and a
/// screen-off one every 240 to 840 s, so the iPhone waited minutes for a link MVP item 2 wants within 30 s. The iPhone
/// now gives the peer the ordinary 12 s dwell plus a 12 s head start, then dials it itself, one such dial at a time,
/// strongest first. Android admits a dialer it has not sighted whatever the order (`BleAdmissionPolicy.kt:52`, knit-next
/// ADR 2026-09.shzv), which is exactly the peer that has not dialed us yet. One that has sighted us refuses the dial
/// (`:51`) and dials us itself; the refusal is an ordinary failed dial, with the ordinary backoff. This is Android's own
/// lonely dial turned the other way (knit-next ADR 2026-09.hj4a): admission keeps the order (``weDial(_:flags:)``), and
/// only promotion moves, as seeking's ``dialsWhateverTheOrder`` does.
///
/// The rule reads ``Radio/servesDoorbell``, the flag the HELLO reads to add `CAP_DOORBELL`, and needs the front. A
/// head-start dial makes the iPhone the link's central at CoreBluetooth's 720 ms supervision timeout, and only Android's
/// doorbell lookup, which a HELLO without the bit never starts, asks for the 5 s one (knit-next ADR 2026-09.dqvb). So no
/// head-start dial goes out on a radio that serves no doorbell. In the background, seeking dials whatever the order
/// already (ADR 2026-10.mueg), and a linked iPhone there gives no head start.
extension LinkManager {
    /// Whether this node gives head starts now: at the front, on a radio that serves the doorbell.
    var givesHeadStart: Bool {
        radio.servesDoorbell && !inBackground
    }

    /// Whether `peer`, advertising `flags`, is one this node waits on for a head start before dialing it: its id sorts
    /// above ours, as an ASCII string, and its advert says it reads GATT payloads, so the order has it dial us.
    func takesHeadStart(_ peer: NodeId, flags: UInt8) -> Bool {
        localId < peer && flags & AdvertPayload.dialsGattPeersFlag != 0
    }

    /// Whether `snapshot` is a peer promotion considers only for its head start: one the order says waits, at a moment
    /// when this node gives head starts and is not seeking, where every peer is dialed whatever the order.
    func isHeadStartCandidate(_ snapshot: PresenceTracker.Snapshot) -> Bool {
        givesHeadStart && !dialsWhateverTheOrder && takesHeadStart(snapshot.nodeId, flags: snapshot.advert.flags)
    }

    /// Whether a head-start dial is open. Derived, not kept, as Android's `lonelyDialInFlight` is: at the front the
    /// order never dials a flagged peer above us, so a dial to one is the head start's.
    var headStartDialInFlight: Bool {
        dialing.keys.contains { peer in
            presence.advert(of: peer).map { takesHeadStart(peer, flags: $0.flags) } ?? false
        }
    }

    /// `snapshot` as promotion should see a head-start peer: its dwell counts the head start less, so the ordinary
    /// dwell, ``PromotionPolicy/untilDwellEnds(candidates:backoff:configuration:)``'s wake included, ends only when the
    /// head start has too.
    func withHeadStart(_ snapshot: PresenceTracker.Snapshot) -> PresenceTracker.Snapshot {
        var waiting = snapshot
        waiting.dwellMilliseconds -= configuration.headStartMilliseconds
        return waiting
    }

    /// `candidates` with at most one head-start peer: the strongest promotable one, or none while a head-start dial is
    /// open. `promote` can dial several peers in one tick, and a head-start dial is one at a time.
    func keepingOneHeadStart(
        _ candidates: [PresenceTracker.Snapshot],
        backoff: Set<NodeId>,
        configuration promotion: PromotionPolicy.Configuration
    ) -> [PresenceTracker.Snapshot] {
        let ready = candidates.filter { candidate in
            isHeadStartCandidate(candidate) && PromotionPolicy.isPromotable(candidate, backoff: backoff, configuration: promotion)
        }
        // `max` keeps the first of equals, as the policy's stable sort does.
        let strongest = ready.max { lhs, rhs in lhs.smoothedRssi < rhs.smoothedRssi }?.nodeId
        return candidates.filter { !isHeadStartCandidate($0) || $0.nodeId == strongest }
    }

    /// Logs a head-start dial, before the dial's own line, with the peer's whole dwell and its smoothed RSSI.
    /// `candidate` is the peer as promotion saw it (``withHeadStart(_:)``).
    func logHeadStartDial(_ candidate: PresenceTracker.Snapshot) {
        let dwell = candidate.dwellMilliseconds + configuration.headStartMilliseconds
        let rssi = Int(candidate.smoothedRssi.rounded())
        log.log(.info, "link head start over for \(candidate.nodeId) (dwell=\(dwell)ms rssi=\(rssi)dBm)")
    }
}
