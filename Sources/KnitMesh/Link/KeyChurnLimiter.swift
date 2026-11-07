import KnitCrypto
import KnitWire

/// Bounds what a contact's key churn costs the resolver (knit-next ADR 2026-11.xp6d's reader, obligation 6;
/// `KeyChurnLimiter.kt` at `cad69c77b`; ADR 2026-11.sv5t): a new key is up to a window's 140 HMACs, so a contact streaming
/// generations would otherwise spend the engine without end. Between the key store's listing (``offer(_:now:)``, node id
/// → keys newest first, the whole set) and ``AdvertAliases/setKeys(_:now:wall:)``:
///
/// 1. a contact's listing **gains a key** at most once per ``minIntervalMilliseconds``, and at most ``dailyCap`` times per
///    rolling day; a change inside either is held, and when the window frees the **newest** listing held applies
///    (``held``, and ``coalesced`` for a held listing a newer one replaced);
/// 2. **unlisting is never delayed**: a contact leaving the listing and a key dropped apply at once, and a change that
///    both drops and gains applies its drop at once and holds its gain.
///
/// A contact that leaves the listing and comes back within a day is counted against what it gained before. **A re-entry
/// with keys it held is a relisting, not a gain**: it waits for the interval alone and never counts toward the cap.
///
/// Pure, on the monotonic clock the caller passes. ``nextDueAt()`` is the deadline the link manager wakes for.
internal struct KeyChurnLimiter {
    /// One gain per contact per this (`MIN_INTERVAL_MS`).
    static let minIntervalMilliseconds: Int64 = 60_000
    /// Gains per contact per rolling day (`DAILY_CAP`).
    static let dailyCap = 24
    /// The rolling day (`DAY_MS`).
    static let dayMilliseconds: Int64 = 86_400_000

    private struct State {
        var applied: [PresenceKey]
        var pending: [PresenceKey]?
        /// The held listing is a relisting: only the interval applies to it.
        var pendingRelist = false
        var gains: [Int64] = []
        /// When a listing last went to the resolver (a gain or a relisting): the interval runs from it.
        var listedAt: Int64?
    }

    /// What a contact that left held: its gains, the keys applied when it left, and when it was last listed.
    private struct Departed {
        let gains: [Int64]
        let keys: [PresenceKey]
        let listedAt: Int64?
    }

    private let minInterval: Int64
    private let cap: Int
    private let day: Int64
    private var contacts: [NodeId: State] = [:]
    private var departed: [NodeId: Departed] = [:]

    /// Changes held for a window.
    private(set) var held = 0
    /// Held changes a newer one replaced.
    private(set) var coalesced = 0

    /// A limiter with knit-next's bounds.
    init() {
        self.init(minIntervalMilliseconds: Self.minIntervalMilliseconds, dailyCap: Self.dailyCap, dayMilliseconds: Self.dayMilliseconds)
    }

    /// A limiter with these bounds.
    init(minIntervalMilliseconds: Int64, dailyCap: Int, dayMilliseconds: Int64) {
        minInterval = minIntervalMilliseconds
        cap = dailyCap
        day = dayMilliseconds
    }

    /// The store's whole listing at `now`. Answers the listing to hand the resolver now, or `nil` when nothing it holds
    /// changed (every gain held).
    mutating func offer(_ listing: [NodeId: [PresenceKey]], now: Int64) -> [NodeId: [PresenceKey]]? {
        departed = departed.filter { _, gone in
            guard let last = gone.listedAt ?? gone.gains.last else {
                return false
            }
            return now - last < day
        }
        let leaving = contacts.keys.filter { listing[$0] == nil }
        for id in leaving {
            if let state = contacts.removeValue(forKey: id) {
                departed[id] = Departed(gains: state.gains, keys: state.applied, listedAt: state.listedAt)
            }
        }
        var changed = !leaving.isEmpty
        for (id, keys) in listing {
            // A contact new to the listing gains as any other does, against what it gained before it left.
            let moved = contacts[id] == nil ? firstListing(id, keys, now: now) : apply(id, keys, now: now)
            changed = moved || changed
        }
        return changed ? applied : nil
    }

