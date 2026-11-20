public import KnitWire

/// When each linked neighbour gets our periodic custody digest again (the `custody-carry-policy` contract, §7, revision 2).
/// Pure, on the engine's monotonic clock; the engine's 60 s re-offer tick asks it, and only the digest is held back: owed
/// ticks, group seeds, key asks and the blob steps on the same tick keep their own rules.
///
/// An offer drew something when custody kept a frame that arrived from the neighbour after our digest to it. A neighbour
/// that never draws is offered at gaps of 60, 120, 240, 480, then 600 s; a kept frame returns its interval to 60 s at once,
/// so traffic that resumes after a quiet spell brings the next offer within a tick or two. A neighbour linking anew starts
/// at 60 s, and its link-up digest, never held, counts as an offer. Every neighbour backs off, proven or not.
public struct ReofferBackoff: Sendable {
    /// The first interval, and the one a kept frame returns to (`REOFFER_MS`): the engine's re-offer tick.
    public static let baseMilliseconds: Int64 = 60_000
    /// The longest interval (`REOFFER_MAX_MS`).
    public static let maxMilliseconds: Int64 = 600_000
    /// How early a tick may land and still offer (`REOFFER_MS / 2`): a tick a few milliseconds early would otherwise hold
    /// a neighbour a whole extra tick.
    public static let toleranceMilliseconds: Int64 = baseMilliseconds / halves
    /// How an interval grows when an offer drew nothing, and how much of the base the tolerance is the inverse of.
    private static let halves: Int64 = 2

    /// One neighbour's pace.
    public struct Pace: Sendable, Equatable {
        /// When our last digest went to it.
        public var lastOffer: Int64
        /// The wait before the next offer.
        public var interval: Int64
        /// Whether custody kept a frame from it since that digest.
        public var drew: Bool
    }

    private var paces: [NodeId: Pace] = [:]

    /// No neighbour paced.
    public init() {
        // Nothing linked.
    }

    /// `peer`'s pace, if it is linked.
    public func pace(of peer: NodeId) -> Pace? {
        paces[peer]
    }

    /// A link to `peer` came up and its link-up digest went at `now`: it starts at the base interval.
    public mutating func linkedUp(_ peer: NodeId, now: Int64) {
        paces[peer] = Pace(lastOffer: now, interval: Self.baseMilliseconds, drew: false)
    }

    /// `peer`'s link went.
    public mutating func linkDown(_ peer: NodeId) {
        paces[peer] = nil
    }

    /// Custody kept a frame that arrived from `peer`: its interval returns to the base at once.
    public mutating func kept(from peer: NodeId) {
        guard var pace = paces[peer] else {
            return
        }
        pace.drew = true
        pace.interval = Self.baseMilliseconds
        paces[peer] = pace
    }

    /// Whether `peer`'s digest is due on the tick at `now`. A neighbour with no pace, linked before the engine knew of it, is.
    public func isDue(_ peer: NodeId, now: Int64) -> Bool {
        paces[peer].map { Self.isDue(since: $0.lastOffer, interval: $0.interval, now: now) } ?? true
    }

    /// The contract's test, in one place: due when `now − lastOffer ≥ interval − REOFFER_MS / 2`.
    public static func isDue(since lastOffer: Int64, interval: Int64, now: Int64) -> Bool {
        now - lastOffer >= interval - toleranceMilliseconds
    }

    /// Our digest went to `peer` on the tick at `now`: the offer before it is judged, the interval doubling up to the most
    /// when it drew nothing and returning to the base when it did.
    public mutating func offered(_ peer: NodeId, now: Int64) {
        let interval = paces[peer].map { $0.drew ? Self.baseMilliseconds : min(Self.halves * $0.interval, Self.maxMilliseconds) }
        paces[peer] = Pace(lastOffer: now, interval: interval ?? Self.baseMilliseconds, drew: false)
    }
}
