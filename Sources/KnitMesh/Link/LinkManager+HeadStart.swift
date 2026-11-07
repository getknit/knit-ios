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

    /// Whether a peer advertising `form` and `flags` is one this node waits on for a head start before dialing it: the
    /// order has it dial us, and its advert says it reads GATT payloads (ADR 2026-10.6eyf, amended by ADR 2026-11.sv5t).
    /// For a clear peer that is today's "its id sorts above ours"; a flagged blinded peer always takes one, since a clear
    /// phone never dials a tag by the order.
    func takesHeadStart(_ form: AdvertOrder.Form, flags: UInt8) -> Bool {
        !AdvertOrder.iDial(mine.current, form) && flags & AdvertPayload.dialsGattPeersFlag != 0
    }

    /// Whether `snapshot` is a peer promotion considers only for its head start: one the order says waits, at a moment
    /// when this node gives head starts and is not seeking, where every peer is dialed whatever the order.
    func isHeadStartCandidate(_ snapshot: PresenceTracker.Snapshot) -> Bool {
        givesHeadStart && !dialsWhateverTheOrder && takesHeadStart(.of(snapshot.advert), flags: snapshot.advert.flags)
    }

    /// Whether a head-start dial is open: read from the kind each dial recorded when it began, never inferred from the
    /// order (Android's `DialPlan.DialKind`), so a tag dial's end leaves no head start stuck open.
    var headStartDialInFlight: Bool {
        dialTargets.contains { $0.record.kind == .headStart }
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
        backoff: Set<SightingKey>,
        configuration promotion: PromotionPolicy.Configuration
    ) -> [PresenceTracker.Snapshot] {
        let ready = candidates.filter { candidate in
            isHeadStartCandidate(candidate) && PromotionPolicy.isPromotable(candidate, backoff: backoff, configuration: promotion)
        }
        // `max` keeps the first of equals, as the policy's stable sort does.
        let strongest = ready.max { lhs, rhs in lhs.smoothedRssi < rhs.smoothedRssi }?.key
        return candidates.filter { !isHeadStartCandidate($0) || $0.key == strongest }
    }

    /// Logs a head-start dial, before the dial's own line, with the peer's whole dwell and its smoothed RSSI.
    /// `candidate` is the peer as promotion saw it (``withHeadStart(_:)``). A clear peer's line names its id, byte for byte
    /// the harness's `HEAD_START_LINE`; a tag's names its handle.
    func logHeadStartDial(_ candidate: PresenceTracker.Snapshot) {
        let dwell = candidate.dwellMilliseconds + configuration.headStartMilliseconds
        let rssi = Int(candidate.smoothedRssi.rounded())
        log.log(.info, "link head start over for \(candidate.key) (dwell=\(dwell)ms rssi=\(rssi)dBm)")
    }
}
