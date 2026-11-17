import KnitCrypto
import KnitWire

@testable import KnitMesh

/// An in-process spool for the record layer's tests, the text subset of knit-next's `FakeSpool.kt` at `0832b8462`: the
/// reference daemon's observable v1 answers (`knit-spool` `SpoolServer.kt` at `a682524`) with an injected clock, and none
/// of attachments, the commons, TURN, tickets, casts or sigs.
///
/// It answers its own `hello` first, with the limits and `powBits` it was made with; a `sub` with a `digest` per scope, or
/// a scoped `err` carrying the `sub`'s `q` (`pow` for an unknown scope without a valid stamp, `quota` past
/// ``scopeQuota``, or a refusal a test planted); `list` with the live ids and the tombstones, each left out when empty;
/// `pull` with a `blob` per id it holds, truncated at `maxPull`, then `ok{missing}`; `push` after the size, the hash and
/// the tombstones, a duplicate acked `ok` with no fan-out (S-7.2-7), a new blob fanned out as an `event` to every other
/// subscriber; and `not_subscribed` for a scope operation before its `sub` on the same connection (B-7.1-9). A client
/// record before the client's `hello` closes 4000, as the daemon closes it.
///
/// Retention runs on the spool's own receipt time: a blob expires once `arrivedAt + ttlMs` is past and the oldest goes past
/// `maxFrames`, each into the tombstones, which expire on the same clock and are held to `max(2 × maxFrames, 1024)`
/// (S-6.2-1, S-6.2-7). A change beyond the one blob a push stored sends every subscriber a fresh `digest` (S-7.2-3), so
/// the heal loop's convergence tests see what a real spool does. ``inject(_:into:)`` is the hostile mode: any bytes at all.
final class FakeSpool {
    /// One socket's handle.
    struct Connection: Hashable {
        let number: Int
    }

    /// What the spool did on one connection, in order.
    enum Outgoing: Equatable {
        case record([UInt8])
        case close(Int)
    }

    private struct Held {
        let id: SpoolID
        let data: [UInt8]
        let arrivedAt: Int64
    }

    private struct Scope {
        var bounds: ScopeBounds
        var live: [Held] = []
        /// Each tombstone and when it expires, `now + ttlMs` at the eviction.
        var tombstones: [(id: SpoolID, expiresAt: Int64)] = []
    }

    private struct Socket {
        var greeted = false
        var open = true
        var subscribed: Set<SpoolID> = []
        var outbox: [Outgoing] = []
    }

    /// The spool's clock, in milliseconds; ``advance(to:)`` moves it and expires what is due.
    private(set) var now: Int64
    let limits: SpoolLimits
    let powBits: Int
    /// Scopes this spool will hold at most; a new one past it is refused `quota` (the daemon's store rule).
    var scopeQuota: Int?
    var quotaRetryMs: Int64?
    /// How many of the next pushes are refused `rate`, and the `retryMs` they carry.
    var ratedPushes = 0
    var rateRetryMs: Int64?
    private let version: Int
    private let minimum: Int?
    private var scopes: [SpoolID: Scope] = [:]
    private var sockets: [Connection: Socket] = [:]
    private var planted: [SpoolID: SpoolErr] = [:]
    private var nextConnection = 1
    /// Every blob id a push stored, in order.
    private(set) var stored: [SpoolID] = []

    init(
        limits: SpoolLimits = FakeSpool.defaultLimits, powBits: Int = 0, version: Int = SpoolRecordLayer.version,
        minimum: Int? = nil, now: Int64 = 0
    ) {
        self.limits = limits
        self.powBits = powBits
        self.version = version
        self.minimum = minimum
        self.now = now
    }

    /// The daemon's defaults (§12.2), a week's `maxTtlMs`.
    static let defaultLimits = SpoolLimits(
        maxBlob: 65_536, maxRecord: 65_536 + 512, maxScopes: 64, maxPull: 64, maxFramesCap: 400, maxTtlMs: 604_800_000)

    /// Opens a socket; the spool's `hello` is its first record.
    func connect() -> Connection {
        let connection = Connection(number: nextConnection)
        nextConnection += 1
        sockets[connection] = Socket()
        let hello = SpoolHello(version: version, minimum: minimum, limits: limits, powBits: powBits)
        emit(.record(hello.encoded), to: connection)
        return connection
    }

    /// What the spool sent on `connection` since the last take.
    func take(_ connection: Connection) -> [Outgoing] {
        defer { sockets[connection]?.outbox.removeAll() }
        return sockets[connection]?.outbox ?? []
    }

    /// Whether `connection` is still open.
    func isOpen(_ connection: Connection) -> Bool {
        sockets[connection]?.open == true
    }

