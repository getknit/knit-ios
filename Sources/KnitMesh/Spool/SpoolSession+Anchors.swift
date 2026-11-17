import KnitCrypto

/// What the heal loop reads and moves on a connection's books (`ScopeSync.spoolDigests`, `spoolCounts` and `accepted`).
/// Each is kept only for a scope subscribed here and goes with the subscription or the connection, so a reconnect
/// re-pulls what custody lost by the ordinary route (`endSession`).
extension SpoolSession {
    /// The ids handled on this connection for one scope, oldest first (`ScopeSync.accepted`, `:3186-3209`).
    ///
    /// Claiming never evicts, so a flood of garbage that is claimed and released costs the set nothing and can never push
    /// out an id already delivered. Only ``trim()``, after a delivery, holds it to ``SpoolSession/maxClaimsPerScope``,
    /// oldest first: the claims in flight are the newest, so the trim takes settled ones.
    struct ClaimSet: Sendable {
        private var members: Set<SpoolID> = []
        private var order: [SpoolID] = []

        /// Adds `id`, or answers `false` when it is already here.
        mutating func insert(_ id: SpoolID) -> Bool {
            guard members.insert(id).inserted else {
                return false
            }
            order.append(id)
            return true
        }

        /// Drops the oldest past the bound.
        mutating func trim() {
            while order.count > SpoolSession.maxClaimsPerScope {
                members.remove(order.removeFirst())
            }
        }

        mutating func remove(_ id: SpoolID) {
            guard members.remove(id) != nil else {
                return
            }
            order.removeAll { $0 == id }
        }

        var count: Int { order.count }

        /// Whether `id` is claimed here, delivered or in flight.
        func contains(_ id: SpoolID) -> Bool {
            members.contains(id)
        }
    }

    /// The spool's last word on a subscribed scope: `nil` until its `digest` came on this connection.
    func anchor(_ scope: SpoolID) -> SpoolAnchor? {
        anchors[scope]
    }

    /// Folds a blob the spool just stored for us into its anchor (`ScopeSync.push`), where one exists: before the `sub`
    /// is answered there is nothing to fold into, and inventing one would be a digest the spool never sent.
    mutating func foldPushed(_ scope: SpoolID, blobId: SpoolID) {
        guard var anchor = anchors[scope] else {
            return
        }
        anchor.digest ^= ScopeCrypto.fnv64(blobId.bytes)
        anchor.count = anchor.count < Int.max ? anchor.count + 1 : anchor.count
        anchors[scope] = anchor
    }

    /// Re-anchors a scope after a heal round over the digest its listing ran against (`reanchor`, knit-next #322): a
    /// `digest` that landed while the listing was in flight is newer than it, and is kept. Answers whether it moved.
    mutating func reanchor(_ scope: SpoolID, over listedAgainst: UInt64, to digest: UInt64, count: Int) -> Bool {
        guard var anchor = anchors[scope], anchor.digest == listedAgainst else {
            return false
        }
        anchor.digest = digest
        anchor.count = count
        anchors[scope] = anchor
        return true
    }

    /// Claims `blobId` for delivery on this connection (`claim`): `false` when it was handled here already, or the scope
    /// is not subscribed. A pull and an `event` that race deliver one blob once.
    mutating func claim(_ scope: SpoolID, blobId: SpoolID) -> Bool {
        guard isSubscribed(scope) else {
            return false
        }
        return claims[scope, default: ClaimSet()].insert(blobId)
    }

    /// Gives a claim back (`release`): a blob that failed its checks off the event path may come again by a pull.
    mutating func release(_ scope: SpoolID, blobId: SpoolID) {
        claims[scope]?.remove(blobId)
    }

    /// Whether `blobId` is claimed on this connection (`acceptedFor`): the heal loop's "processed", which it never pulls
    /// again on this connection.
    func hasClaimed(_ scope: SpoolID, blobId: SpoolID) -> Bool {
        claims[scope]?.contains(blobId) == true
    }

    /// How many ids `scope` has claimed on this connection, delivered and in flight.
    func claimCount(_ scope: SpoolID) -> Int {
        claims[scope]?.count ?? 0
    }

    /// Holds a scope's claims to ``maxClaimsPerScope`` after a delivery (`settle`), the oldest going first.
    mutating func settle(_ scope: SpoolID) {
        claims[scope]?.trim()
    }

    /// How many entries the per-connection books hold, each pull's named and oversize ids and each waiting `sub`'s scopes
    /// counted, for the tests that flood a session.
    var bookSize: Int {
        let requests = pending.values.reduce(0) { $0 + 1 + $1.unserved.count + $1.oversize.count }
        let subs = subsInFlight.values.reduce(0) { $0 + $1.waiting.count }
        return requests + subs + subscriptions.count + anchors.count + claims.values.reduce(0) { $0 + $1.count }
    }
}
