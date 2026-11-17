import KnitWire

/// Which DM scopes the plane spends on, and at which relays (ADR 2026-11.adrq, amended 2026-11-16; Kotlin's
/// `ScopeRegistry.reconcile`, `ScopeRegistry.kt` at `0832b8462`, the DM half, which has neither gate nor cap). Pure: the
/// engine reads its stores and calls ``updated(dmScopes:accepted:blocked:recent:relays:)``.
///
/// - **Consent.** A peer is in only when the person accepted it (`accepted`: an accepted or authored DM thread, or a
///   verified contact, as the stores persist them) and has not blocked it. Group membership, a confirmed session and a
///   peer's message alone never count. The pair still meets: the peer's pushes wait at the spool, inside its 48 h, until
///   the person accepts.
/// - **Per scope, never per frame.** A scope is subscribed whole or not at all, so its local fold stays the spool's.
/// - **A cap.** At most ``maxPeers`` peers, ranked by this phone's own record of activity with each (`recent`), never a
///   peer's `sentAt`, which the peer writes. Live scopes come before retiring ones. A spool's `maxScopes` is not read
///   here: each session holds its own `sub`s to its own spool's cap, in this order, so one spool's cap costs no other
///   relay a scope.
/// - **No change on a failed read.** `nil` for `dmScopes`, `accepted` or `blocked` keeps the table as it stands
///   (``Update/unchanged``), never an empty one that would drop every subscription on a passing store error.
///
/// Relays are named by ``SpoolRelayHandle``, never by URL. Every relay carries every scope: this port has no homes.
internal struct ScopeTable: Sendable, Equatable {
    /// The most peers with scopes (P3's design pass, ADR 2026-11.adrq).
    static let maxPeers = 128

    /// What a reconcile came to.
    enum Update: Sendable, Equatable {
        /// The table moved.
        case table(ScopeTable)
        /// It stands as it was: an input could not be read, or nothing changed.
        case unchanged
    }

    /// The scopes, live ones by rank first, then retiring ones by rank.
    private(set) var scopes: [SpoolScope] = []
    /// The relays every scope rides, in handle order.
    private(set) var relays: [SpoolRelayHandle] = []

    /// The scope ids, for a heal loop's `adopt`.
    var ids: Set<SpoolID> { Set(scopes.map(\.id)) }

    /// The table these inputs make, or ``Update/unchanged``.
    ///
    /// `accepted` is the person's direct contacts before blocks (`DirectContacts.candidates`, the facts `Acquaintances`
    /// reads: accepted and authored DM threads and verified peers), the set the presence keys already read; it is never
    /// `Conversations.isAccepted`, whose group branch counts a group's senders. `blocked` holds every blocked node id,
    /// the device-tag blocks resolved to ids. `recent` is this phone's last activity with each peer (a message sent or
    /// received, by our clock); a peer with none ranks last, ties broken by node id.
    func updated(
        dmScopes: [RatchetSessions.DMScopes]?,
        accepted: Set<NodeId>?,
        blocked: Set<NodeId>?,
        recent: [NodeId: Int64],
        relays: [SpoolRelayHandle]
    ) -> Update {
        guard let dmScopes, let accepted, let blocked else {
            return .unchanged
        }
        let consented = dmScopes.filter { accepted.contains($0.peerId) && !blocked.contains($0.peerId) }
        let ranked = consented.sorted { lhs, rhs in
            let left = recent[lhs.peerId] ?? Int64.min
            let right = recent[rhs.peerId] ?? Int64.min
            return left != right ? left > right : lhs.peerId < rhs.peerId
        }
        let kept = ranked.prefix(Self.maxPeers)
        let live = kept.compactMap { SpoolScope.of($0.live, peer: $0.peerId, retiring: false) }
        let retiring = kept.compactMap { entry in entry.retiring.flatMap { SpoolScope.of($0, peer: entry.peerId, retiring: true) } }
        let next = Self(scopes: Self.unique(live + retiring), relays: Array(Set(relays)).sorted())
        return next == self ? .unchanged : .table(next)
    }

    /// The scopes with each id once, the first kept: two peers can never derive one id, but a table keyed by id must not
    /// trust that.
    private static func unique(_ scopes: [SpoolScope]) -> [SpoolScope] {
        var seen: Set<SpoolID> = []
        return scopes.filter { seen.insert($0.id).inserted }
    }
}
