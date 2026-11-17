import KnitCrypto

/// What the engine's stamp searches learnt, per (scope, day) (ADR 2026-11.adrq, P4b2, this port's own rule: Kotlin's stamp
/// cache keys by scope alone and forgets the bits):
/// - the best stamp found, the one with the most leading zero bits, with the bits it actually has, which answers every ask
///   at those bits or fewer;
/// - the fewest bits a whole search came up empty at, which answers every ask at those bits or more, since a counter with
///   more zero bits has fewer too;
/// - per bits, the counter a stopped search reached with no find, where a search at those bits or more resumes: no counter
///   below it meets fewer bits, so none meets more.
///
/// Every search runs from where the entries say no stamp lies below it, so a run that ends exhausted covered `0..<maxTries`.
/// An entry leaves when its day is past reuse (``SpoolPow/reusable(stampDay:nowMs:)`` on the wall clock), never because its
/// scope left the table: a scope that leaves and comes back is not mined again. Past ``maxEntries`` the entries of scopes
/// not in the table go first, then the oldest day. In memory: P6 persists the found entries.
internal struct SpoolMinerCache: Sendable, Equatable {
    /// A stamp's own day and the next, which a spool still takes.
    static let daysKept = 2
    /// A peer's live scope and its retiring one.
    static let scopesPerPeer = 2
    /// Two days for each of two scopes for each of the table's peers.
    static let maxEntries = daysKept * ScopeTable.maxPeers * scopesPerPeer

    struct Key: Hashable, Sendable {
        let scope: SpoolID
        let day: Int64
    }

    struct Found: Sendable, Equatable {
        let counter: Int64
        let bits: Int
    }

    struct Entry: Sendable, Equatable {
        var found: Found?
        var exhaustedBits: Int?
        var reached: [Int: Int64] = [:]
    }

    private(set) var entries: [Key: Entry] = [:]

    /// What the entries already answer for `value`, or `nil` when a search must run.
    func answer(_ value: SpoolMiner.Value) -> SpoolStampAnswer? {
        let entry = entries[value.key]
        if let found = entry?.found, found.bits >= value.bits {
            return .found(counter: found.counter, bits: found.bits)
        }
        if let bits = entry?.exhaustedBits, value.bits >= bits {
            return .exhausted
        }
        return nil
    }

    /// Where a search for `value` starts: the furthest counter a stopped search reached at its bits or fewer, or 0.
    func resumeFrom(_ value: SpoolMiner.Value) -> Int64 {
        entries[value.key]?.reached.filter { $0.key <= value.bits }.values.max() ?? 0
    }

    /// A search for `value` found `counter`, whose digest has `bits` leading zero bits.
    mutating func found(_ value: SpoolMiner.Value, counter: Int64, bits: Int, table: Set<SpoolID>) {
        var entry = entries[value.key] ?? Entry()
        if entry.found.map({ $0.bits < bits }) != false {
            entry.found = Found(counter: counter, bits: bits)
        }
        store(entry, at: value.key, table: table)
    }

    /// A search for `value` covered every counter and found none.
    mutating func exhausted(_ value: SpoolMiner.Value, table: Set<SpoolID>) {
        var entry = entries[value.key] ?? Entry()
        entry.exhaustedBits = min(entry.exhaustedBits ?? value.bits, value.bits)
        store(entry, at: value.key, table: table)
    }

    /// A search for `value` stopped at `counter` with no find.
    mutating func reached(_ value: SpoolMiner.Value, counter: Int64, table: Set<SpoolID>) {
        var entry = entries[value.key] ?? Entry()
        entry.reached[value.bits] = max(entry.reached[value.bits] ?? 0, counter)
        store(entry, at: value.key, table: table)
    }

    /// Drops every entry whose day is past reuse at `wall`.
    mutating func prune(wall: Int64) {
        entries = entries.filter { SpoolPow.reusable(stampDay: $0.key.day, nowMs: wall) }
    }

    /// Stores `entry`, and past ``maxEntries`` evicts one: a scope not in `table` before one in it, then the oldest day,
    /// then the lowest scope id.
    private mutating func store(_ entry: Entry, at key: Key, table: Set<SpoolID>) {
        entries[key] = entry
        guard entries.count > Self.maxEntries else {
            return
        }
        let victim = entries.keys.min { lhs, rhs in
            let (left, right) = (table.contains(lhs.scope), table.contains(rhs.scope))
            if left != right {
                return !left
            }
            return lhs.day != rhs.day ? lhs.day < rhs.day : lhs.scope.bytes.lexicographicallyPrecedes(rhs.scope.bytes)
        }
        if let victim {
            entries[victim] = nil
        }
    }
}