    /// The client closed `connection`, or the socket died.
    func drop(_ connection: Connection) {
        sockets[connection]?.open = false
    }

    /// Sends `bytes` on `connection` as they are: the hostile mode.
    func inject(_ bytes: [UInt8], into connection: Connection) {
        emit(.record(bytes), to: connection)
    }

    /// Refuses the next `sub` naming `scope` with `code` (the daemon's `pow` and `quota`), once.
    func refuseSub(_ scope: SpoolID, code: String, retryMs: Int64? = nil) {
        planted[scope] = SpoolErr(code: code, scope: scope.bytes, retryMs: retryMs)
    }

    /// The live ids of `scope`, oldest first.
    func liveIds(_ scope: SpoolID) -> [SpoolID] {
        scopes[scope]?.live.map(\.id) ?? []
    }

    /// The tombstoned ids of `scope`, oldest first.
    func tombstones(_ scope: SpoolID) -> [SpoolID] {
        scopes[scope]?.tombstones.map(\.id) ?? []
    }

    /// Moves the clock to `now`, expires what is due, and sends a fresh `digest` for every scope whose live set changed.
    func advance(to now: Int64) {
        self.now = now
        for scope in scopes.keys where expire(scope) {
            broadcastDigest(scope)
        }
    }

    /// Reads one record a client sent on `connection`.
    func receive(_ bytes: [UInt8], from connection: Connection) {
        guard sockets[connection]?.open == true else {
            return
        }
        guard let record = SpoolRecord(decoding: bytes) else {
            return
        }
        guard sockets[connection]?.greeted == true else {
            if case .hello = record {
                sockets[connection]?.greeted = true
            } else {
                emit(.close(SpoolCloseCode.malformed), to: connection)
                sockets[connection]?.open = false
            }
            return
        }
        switch record {
        case .sub(let sub):
            onSub(sub, connection)
        case .list(let list):
            onList(list, connection)
        case .pull(let pull):
            onPull(pull, connection)
        case .push(let push):
            onPush(push, connection)
        default:
            break
        }
    }

    // MARK: Records

    private func onSub(_ sub: SpoolSub, _ connection: Connection) {
        for entry in sub.subs {
            guard let scope = SpoolID(entry.scope) else {
                continue
            }
            if var refusal = planted.removeValue(forKey: scope) {
                refusal.request = sub.request
                emit(refusal, to: connection)
                continue
            }
            if scopes[scope] == nil, let quota = scopeQuota, scopes.count >= quota {
                emit(SpoolErr(code: SpoolErrorCode.quota, request: sub.request, scope: entry.scope, retryMs: quotaRetryMs), to: connection)
                continue
            }
            if powRefused(scope, entry.pow) {
                emit(SpoolErr(code: SpoolErrorCode.pow, request: sub.request, scope: entry.scope), to: connection)
                continue
            }
            let applied = applied(entry.bounds)
            scopes[scope, default: Scope(bounds: applied)].bounds = applied
            sockets[connection]?.subscribed.insert(scope)
            _ = expire(scope)
            emit(.record(digest(scope).encoded), to: connection)
        }
    }

    private func onList(_ list: SpoolList, _ connection: Connection) {
        guard let scope = subscribed(list.scope, list.request, connection) else {
            return
        }
        _ = expire(scope)
        let live = liveIds(scope).map(\.bytes)
        let tombstones = tombstones(scope).map(\.bytes)
        let answer = SpoolList(
            request: list.request, scope: list.scope, blobIds: live.isEmpty ? nil : live, tombstones: tombstones.isEmpty ? nil : tombstones)
        emit(.record(answer.encoded), to: connection)
    }

    private func onPull(_ pull: SpoolPull, _ connection: Connection) {
        guard let scope = subscribed(pull.scope, pull.request, connection) else {
            return
        }
        _ = expire(scope)
        var missing: [[UInt8]] = []
        for id in pull.blobIds.prefix(limits.maxPull) {
            if let held = scopes[scope]?.live.first(where: { $0.id.bytes == id }) {
                emit(.record(SpoolBlob(scope: pull.scope, blobId: id, data: held.data).encoded), to: connection)
            } else {
                missing.append(id)
            }
        }
        emit(.record(SpoolOk(request: pull.request, missing: missing.isEmpty ? nil : missing).encoded), to: connection)
    }

