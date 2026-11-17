/// What `status` shows of the spool plane (ADR 2026-11.adrq, P4b1): relays by handle and counts, and nothing else: no URL,
/// no token, no scope id.
public struct SpoolStatus: Sendable, Equatable {
    /// One relay's line.
    public struct Relay: Sendable, Equatable {
        /// The relay's handle.
        public let handle: Int
        /// `idle`, `dialing` or `open`.
        public let state: String
        /// Unreached sessions in a row.
        public let failures: Int
        /// Its counts by name.
        public let counts: [String: Int]
    }

    /// Whether the plane is paused.
    public let paused: Bool
    /// The scopes the table carries.
    public let scopes: Int
    /// The plane's counts by name: the door's, and the table reads that kept the table.
    public let counts: [String: Int]
    /// Each relay, by handle.
    public let relays: [Relay]
}

extension SpoolPlane {
    /// The plane as `status` shows it, beside `inbound`, the engine door's counts, at `now` on the monotonic clock: the
    /// miner's counts and the counters it spent in the window, engine-wide (P4b2).
    func status(inbound: SpoolInbound.Counts, now: Int64) -> SpoolStatus {
        var counts = SpoolLogBook.counts(inbound)
        counts["unreadableTables"] = unreadableTables
        for (word, count) in SpoolLogBook.counts(miner.counts) {
            counts[word] = count
        }
        counts["minerSpent"] = Int(miner.budget.spent(now: now))
        let lines = relays.sorted { $0.key < $1.key }.map { handle, relay -> SpoolStatus.Relay in
            var line = SpoolLogBook.counts(relay.link.counts)
            for (word, count) in SpoolLogBook.counts(relay.heal.counts) {
                line[word] = count
            }
            for (word, count) in relay.drops {
                line["dropped." + word] = count
            }
            for (code, count) in relay.errors {
                line["error." + code] = count
            }
            line["queuedBytes"] = relay.link.queuedBytes
            line["mining"] = relay.heal.mining.count
            return SpoolStatus.Relay(handle: handle.number, state: relay.link.state, failures: relay.link.failures, counts: line)
        }
        return SpoolStatus(paused: paused, scopes: table.scopes.count, counts: counts, relays: lines)
    }

    /// The log lines due at `now`, at most one per kind per relay per ``SpoolLogBook/intervalMilliseconds``.
    mutating func logLines(inbound: SpoolInbound.Counts, now: Int64) -> [String] {
        var lines: [String] = []
        var door = SpoolLogBook.counts(inbound)
        door["unreadableTables"] = unreadableTables
        lines += logBook.line("spool", kind: "door", door, now: now)
        lines += logBook.line("spool", kind: "miner", SpoolLogBook.counts(miner.counts), now: now)
        for (handle, relay) in relays.sorted(by: { $0.key < $1.key }) {
            let name = "spool \(handle)"
            lines += logBook.line(name, kind: "link", SpoolLogBook.counts(relay.link.counts), now: now)
            lines += logBook.line(name, kind: "heal", SpoolLogBook.counts(relay.heal.counts), now: now)
            lines += logBook.line(name, kind: "dropped", relay.drops, now: now)
            lines += logBook.line(name, kind: "refused", relay.errors, now: now)
        }
        return lines
    }
}

/// The plane's log lines (ADR 2026-11.adrq, P4b1): at most one line per kind per relay per ``intervalMilliseconds``, carrying
/// what moved since that kind's last line, at warning level. A line is built from count names, numbers, a relay's handle and
/// the spec's refusal codes alone (a spool's own code reads `other`): no URL, no node id, no scope id or any part of one, and
/// never a spool's own text.
internal struct SpoolLogBook: Sendable {
    /// The least time between two lines of one kind for one relay.
    static let intervalMilliseconds: Int64 = 60_000

    private var logged: [String: (at: Int64, counts: [String: Int])] = [:]

    /// The line for `kind` under `name` when `counts` moved since its last line and its interval is over, or none.
    mutating func line(_ name: String, kind: String, _ counts: [String: Int], now: Int64) -> [String] {
        let key = name + " " + kind
        let last = logged[key]
        if let last, now < SpoolSession.later(last.at, by: Self.intervalMilliseconds) {
            return []
        }
        let moved = counts.compactMap { word, count -> (String, Int)? in
            let delta = count - (last?.counts[word] ?? 0)
            return delta > 0 ? (word, delta) : nil
        }
        guard !moved.isEmpty else {
            return []
        }
        logged[key] = (now, counts)
        let parts = moved.sorted { $0.0 < $1.0 }.map { "\($0.0) \($0.1)" }
        return ["\(name) \(kind): " + parts.joined(separator: ", ")]
    }

    /// The word a drop counts under.
    static func word(for drop: SpoolDrop) -> String {
        switch drop {
        case .undecodable:
            "undecodable"
        case .unknown:
            "unknown"
        case .beforeHello:
            "beforeHello"
        case .lateHello:
            "lateHello"
        case .malformed:
            "malformed"
        case .unsubscribed:
            "unsubscribed"
        case .unsolicited:
            "unsolicited"
        case .oversize:
            "oversize"
        case .unmatched:
            "unmatched"
        }
    }

    static func counts(_ counts: SpoolInbound.Counts) -> [String: Int] {
        [
            "delivered": counts.delivered, "unopenable": counts.unopenable, "notTaken": counts.notTaken,
            "refusedByCarry": counts.refusedByCarry, "oversizeProfiles": counts.oversizeProfiles, "duplicates": counts.duplicates,
            "bridged": counts.bridged, "bridgeDeferred": counts.bridgeDeferred,
        ]
    }

    static func counts(_ counts: SpoolMiner.Counts) -> [String: Int] {
        [
            "minerRuns": counts.runs, "minerFound": counts.found, "minerExhausted": counts.exhausted,
            "minerStopped": counts.stopped, "minerResumed": counts.resumed, "minerOverBudget": counts.overBudget,
            "minerOverRelayShare": counts.overRelayShare, "minerOverPeerShare": counts.overPeerShare,
            "minerFromCache": counts.fromCache, "minerUnheldScopes": counts.unheldScopes,
        ]
    }

    static func counts(_ counts: SpoolLink.Counts) -> [String: Int] {
        [
            "dials": counts.dials, "dialFailures": counts.dialFailures, "dialTimeouts": counts.dialTimeouts,
            "sessions": counts.sessions, "reached": counts.reached, "unreached": counts.unreached,
            "writeStalls": counts.writeStalls, "sendFailures": counts.sendFailures, "inboundDeferred": counts.inboundDeferred,
            "textDropped": counts.textDropped, "stampsAnsweredOffline": counts.stampsAnsweredOffline,
            "dropFaults": counts.dropFaults,
        ]
    }

    static func counts(_ counts: ScopeHeal.Counts) -> [String: Int] {
        [
            "listings": counts.listings, "overlongListings": counts.overlongListings, "pushed": counts.pushed,
            "quarantined": counts.quarantined, "accounted": counts.accounted, "unpushable": counts.unpushable,
            "healDuplicates": counts.duplicates, "replays": counts.replays, "stampsCapped": counts.stampsCapped,
            "stampsRetiring": counts.stampsRetiring,
            "unreadableRounds": counts.unreadableRounds, "pullBudgetDeferred": counts.budgetDeferred, "faults": counts.faults,
            "parks": counts.parks, "pushBudgetDeferred": counts.pushBudgetDeferred, "outboundHeld": counts.outboundHeld,
            "roundsCompared": counts.roundsCompared,
        ]
    }
}
