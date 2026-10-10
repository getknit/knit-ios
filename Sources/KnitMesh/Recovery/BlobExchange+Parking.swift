import KnitWire

/// Asks for a blob we hold that came in while another copy of it was being fed (`parked`, `BlobExchange.kt:174-184`,
/// knit-next ADR 2026-10.g24x, `e2191bb9`, and its ADR 2026-10.nsr7, `79f38d3d`). Each blob's best ask is served once no
/// live copy of it is fed to anyone else (``MeshEngine`` reads the feeds), and an ask is dropped when its asker unlinks
/// or stops renewing it. The bookkeeping alone: the engine decides.
extension BlobExchange {
    /// How often parked asks look for their blob's other feed to have ended, at the soonest (`PARK_POLL_MS`).
    static let parkPollMilliseconds: Int64 = 1000
    /// The longest the poll sleeps between passes (`PARK_POLL_MAX_MS`): a parked ask's fastest-first and beside checks
    /// move with the feeds' measured rates, which a report may change at any time.
    static let parkPollMaxMilliseconds: Int64 = 10_000
    /// How many blobs may have asks parked at once (`MAX_PARKED_BLOBS`): an unsigned `blobreq` can park one, so the
    /// eldest goes past the cap, and its askers ask again.
    static let maxParkedBlobs = 64

    /// An ask parked behind another copy's feed (`ParkedAsk`): the copy's length, when it was parked, when its asker last
    /// asked or queried for it, and how long a SENDING answer promised it, with its slack.
    struct ParkedAsk: Sendable, Equatable {
        var bytes: Int64
        var since: Int64
        var at: Int64
        var until: Int64

        /// When it lapses unrenewed (`keptUntil`): the memo after its last ask or query, or what it was promised.
        var keptUntil: Int64 {
            max(at + BlobExchange.serveMemoMilliseconds, until)
        }
    }

    /// Parks `asker`'s ask for `hash`, a copy of `bytes`, or refreshes it when it is parked already (`parkBehindFeed`'s
    /// book). Answers whether the park is fresh. A new blob past ``maxParkedBlobs`` evicts the eldest.
    mutating func park(_ hash: BlobHash, for asker: NodeId, bytes: Int64, now: Int64) -> Bool {
        if parked[hash] == nil {
            parkedOrder.append(hash)
            if parkedOrder.count > Self.maxParkedBlobs {
                parked[parkedOrder.removeFirst()] = nil
            }
        }
        let was = parked[hash]?[asker]
        parked[hash, default: [:]][asker] = ParkedAsk(bytes: bytes, since: was?.since ?? now, at: now, until: was?.until ?? 0)
        if parkPollAt == nil {
            parkPollAt = now + Self.parkPollMilliseconds
        }
        return was == nil
    }

    /// Whether `asker`'s ask for `hash` is parked (`isParked`): a peek, nothing pruned.
    func isParked(_ hash: BlobHash, for asker: NodeId) -> Bool {
        parked[hash]?[asker] != nil
    }

    /// `asker`'s parked ask for `hash`, renewed at `now` (`etaFor`'s renewal), or `nil` when none is parked.
    mutating func renewParked(_ hash: BlobHash, for asker: NodeId, now: Int64) -> ParkedAsk? {
        parked[hash]?[asker]?.at = now
        return parked[hash]?[asker]
    }

    /// Keeps `asker`'s parked ask for `hash` at least until `until`: what a SENDING answer promised it, and its slack.
    mutating func keepParked(_ hash: BlobHash, for asker: NodeId, until: Int64) {
        if let kept = parked[hash]?[asker]?.until, until > kept {
            parked[hash]?[asker]?.until = until
        }
    }

    /// Takes `asker`'s parked ask for `hash` off the book (`takeParked`): false when none was parked.
    mutating func takeParked(_ hash: BlobHash, for asker: NodeId) -> Bool {
        guard parked[hash]?.removeValue(forKey: asker) != nil else {
            return false
        }
        if parked[hash]?.isEmpty == true {
            parked[hash] = nil
            parkedOrder.removeAll { $0 == hash }
        }
        return true
    }

    /// Drops every parked ask whose asker is not `linked`, or that nobody renewed in time (``ParkedAsk/keptUntil``), and
    /// answers what is left, blob by blob in the order they were parked (`serveParked`'s prune).
    mutating func pruneParked(linked: Set<NodeId>, now: Int64) -> [(hash: BlobHash, asks: [(asker: NodeId, ask: ParkedAsk)])] {
        for hash in parkedOrder {
            parked[hash] = parked[hash]?.filter { linked.contains($0.key) && now < $0.value.keptUntil }
            if parked[hash]?.isEmpty == true {
                parked[hash] = nil
            }
        }
        parkedOrder.removeAll { parked[$0] == nil }
        return parkedOrder.compactMap { hash in
            parked[hash].map { asks in (hash, asks.map { (asker: $0.key, ask: $0.value) }.sorted { $0.asker.string < $1.asker.string }) }
        }
    }

    /// Whether any ask is parked.
    var hasParked: Bool {
        !parked.isEmpty
    }
}
