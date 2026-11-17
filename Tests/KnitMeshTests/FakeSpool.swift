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

    struct Held {
        let id: SpoolID
        let data: [UInt8]
        let arrivedAt: Int64
    }

    struct Scope {
        var bounds: ScopeBounds
        var live: [Held] = []
        /// Each tombstone and when it expires, `now + ttlMs` at the eviction.
        var tombstones: [(id: SpoolID, expiresAt: Int64)] = []
    }

    struct Socket {
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
    /// The most scopes one `sub` may name; a larger one is refused whole with an unscoped `malformed` carrying its `q`, as
    /// the daemon refuses a batch past its own `maxScopes` (knit-spool `SpoolServer.kt:1622-1628` at `a682524`).
    var subBatchLimit: Int?
    /// Hostile modes: each listing names this many fresh ids it never held; every pulled id is served this many bytes
    /// long, past any `maxBlob`; every served blob has a byte flipped, so it no longer hashes to its id; and every push
    /// is refused `pow`, stamp or not.
    var freshIdsPerListing: Int?
    /// Each listing also names this many fresh blobs of ``junkSize`` bytes that hash to their ids and open to nothing,
    /// served when pulled.
    var freshJunkPerListing: Int?
    var junkSize = 61_440
    var junk: [SpoolID: [UInt8]] = [:]
    var oversizeServes: Int?
    var garblesServes = false
    var refusesEveryPushPow = false
    /// The bytes every `blob` record this spool sent carried.
    var servedBytes = 0
    /// The bytes `blob` records carried, by connection.
    var servedTo: [Connection: Int] = [:]
    /// The bytes of every `push` record clients sent.
    var uploadedBytes = 0
    /// Modes of P4b1's tests: a stored push is acked and then forgotten, with a fresh `digest` to every subscriber, so the
    /// digests churn; and every socket is closed right after the client's `hello`.
    var forgetsAfterPush = false
    var closesAfterHello = false
    /// At each clock step, every socket whose `sub` was answered is closed 1000: a session that ends right after its first
    /// round.
    var closesAfterRound = false
    private var minted = 0
    /// How many of the next pushes are refused `rate`, and the `retryMs` they carry.
    var ratedPushes = 0
    var rateRetryMs: Int64?
    private let version: Int
    private let minimum: Int?
    var scopes: [SpoolID: Scope] = [:]
    var sockets: [Connection: Socket] = [:]
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

    /// Moves the clock to `now`, expires what is due, and sends a fresh `digest` for every scope whose live set changed.
    func advance(to now: Int64) {
        self.now = now
        for scope in scopes.keys where expire(scope) {
            broadcastDigest(scope)
        }
        if closesAfterRound {
            for (connection, socket) in sockets where socket.open && !socket.subscribed.isEmpty {
                emit(.close(SpoolCloseCode.normal), to: connection)
                sockets[connection]?.open = false
            }
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
            greet(record, connection)
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
            uploadedBytes += bytes.count
            onPush(push, connection)
        default:
            break
        }
    }

    // MARK: Records

    private func onSub(_ sub: SpoolSub, _ connection: Connection) {
        if let limit = subBatchLimit, sub.subs.count > limit {
            emit(SpoolErr(code: SpoolErrorCode.malformed, request: sub.request), to: connection)
            return
        }
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
        var live = liveIds(scope).map(\.bytes)
        for _ in 0..<(freshIdsPerListing ?? 0) {
            minted += 1
            live.append([0xF5] + withUnsafeBytes(of: UInt64(minted).bigEndian, Array.init) + [UInt8](repeating: 0, count: 23))
        }
        for _ in 0..<(freshJunkPerListing ?? 0) {
            minted += 1
            let data = withUnsafeBytes(of: UInt64(minted).bigEndian, Array.init) + [UInt8](repeating: 0x5A, count: max(junkSize - 8, 0))
            if let id = SpoolID(ScopeCrypto.blobId(of: data)) {
                junk[id] = data
                live.append(id.bytes)
            }
        }
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
            if let size = oversizeServes {
                serve(SpoolBlob(scope: pull.scope, blobId: id, data: [UInt8](repeating: 0xAB, count: size)), connection)
            } else if let blobId = SpoolID(id), let data = junk[blobId] {
                serve(SpoolBlob(scope: pull.scope, blobId: id, data: data), connection)
            } else if let held = scopes[scope]?.live.first(where: { $0.id.bytes == id }) {
                var data = held.data
                if garblesServes, !data.isEmpty {
                    data[data.count - 1] ^= 0x01
                }
                serve(SpoolBlob(scope: pull.scope, blobId: id, data: data), connection)
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
        if let mode = modeRefusal(push) {
            emit(mode, to: connection)
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
        if forgetsAfterPush {
            scopes[scope]?.live.removeAll { $0.id == blobId }
            broadcastDigest(scope)
        } else if evicted || overflowed {
            broadcastDigest(scope)
        }
    }
}

extension FakeSpool {
    /// The refusal a test mode answers `push` with: `pow` every time, or `rate` for the next ``ratedPushes``.
    func modeRefusal(_ push: SpoolPush) -> SpoolErr? {
        if refusesEveryPushPow {
            return SpoolErr(code: SpoolErrorCode.pow, request: push.request, scope: push.scope)
        }
        guard ratedPushes > 0 else {
            return nil
        }
        ratedPushes -= 1
        return SpoolErr(code: SpoolErrorCode.rate, request: push.request, scope: push.scope, retryMs: rateRetryMs)
    }

    /// The client's first record: its `hello`, or a close 4000; and in ``closesAfterHello`` mode, a close right after.
    func greet(_ record: SpoolRecord, _ connection: Connection) {
        guard case .hello = record else {
            emit(.close(SpoolCloseCode.malformed), to: connection)
            sockets[connection]?.open = false
            return
        }
        sockets[connection]?.greeted = true
        if closesAfterHello {
            emit(.close(SpoolCloseCode.goingAway), to: connection)
            sockets[connection]?.open = false
        }
    }

    /// The live ids of `scope`, oldest first.
    func liveIds(_ scope: SpoolID) -> [SpoolID] {
        scopes[scope]?.live.map(\.id) ?? []
    }

    /// The tombstoned ids of `scope`, oldest first.
    func tombstones(_ scope: SpoolID) -> [SpoolID] {
        scopes[scope]?.tombstones.map(\.id) ?? []
    }
}