    private func onPush(_ push: SpoolPush, _ connection: Connection) {
        guard let scope = subscribed(push.scope, push.request, connection), let blobId = SpoolID(push.blobId) else {
            return
        }
        if ratedPushes > 0 {
            ratedPushes -= 1
            emit(SpoolErr(code: SpoolErrorCode.rate, request: push.request, scope: push.scope, retryMs: rateRetryMs), to: connection)
            return
        }
        let evicted = expire(scope)
        // In the daemon's order (`InMemoryScopeStore.push`, `:157-180`): the size before the hash, then the tombstones.
        let refusal: String? =
            if push.data.count > min(limits.maxBlob, scopes[scope]?.bounds.maxBlob ?? 0) {
                SpoolErrorCode.tooLarge
            } else if ScopeCrypto.blobId(of: push.data) != push.blobId {
                SpoolErrorCode.badId
            } else if tombstones(scope).contains(blobId) {
                SpoolErrorCode.tombstoned
            } else {
                nil
            }
        if let refusal {
            emit(SpoolErr(code: refusal, request: push.request, scope: push.scope), to: connection)
            return
        }
        guard !liveIds(scope).contains(blobId) else {
            emit(.record(SpoolOk(request: push.request).encoded), to: connection)
            return
        }
        scopes[scope]?.live.append(Held(id: blobId, data: push.data, arrivedAt: now))
        stored.append(blobId)
        let overflowed = evict(scope)
        emit(.record(SpoolOk(request: push.request).encoded), to: connection)
        let event = SpoolEvent(scope: push.scope, blobId: push.blobId, data: push.data).encoded
        for (other, socket) in sockets where other != connection && socket.open && socket.subscribed.contains(scope) {
            emit(.record(event), to: other)
        }
        if evicted || overflowed {
            broadcastDigest(scope)
        }
    }
}

extension FakeSpool {
    // MARK: Rules

    /// The scope a request names, once it is subscribed on this connection; `not_subscribed` otherwise (B-7.1-9).
    private func subscribed(_ bytes: [UInt8], _ request: Int64, _ connection: Connection) -> SpoolID? {
        guard let scope = SpoolID(bytes), sockets[connection]?.subscribed.contains(scope) == true else {
            emit(SpoolErr(code: SpoolErrorCode.notSubscribed, request: request, scope: bytes), to: connection)
            return nil
        }
        return scope
    }

    /// Whether a stamp is wanted and missing or wrong: only for a scope the spool does not hold (S-6.4-2).
    private func powRefused(_ scope: SpoolID, _ stamp: PowStamp?) -> Bool {
        guard powBits > 0, scopes[scope] == nil else {
            return false
        }
        guard let stamp else {
            return true
        }
        return !SpoolPow.verify(scopeId: scope.bytes, day: stamp.day, n: stamp.counter, bits: powBits)
    }

    /// The most recent declaration clamped to the hello's caps (S-6.2-2).
    private func applied(_ declared: ScopeBounds) -> ScopeBounds {
        ScopeBounds(
            maxFrames: min(declared.maxFrames, limits.maxFramesCap),
            ttlMs: min(declared.ttlMs, limits.maxTtlMs),
            maxBlob: min(declared.maxBlob, limits.maxBlob)
        )
    }

    /// Ages out what is past its `ttlMs` on the spool's clock, live and tombstoned, on the daemon's edges: a blob once
    /// `arrivedAt + ttlMs < now`, a tombstone once its expiry `< now` (knit-spool `InMemoryScopeStore.sweepScope`,
    /// `:418-430`, at `a682524`). Answers whether the live set moved.
    private func expire(_ scope: SpoolID) -> Bool {
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
    private func evict(_ scope: SpoolID) -> Bool {
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

    private func trimTombstones(_ scope: SpoolID) {
        guard let state = scopes[scope] else {
            return
        }
        let bound = max(2 * state.bounds.maxFrames, 1024)
        if state.tombstones.count > bound {
            scopes[scope]?.tombstones.removeFirst(state.tombstones.count - bound)
        }
    }

    private func digest(_ scope: SpoolID) -> SpoolDigest {
        let state = scopes[scope] ?? Scope(bounds: applied(ScopeBounds(maxFrames: 400, ttlMs: 172_800_000, maxBlob: 65_536)))
        return SpoolDigest(
            scope: scope.bytes,
            digest: ScopeCrypto.digestBytes(ScopeCrypto.digest(of: state.live.map(\.id.bytes))),
            count: state.live.count,
            full: state.live.count >= state.bounds.maxFrames,
            bounds: state.bounds
        )
    }

    private func broadcastDigest(_ scope: SpoolID) {
        let record = digest(scope).encoded
        for (connection, socket) in sockets where socket.open && socket.subscribed.contains(scope) {
            emit(.record(record), to: connection)
        }
    }

    private func emit(_ err: SpoolErr, to connection: Connection) {
        emit(.record(err.encoded), to: connection)
    }

    private func emit(_ outgoing: Outgoing, to connection: Connection) {
        guard sockets[connection]?.open == true else {
            return
        }
        sockets[connection]?.outbox.append(outgoing)
    }
}
