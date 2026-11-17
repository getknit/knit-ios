/// What the engine's spool door keeps between candidates (``MeshEngine/receiveFromSpool(_:relay:)``, ADR 2026-11.adrq,
/// P4a): the engine's one bridge budget, and the counts `status` reads. Pure, its times on the monotonic clock the caller
/// passes.
internal struct SpoolInbound: Sendable {
    /// What the door has done, for `status`.
    struct Counts: Sendable, Equatable {
        /// Candidates delivered, or found already seen, and settled `.delivered`.
        var delivered = 0
        /// Candidates whose signature failed, or whose sender has no key here.
        var unopenable = 0
        /// Candidates settled `.notTaken` because a store unit failed.
        var notTaken = 0
        /// Candidates the carry gate refused for their own bytes.
        var refusedByCarry = 0
        /// Profiles refused at the door as over custody's profile cap.
        var oversizeProfiles = 0
        /// Candidates a router had already seen.
        var duplicates = 0
        /// Frames scheduled onto the radios.
        var bridged = 0
        /// Frames newly carried that the bridge budget left to custody's own digest exchange.
        var bridgeDeferred = 0
    }

    private(set) var counts = Counts()
    /// The engine's one bridge budget, shared by every relay, full from its first use.
    private var bridge: SpoolBridgeBudget?

    /// Takes a bridge token at `now`, for a frame the router will schedule, and counts what came of it.
    mutating func takesBridgeToken(now: Int64) -> Bool {
        var bucket = bridge ?? SpoolBridgeBudget(now: now)
        let taken = bucket.take(now: now)
        bridge = bucket
        if taken {
            counts.bridged += 1
        } else {
            counts.bridgeDeferred += 1
        }
        return taken
    }

    /// Counts how a candidate settled.
    mutating func note(_ settlement: ScopeHeal.Settlement) {
        switch settlement {
        case .delivered:
            counts.delivered += 1
        case .unopenable:
            counts.unopenable += 1
        case .notTaken:
            counts.notTaken += 1
        case .refusedByCarry:
            counts.refusedByCarry += 1
        }
    }

    mutating func noteOversizeProfile() {
        counts.oversizeProfiles += 1
    }

    mutating func noteDuplicate() {
        counts.duplicates += 1
    }
}

/// The engine's bridge budget, a token bucket (ADR 2026-11.adrq, P4a, this port's own rule): bridging is bounded by one
/// budget per engine, shared by every relay, of 32 frames in a burst and one more every two seconds. A frame over the
/// budget is delivered and kept, and not bridged.
internal struct SpoolBridgeBudget: Sendable, Equatable {
    /// The most frames bridged in a burst.
    static let capacity = 32
    /// One token comes back each interval, on the monotonic clock.
    static let refillMilliseconds: Int64 = 2000

    private(set) var tokens: Int
    private var refilledAt: Int64

    /// A full bucket at `now`.
    init(now: Int64) {
        tokens = Self.capacity
        refilledAt = now
    }

    /// Takes one token at `now`, if one is left after the refill.
    mutating func take(now: Int64) -> Bool {
        if now > refilledAt {
            let (elapsed, overflow) = now.subtractingReportingOverflow(refilledAt)
            let earned = overflow ? Int64(Self.capacity) : elapsed / Self.refillMilliseconds
            if earned > 0 {
                tokens = Int(min(Int64(Self.capacity), Int64(tokens) + min(earned, Int64(Self.capacity))))
                refilledAt = tokens == Self.capacity ? now : refilledAt + earned * Self.refillMilliseconds
            }
        } else if now < refilledAt {
            // A clock that went back starts the interval again from here.
            refilledAt = now
        }
        guard tokens > 0 else {
            return false
        }
        tokens -= 1
        return true
    }
}
