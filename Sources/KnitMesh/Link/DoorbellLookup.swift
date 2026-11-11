/// How a ring client reads a doorbell lookup that found nothing (ADR 2026-11.prsp; ADR 2026-09.khjj): both radios' ring
/// clients, KnitBLE's on the CoreBluetooth queue and KnitBlueZ's on its loop, ask it.
///
/// A blinding iPhone serves its doorbell in a `0xFE30` service of its own, added first at each bring-up, and replaces the
/// payload's service beside it at every rotation. A lookup that runs while the peer's server is still coming up, or while
/// the client's view of it is being refreshed after a services change, can find no doorbell where one is a moment away. So
/// a lookup that finds none within ``doorbellSettleMilliseconds`` of the link's open, of a services change
/// (`didModifyServices`) or of BlueZ's `ServicesResolved` is a failure, which the next ring retries, never an absence.
/// Past the bound an absence stands, so a peer that serves no doorbell, an Android phone, is not looked up at every ring.
/// Companion change A11 has Android's `BleDoorbell.lookUp` keep the same bound.
public enum DoorbellLookup {
    /// How long after a link's open or a services change a missing doorbell may still be on its way, on the monotonic
    /// clock.
    public static let doorbellSettleMilliseconds: Int64 = 10_000

    /// What a lookup that found no doorbell leaves behind.
    public enum Missing: Sendable, Equatable {
        /// Nothing: the next ring looks again.
        case retry
        /// The peer serves no doorbell, and no ring on this connection looks again.
        case absent
    }

    /// A lookup ended at `now` without a doorbell, having `failed` (an error, not an answer) or not, with the peer's services
    /// settling since `settlingSince`: the latest of the link's open and the last services change, or `nil` when neither is
    /// known, which counts as settled.
    public static func missing(failed: Bool, settlingSince: Int64?, now: Int64) -> Missing {
        guard !failed else {
            return .retry
        }
        guard let settlingSince else {
            return .absent
        }
        return now - settlingSince < doorbellSettleMilliseconds ? .retry : .absent
    }
}
