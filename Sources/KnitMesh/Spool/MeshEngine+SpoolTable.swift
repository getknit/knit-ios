import KnitStore
import KnitWire

/// What the scope table reads from the engine's stores (``ScopeTable/updated(dmScopes:accepted:blocked:recent:relays:)``),
/// each input in a store unit of its own, never nested in another, and `nil` when its unit failed: SQL stores answer a
/// failed read as empty (ADR 2026-09.nyya), and an empty `blocked` would let a blocked peer's scope back in (ADR
/// 2026-11.adrq, P4a).
internal struct SpoolTableInputs {
    /// The confirmed sessions' scopes (``RatchetSessions/dmScopes(now:)``, its own unit).
    var dmScopes: [RatchetSessions.DMScopes]?
    /// The person's direct contacts before blocks (``DirectContacts/candidates(accepted:verified:authored:)``).
    var accepted: Set<NodeId>?
    /// Every blocked node id, the device-tag blocks resolved over every pinned peer.
    var blocked: Set<NodeId>?
    /// This phone's own last activity with each DM peer: the time we sent our newest message there, or when a peer's newest
    /// arrived here by our clock, never a peer's `sentAt`.
    var recent: [NodeId: Int64]?
}

extension MeshEngine {
    /// Reads the scope table's inputs, each in a unit of its own (``SpoolTableInputs``), at `now` on the wall clock.
    func spoolTableInputs(now: Int64) -> SpoolTableInputs {
        SpoolTableInputs(
            dmScopes: ratchet.dmScopes(now: now),
            accepted: readInUnit {
                let known = Acquaintances(reading: self)
                return DirectContacts.candidates(accepted: known.accepted, verified: known.verified, authored: known.authored)
            },
            blocked: readInUnit {
                let tagBlocked = stores.peers.allPeers().filter { peer in peer.deviceTag.map(stores.blocks.isBlocked(deviceTag:)) == true }
                return stores.blocks.blockedNodeIds().union(tagBlocked.map(\.nodeId))
            },
            recent: readInUnit { recentActivity() }
        )
    }

    /// The newest of each DM thread, by our own clock: our send time for one of ours, its arrival here for a peer's.
    private func recentActivity() -> [NodeId: Int64] {
        var recent: [NodeId: Int64] = [:]
        for head in stores.messages.threadHeads(excludingSenders: []) {
            guard let peer = DirectContacts.dmPeer(head.conversationId) else {
                continue
            }
            let stamp = head.senderId == nodeId ? head.sentAt : head.arrivedAt
            if let stamp {
                recent[peer] = max(recent[peer] ?? .min, stamp)
            }
        }
        return recent
    }

    /// `read` in a store unit of its own, or `nil` when the unit did not commit as the outermost.
    private func readInUnit<Value>(_ read: () -> Value) -> Value? {
        guard case .committed(let value) = stores.transactor.atomically({ () -> Value? in read() }) else {
            return nil
        }
        return value
    }
}
