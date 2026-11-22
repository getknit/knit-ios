public import KnitCrypto
import KnitStore
public import KnitWire

extension RatchetSessions {
    /// One peer's DM scopes (`ExportedRoots`, knit-next `RatchetSessions.kt:1033-1042` at `0832b8462`), as scope keys
    /// rather than roots: the session's live scope, and the scope of the root it replaced while that root drains.
    public struct DMScopes: Sendable {
        /// The peer.
        public let peerId: NodeId
        /// The scope of the session's root: pulled, and refilled with what the frame-set rule admits.
        public let live: ScopeKeys
        /// The scope of the session's previous root, while it drains (C-3.1-2): pulled, never refilled (C-3.1-3). `nil`
        /// when there is none, or its drain ended.
        public let retiring: ScopeKeys?
        /// When ``retiring``'s drain ends (`prevRootExpiresAt`, our clock), `nil` with no retiring scope: the spool plane
        /// reads the table again then (ADR 2026-11.adrq, P4a).
        public var retiringUntil: Int64?
    }

    /// The DM scopes of every session that exports one, read in a unit of its own (`exportedRoots`,
    /// `RatchetSessions.kt:977-989`; ADR 2026-11.adrq). Each scope's id and keys are derived here, from the root through
    /// ``RatchetCrypto/exportRoot(_:)`` and our id and the peer's, so no root, `pairwiseRoot` or ratchet state leaves this
    /// facade; the spool plane gets scope keys alone.
    ///
    /// A session exports only once it is confirmed (``exports(_:)``). The retiring scope is the `prevRoot` a resolution
    /// kept, while `prevRootExpiresAt` is past `now`, our clock: the stamp is ours too.
    ///
    /// `nil` when a store could not be read, and when asked inside a caller's unit. A caller reads `nil` as "no change"
    /// and keeps the scopes it holds; it never reads it as "no scopes", which would drop every subscription on a
    /// passing store error.
    public func dmScopes(now: Int64) -> [DMScopes]? {
        let ours = identity.nodeId
        let unit = transactor.atomically { () -> [DMScopes]? in
            store.sessionPeerIds().compactMap { peer -> DMScopes? in
                guard let session = store.session(peer), Self.exports(session) else {
                    return nil
                }
                let retiring = session.prevRoot.flatMap { prevRoot in
                    session.prevRootExpiresAt > now ? Self.dmScope(of: prevRoot, ours, peer) : nil
                }
                return DMScopes(
                    peerId: peer,
                    live: Self.dmScope(of: session.root, ours, peer),
                    retiring: retiring,
                    retiringUntil: retiring == nil ? nil : session.prevRootExpiresAt
                )
            }
        }
        guard case .committed(let scopes) = unit else {
            return nil
        }
        return scopes
    }

    /// Whether the spool may derive scopes from `session` (`exports`, `RatchetSessions.kt:1099`): a confirmed session. A
    /// first-contact init is not, since the pair may still be resolving a race. Kotlin also takes our own reset while
    /// it waits for its answer over a root it replaced (`pendingResetInit`, knit-next ADR 2026-10.j67x's rule 1). The slot
    /// and race rules that exception stands on are ported (j67x's rules 2 and 3, ``pendingResetInit(_:)``, ADR 2026-10.5sk9's
    /// P9a amendment); rule 1 itself is deferred (ADR 2026-11.adrq), so such a reset exports nothing here. Nothing else
    /// gates it: two phones meet only in a scope both derive.
    static func exports(_ session: RatchetSessionRecord) -> Bool {
        session.confirmed
    }

    /// A root's DM scope with `peer`.
    private static func dmScope(of root: [UInt8], _ ours: NodeId, _ peer: NodeId) -> ScopeKeys {
        ScopeCrypto.dmScope(pairwiseRoot: RatchetCrypto.exportRoot(root), ours, peer)
    }
}
