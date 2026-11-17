import KnitCrypto
import KnitWire

/// What stamp searches may spend (ADR 2026-11.adrq, P4b2, this port's own rule): counters hashed over a rolling 24 h on the
/// monotonic clock, charged with each run's `tried`, for the engine and for each relay and each peer (``SpoolScope/peer``).
/// The engine holds at most 2^29 counters, one relay 2^28 and one peer 2^27, so one relay or one peer can spend at most half
/// or a quarter of what the engine allows, and a peer's charge outlives its scopes leaving the table.
///
/// Each record keeps one bucket per hour. A charge counts in its hour's bucket and the 24 after it, so it leaves no sooner
/// than 24 h after it was made: the record never drops charge early. Expired buckets go before each charge, which keeps at
/// most 25, since a charge never lands before the newest bucket. A record or a relay or peer whose window holds nothing is
/// dropped, so the maps hold only who spent in the window; every peer here was in the scope table when its run started.
/// All of it is in memory: P6 persists the buckets.
internal struct SpoolMinerBudget: Sendable, Equatable {
    /// The engine's counters in the window: eight full searches.
    static let engineCap: Int64 = 1 << 29
    /// One relay's: four full searches.
    static let relayCap: Int64 = 1 << 28
    /// One peer's: two full searches.
    static let peerCap: Int64 = 1 << 27
    /// A bucket's span.
    static let hourMilliseconds: Int64 = 3_600_000
    /// The hours a charge counts in: its own and the 24 after it.
    static let windowHours: Int64 = 25

    /// Which share a search did not fit, the first in this order.
    enum Share: Sendable, Equatable {
        case engine
        case relay
        case peer
    }

    /// One hour's charge.
    struct Bucket: Sendable, Equatable {
        let hour: Int64
        var spent: Int64
    }

    /// One share's buckets, oldest first.
    struct Record: Sendable, Equatable {
        private(set) var buckets: [Bucket] = []

        /// The counters spent in the window that holds `hour`.
        func spent(at hour: Int64) -> Int64 {
            buckets.filter { hour < $0.hour + SpoolMinerBudget.windowHours }.reduce(0) { $0 + $1.spent }
        }

        /// Charges `amount` to `hour`, or to the newest bucket when that is no older, after dropping what expired.
        mutating func charge(_ amount: Int64, at hour: Int64) {
            buckets.removeAll { hour >= $0.hour + SpoolMinerBudget.windowHours }
            if let last = buckets.indices.last, buckets[last].hour >= hour {
                buckets[last].spent += amount
            } else {
                buckets.append(Bucket(hour: hour, spent: amount))
            }
        }

        /// The hour at whose start this record, under `cap`, holds `need` more counters, or `nil` when it holds them now:
        /// the hour the oldest buckets that free enough leave the window.
        func freesAt(need: Int64, cap: Int64, hour: Int64) -> Int64? {
            let live = buckets.filter { hour < $0.hour + SpoolMinerBudget.windowHours }
            let deficit = live.reduce(0) { $0 + $1.spent } + need - cap
            guard deficit > 0 else {
                return nil
            }
            // `need` is at most a full search, which every cap holds, so the live buckets always free enough.
            var freed: Int64 = 0
            var at = hour
            for bucket in live where freed < deficit {
                freed += bucket.spent
                at = bucket.hour + SpoolMinerBudget.windowHours
            }
            return at
        }
    }

    private(set) var engine = Record()
    private(set) var relays: [SpoolRelayHandle: Record] = [:]
    private(set) var peers: [NodeId: Record] = [:]

    /// The hour a monotonic instant falls in. The monotonic clock counts up from 0.
    static func hour(_ monotonic: Int64) -> Int64 {
        monotonic / hourMilliseconds
    }

    /// The engine's counters in the window at `now`.
    func spent(now: Int64) -> Int64 {
        engine.spent(at: Self.hour(now))
    }

    /// `relay`'s counters in the window at `now`.
    func spent(relay: SpoolRelayHandle, now: Int64) -> Int64 {
        relays[relay]?.spent(at: Self.hour(now)) ?? 0
    }

    /// `peer`'s counters in the window at `now`.
    func spent(peer: NodeId, now: Int64) -> Int64 {
        peers[peer]?.spent(at: Self.hour(now)) ?? 0
    }

    /// The hour `relay`'s share holds `need` more counters at `now`, or `nil` when it holds them now.
    func relayFreesAt(_ relay: SpoolRelayHandle, need: Int64, now: Int64) -> Int64? {
        relays[relay]?.freesAt(need: need, cap: Self.relayCap, hour: Self.hour(now))
    }

    /// Charges one run's `tried` to the engine, `relay` and `peer` at `now`.
    mutating func charge(_ tried: Int64, relay: SpoolRelayHandle, peer: NodeId, now: Int64) {
        let hour = Self.hour(now)
        engine.charge(tried, at: hour)
        relays[relay, default: Record()].charge(tried, at: hour)
        peers[peer, default: Record()].charge(tried, at: hour)
        relays = relays.filter { $0.value.spent(at: hour) > 0 }
        peers = peers.filter { $0.value.spent(at: hour) > 0 }
    }

    /// Whether a search of `need` counters for `relay` and `peer` fits at `now`: `nil` when the engine and both shares hold
    /// it, otherwise the first share that does not and how long until every short one does, held to the shortest park and
    /// a day. A relay or peer with no record has spent nothing, and `need` is at most a full search, which every cap holds.
    func shortfall(need: Int64, relay: SpoolRelayHandle, peer: NodeId, now: Int64) -> (share: Share, parkMilliseconds: Int64)? {
        let hour = Self.hour(now)
        let frees: [(Share, Int64?)] = [
            (.engine, engine.freesAt(need: need, cap: Self.engineCap, hour: hour)),
            (.relay, relays[relay]?.freesAt(need: need, cap: Self.relayCap, hour: hour)),
            (.peer, peers[peer]?.freesAt(need: need, cap: Self.peerCap, hour: hour)),
        ]
        let short = frees.compactMap { share, at in at.map { (share, $0) } }
        guard let first = short.first, let latest = short.map(\.1).max() else {
            return nil
        }
        // Counted from the hour's start and held to a window, so no clock value overflows it, a clock that ran back included.
        let wait = min(latest - hour, Self.windowHours) * Self.hourMilliseconds - now % Self.hourMilliseconds
        return (first.0, min(max(wait, SpoolSession.minParkMilliseconds), SpoolPow.dayMilliseconds))
    }
}
