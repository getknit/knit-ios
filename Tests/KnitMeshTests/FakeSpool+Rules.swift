import KnitCrypto
import KnitWire

@testable import KnitMesh

extension FakeSpool {
    // MARK: Rules

    /// Sheds `scope` as a full spool does: its blobs and tombstones go, and every subscriber hears a digest of 0.
    func shed(_ scope: SpoolID) {
        scopes[scope]?.live.removeAll()
        scopes[scope]?.tombstones.removeAll()
        broadcastDigest(scope)
    }

    func serve(_ blob: SpoolBlob, _ connection: Connection) {
        servedBytes += blob.data.count
        emit(.record(blob.encoded), to: connection)
    }

    /// The scope a request names, once it is subscribed on this connection; `not_subscribed` otherwise (B-7.1-9).
    func subscribed(_ bytes: [UInt8], _ request: Int64, _ connection: Connection) -> SpoolID? {
        guard let scope = SpoolID(bytes), sockets[connection]?.subscribed.contains(scope) == true else {
            emit(SpoolErr(code: SpoolErrorCode.notSubscribed, request: request, scope: bytes), to: connection)
            return nil
        }
        return scope
    }

    /// Whether a stamp is wanted and missing or wrong: only for a scope the spool does not hold (S-6.4-2).
    func powRefused(_ scope: SpoolID, _ stamp: PowStamp?) -> Bool {
        guard powBits > 0, scopes[scope] == nil else {
            return false
        }
        guard let stamp else {
            return true
        }
        return !SpoolPow.verify(scopeId: scope.bytes, day: stamp.day, n: stamp.counter, bits: powBits)
    }

    /// The most recent declaration clamped to the hello's caps (S-6.2-2).
    func applied(_ declared: ScopeBounds) -> ScopeBounds {
        ScopeBounds(
            maxFrames: min(declared.maxFrames, limits.maxFramesCap),
            ttlMs: min(declared.ttlMs, limits.maxTtlMs),
            maxBlob: min(declared.maxBlob, limits.maxBlob)
        )
    }

    /// Ages out what is past its `ttlMs` on the spool's clock, live and tombstoned, on the daemon's edges: a blob once
    /// `arrivedAt + ttlMs < now`, a tombstone once its expiry `< now` (knit-spool `InMemoryScopeStore.sweepScope`,
    /// `:418-430`, at `a682524`). Answers whether the live set moved.
    func expire(_ scope: SpoolID) -> Bool {
        guard var state = scopes[scope] else {
            return false
        }
        let ttl = state.bounds.ttlMs
        let gone = state.live.filter { $0.arrivedAt + ttl < now }
        state.live.removeAll { $0.arrivedAt + ttl < now }
        state.tombstones.removeAll { $0.expiresAt < now }
        state.tombstones += gone.map { ($0.id, now + ttl) }
        scopes[scope] = state
        trimTombstones(scope)
        return !gone.isEmpty
    }

    /// Evicts the oldest past `maxFrames` into the tombstones. Answers whether any went.
    func evict(_ scope: SpoolID) -> Bool {
        guard var state = scopes[scope], state.live.count > state.bounds.maxFrames else {
            return false
        }
        let over = state.live.count - max(state.bounds.maxFrames, 0)
        state.tombstones += state.live.prefix(over).map { ($0.id, now + state.bounds.ttlMs) }
        state.live.removeFirst(over)
        scopes[scope] = state
        trimTombstones(scope)
        return true
    }

    func trimTombstones(_ scope: SpoolID) {
        guard let state = scopes[scope] else {
            return
        }
        let bound = max(2 * state.bounds.maxFrames, 1024)
        if state.tombstones.count > bound {
            scopes[scope]?.tombstones.removeFirst(state.tombstones.count - bound)
        }
    }

    func digest(_ scope: SpoolID) -> SpoolDigest {
        let state = scopes[scope] ?? Scope(bounds: applied(ScopeBounds(maxFrames: 400, ttlMs: 172_800_000, maxBlob: 65_536)))
        return SpoolDigest(
            scope: scope.bytes,
            digest: ScopeCrypto.digestBytes(ScopeCrypto.digest(of: state.live.map(\.id.bytes))),
            count: state.live.count,
            full: state.live.count >= state.bounds.maxFrames,
            bounds: state.bounds
        )
    }

    func broadcastDigest(_ scope: SpoolID) {
        let record = digest(scope).encoded
        for (connection, socket) in sockets where socket.open && socket.subscribed.contains(scope) {
            emit(.record(record), to: connection)
        }
    }

    func emit(_ err: SpoolErr, to connection: Connection) {
        emit(.record(err.encoded), to: connection)
    }

    func emit(_ outgoing: Outgoing, to connection: Connection) {
        guard sockets[connection]?.open == true else {
            return
        }
        sockets[connection]?.outbox.append(outgoing)
    }
}
