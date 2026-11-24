import KnitWire

/// When each peer was last heard, between a verified frame and the bank that writes it to `peers.lastSeenAt` (knit-next ADR
/// 2026-10.k8ge: `HeardFrom.kt`, and `PeerRepository.noteSeen` and `flushSeen`, `PeerRepository.kt:150-182` at `2e91518e3`).
/// The stamp lets a stranger's name clash fade once they have been quiet for a week; the window lives in KnitAppCore's
/// `LabelFade`, and the gate and the cap here.
///
/// Presentation only. The stamp is the sender's own `sentAt` and rides every re-serve, so nothing here may feed a presence
/// tier, a route, custody, a fetch order or an eviction order (`PresenceTracker` keeps its own, local, clock).
///
/// Pure and in memory: the engine notes each verified frame here, and its 60 s timer and ``Mesh/stop()`` bank what built up
/// in one write. ``heardAt(_:now:)`` floors a peer's stamp at 0, and every subtraction on one is overflow-checked.
internal struct HeardFrom {
    /// How much newer than the row's a stamp must be to cost a write, six hours (`LabelFade.SEEN_GATE_MS`, `LabelFade.kt:43`): a live
    /// peer costs a write or two a day, not one a frame.
    static let gateMilliseconds: Int64 = 21_600_000
    /// How many senders the buffer holds between banks (`SEEN_BUFFER_CAP`, `PeerRepository.kt:362`): a new one past it is
    /// dropped, one already held still merges.
    static let bufferCap = 1024

    /// The stamps noted since the last bank, the newest per sender.
    private(set) var heard: [NodeId: Int64] = [:]
    /// The newest stamp banked or read back per sender, or `nil` before the first bank primes it from the table.
    private(set) var banked: [NodeId: Int64]?

    /// Whether a frame ``MeshEngine/verify(_:)`` let through shows its author was heard from (`isHeardEvidence`,
    /// `HeardFrom.kt`): a signed frame that is not the blob traffic. The blob traffic and the v3 tick reach a handler
    /// unsigned, judged by their shape alone, so neither says who wrote them.
    static func isEvidence(_ wire: WireEnvelope, _ envelope: RelayEnvelope) -> Bool {
        !wire.sig.isEmpty && !envelope.type.isUnsignedPointToPoint
    }

    /// When `envelope` says its author was heard (`heardAt`, `HeardFrom.kt`): its own `sentAt`, capped at our wall clock
    /// `now`, so a replay keeps its age and a future stamp never outlives the moment we took it. Floored at 0, where Kotlin
    /// keeps a negative stamp: a stored presentation value, not a wire one, so nothing on Android reads the difference.
    static func heardAt(_ envelope: RelayEnvelope, now: Int64) -> Int64 {
        max(0, min(now, envelope.sentAt))
    }

    /// Notes that `sender` was heard `at` (`noteSeen`): the newest stamp per sender wins, and a sender new past the cap is
    /// dropped.
    mutating func note(_ sender: NodeId, at: Int64) {
        guard heard[sender] != nil || heard.count < Self.bufferCap else {
            return
        }
        heard[sender] = max(heard[sender] ?? at, at)
    }

    /// Drains the buffer and answers the stamps due a write (`flushSeen`'s `due`): those for a sender with nothing banked,
    /// or at least the gate newer than what was. `prime` reads the table's stamps, once, before the first bank. Empty when
    /// nothing was heard, without priming.
    mutating func takeDue(priming prime: () -> [NodeId: Int64]) -> [NodeId: Int64] {
        guard !heard.isEmpty else {
            return [:]
        }
        let pending = heard
        heard = [:]
        let written = banked ?? prime()
        banked = written
        return pending.filter { sender, at in
            guard let held = written[sender] else {
                return true
            }
            let (newer, overflow) = at.subtractingReportingOverflow(held)
            // Overflow is a newer stamp past any range a held one could reach, or an older one past it the other way.
            return overflow ? at > held : newer >= Self.gateMilliseconds
        }
    }

    /// Settles a bank of `due`: written (`true`, whatever rows took it, as `flushSeen` remembers it), so the gate counts
    /// from it; or failed, so it goes back to the buffer for the next bank and the memory of what was written stays.
    mutating func settle(_ due: [NodeId: Int64], written: Bool) {
        if written {
            banked?.merge(due, uniquingKeysWith: max)
        } else {
            heard.merge(due, uniquingKeysWith: max)
        }
    }
}
