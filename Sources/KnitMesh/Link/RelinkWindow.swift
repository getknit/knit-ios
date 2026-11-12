import KnitWire

/// Who may redial us out of order for a while after the radio ended our proven link to it: the relink window.
///
/// iOS ends an LE connection when the same device connects to it again, same address and CoreBluetooth UUID (`LE Link
/// disconnected … reason 708`; `.agents/context/linux-peer.md`, "The iPhone ends a link when the same device connects to it
/// again"). A reader's GATT read of an iPhone's new address is that second connection whenever the reader's address is the
/// one its link was made from: always for KnitBlueZ's dongle, sometimes for an Android or iPhone reader. The iPhone then
/// redials after its backoff (10 s after the link ended, in the one case logged), and a responder whose order says it
/// dials the iPhone refused that dial ("we dial it"), then failed its own dials for minutes (the 2026-11-11 clear-mode
/// control, 20:04). So for ``lengthMilliseconds`` after the radio closed a proven link, a dialer proving the same id is admitted
/// out of order once, as long as no dial of ours to it is open (``LinkManager/admissionRefusal(_:proves:sighting:held:on:now:)``).
///
/// Opened only by the radio's close of a proven link: the stack or the far side ended it. Never by a teardown this node
/// chose (an eviction, a refusal, a write stall, a bad record, a replacement, `register`'s keep-older), which retire the
/// channel before the radio's close arrives: opened there, a peer evicted at the link budget would redial, be admitted,
/// outlive the hold and be evicted again. Keyed by node id alone, since the address rotates and the channel is gone.
/// Consumed only when a link to that id registers proven, never at admission, so a bogus proof leaves it open for the real
/// peer. Nothing is dialed on it, so it needs no deadline: it is pruned when a dialer is judged or a window opens.
///
/// Pure, free of a clock: the caller passes the monotonic time.
internal struct RelinkWindow {
    /// How long after the radio's close the window stays open.
    let lengthMilliseconds: Int64
    /// When the radio closed each proven link whose id has not relinked proven since.
    private var closedAt: [NodeId: Int64] = [:]

    /// A window that stays open `lengthMilliseconds` after each close.
    init(lengthMilliseconds: Int64) {
        self.lengthMilliseconds = lengthMilliseconds
    }

    /// The radio closed a live link to `peer` at `now`: the window opens for `peer` when that link was `proven`, and only
    /// then, so an unproven claimant never earns one.
    mutating func radioClosed(_ peer: NodeId, proven: Bool, now: Int64) {
        prune(now: now)
        guard proven else {
            return
        }
        closedAt[peer] = now
    }

    /// Whether `peer`'s window is open at `now`.
    func admits(_ peer: NodeId, now: Int64) -> Bool {
        closedAt[peer].map { now - $0 < lengthMilliseconds } ?? false
    }

    /// A link to `peer` registered proven: its window closes, whichever side dialed.
    mutating func relinked(_ peer: NodeId) {
        closedAt[peer] = nil
    }

    /// The session ended, with every link: nothing it closed is a relink any more.
    mutating func clear() {
        closedAt.removeAll()
    }

    /// Forgets the windows expired at `now`, so the book holds only open ones: at each admission and each opening.
    mutating func prune(now: Int64) {
        closedAt = closedAt.filter { now - $0.value < lengthMilliseconds }
    }
}