    /// Applies the held listings whose window has freed at `now`: the listing to hand the resolver, or `nil` for none.
    mutating func release(now: Int64) -> [NodeId: [PresenceKey]]? {
        var changed = false
        for id in contacts.keys {
            guard var state = contacts[id], let pending = state.pending, now >= dueAt(&state) else {
                continue
            }
            state.pending = nil
            state.applied = pending
            if !state.pendingRelist {
                state.gains.append(now)
            }
            state.pendingRelist = false
            state.listedAt = now
            contacts[id] = state
            changed = true
        }
        return changed ? applied : nil
    }

    /// When the first held listing may apply, on the monotonic clock; `nil` with none held.
    func nextDueAt() -> Int64? {
        contacts.values.filter { $0.pending != nil }.map { state in
            var state = state
            return dueAt(&state)
        }.min()
    }

    private mutating func firstListing(_ id: NodeId, _ keys: [PresenceKey], now: Int64) -> Bool {
        var state = State(applied: [])
        let before = departed.removeValue(forKey: id)
        if let before {
            state.gains = before.gains
            state.listedAt = before.listedAt
        }
        // Only keys it held when it left: a relisting, under the interval alone.
        state.pendingRelist = before.map { gone in keys.allSatisfy(gone.keys.contains) } ?? false
        if now >= dueAt(&state) {
            state.applied = keys
            if !state.pendingRelist {
                state.gains.append(now)
            }
            state.pendingRelist = false
            state.listedAt = now
            contacts[id] = state
            return true
        }
        // Back inside its window: held like any other change, with nothing listed meanwhile.
        state.pending = keys
        held += 1
        contacts[id] = state
        return false
    }

    private mutating func apply(_ id: NodeId, _ keys: [PresenceKey], now: Int64) -> Bool {
        guard var state = contacts[id] else {
            return false
        }
        defer { contacts[id] = state }
        if state.applied == keys {
            if state.pending != nil {
                coalesced += 1
            }
            state.pending = nil
            state.pendingRelist = false
            return false
        }
        // The listing held already, offered again: it stays held as it was (a relisting stays one).
        if state.pending == keys {
            return false
        }
        let gains = keys.contains { !state.applied.contains($0) }
        guard gains else {
            // A pure drop: never delayed.
            state.applied = keys
            state.pending = nil
            state.pendingRelist = false
            return true
        }
        state.pendingRelist = false
        if now >= dueAt(&state) {
            state.applied = keys
            state.pending = nil
            state.gains.append(now)
            state.listedAt = now
            return true
        }
        if state.pending != nil {
            coalesced += 1
        } else {
            held += 1
        }
        state.pending = keys
        // Its drop goes at once: what stays listed is what both name.
        let kept = state.applied.filter(keys.contains)
        guard kept.count != state.applied.count else {
            return false
        }
        state.applied = kept
        return true
    }

    /// When `state`'s next listing may go: the interval from its last one, and for a gain the daily cap too. Trims the gains
    /// to the cap, as Kotlin's `dueAt` does.
    private func dueAt(_ state: inout State) -> Int64 {
        if state.gains.count > cap {
            state.gains.removeFirst(state.gains.count - cap)
        }
        let last = max(state.listedAt ?? .min, state.gains.last ?? .min)
        let interval = last == .min ? Int64.min : last + minInterval
        if state.pendingRelist {
            return interval
        }
        let daily = state.gains.count >= cap ? (state.gains.first ?? .min) + day : Int64.min
        return max(interval, daily)
    }

    private var applied: [NodeId: [PresenceKey]] {
        contacts.filter { !$0.value.applied.isEmpty }.mapValues(\.applied)
    }
}
