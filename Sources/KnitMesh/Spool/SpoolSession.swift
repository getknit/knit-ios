import KnitWire

/// One spool connection's record layer, as a value (`SpoolConnection.kt` in knit-next at `0832b8462`, spec §7.1–7.2,
/// ADR 2026-11.adrq).
///
/// The caller feeds it what happened (the socket opened, a record's bytes, the monotonic clock's `now`, the socket went)
/// and the requests it wants made, and drains what to do: records to send, a close and its code, and events. Nothing here
/// touches a socket, a clock, a log or a store, so the actor and the dialer that drive it in P4 and P5 stay thin, and the
/// hostile cases are table tests.
///
/// It owns what dies with the connection and nothing that outlives it:
/// - **the handshake.** The spool speaks first; we answer `{t:"hello",v:1}` and nothing else (B-7.1-5), or close 4002
///   when its versions leave ours out. Records before its `hello` are dropped, a second `hello` is ignored, and a socket
///   that says nothing for 20 s (`HANDSHAKE_TIMEOUT_MS`) is closed as ``SpoolFault/noHello``. Its limits pass through
///   `SpoolLimits.clamped()` and `powBits` through 0…24 (`SpoolPow.maxBits`).
/// - **requests.** `q` rises per connection. Each `list`, `pull` and `push` has 30 s from its send to a terminal `ok`,
///   `err` or listing (`REQUEST_TIMEOUT_MS`), never stretched by the `blob`s that stream into a pull, and three that go
///   unanswered in a row end the connection as ``SpoolFault/unresponsive`` (`MAX_SILENT_REQUESTS`). A `sub` is no request
///   and strikes nothing: it is answered by a `digest` or a scoped `err` per scope, and a scope its answers leave out
///   within the same 30 s, or that an unscoped `err` with its `q` refuses, is forgotten so the next round subscribes it
///   again (see `SpoolSession+Subscriptions`).
/// - **the subscribed set,** and what it gates: a `digest`, `event`, `blob` or uncorrelated scoped `err` for a scope not
///   subscribed on this connection is dropped before anything reads it, so the maps below are bounded by what we
///   subscribed. A scope or blob id that is not 32 bytes, or a digest that is not 8, is a fault of that record alone.
/// - **pull correlation.** A `blob` carries no `q`, so it is taken only for an outstanding pull that named its id, once
///   per named id (`Pending.claimBlob`), and an `ok`'s `missing` is held to the ids the pull named and was not served.
/// - **the anchors** (each subscribed scope's last digest and count) and **the claims** (the ids handled on this
///   connection, 512 a scope, so a pull racing an `event` delivers one blob once).
///
/// The accounted, invalid and unpushable sets, a scope's park and its stamps outlive a connection, so they are the heal
/// loop's (P3b), never this type's.
///
/// It reads only what answers it: a `digest` or `event` for a scope subscribed on this connection, records after the
/// spool's `hello`, and an `err` that names the scope of the request its `q` names (ADR 2026-11.adrq, P3a).
internal struct SpoolSession: Sendable {
    /// How long the spool has to send its `hello` (`HANDSHAKE_TIMEOUT_MS`).
    static let handshakeMilliseconds: Int64 = 20_000
    /// How long a request waits for its terminal answer (`REQUEST_TIMEOUT_MS`).
    static let requestMilliseconds: Int64 = 30_000
    /// Unanswered requests in a row that end the connection (`MAX_SILENT_REQUESTS`).
    static let maxSilentRequests = 3
    /// The ids remembered as handled per scope on one connection (`BLOB_SET_MAX`).
    static let maxClaimsPerScope = 512
    /// The longest a `rate` refusal is waited out (`MAX_RATE_WAIT_MS`).
    static let maxRateWaitMilliseconds: Int64 = 5000
    /// A refused scope's park, floor and cap (`MIN_REFUSAL_PARK_MS`, `MAX_REFUSAL_PARK_MS`, §12.2).
    static let minParkMilliseconds: Int64 = 300_000
    static let maxParkMilliseconds: Int64 = 3_600_000

    /// Where the connection stands.
    enum Phase: Sendable {
        /// The socket is open and the spool has not said `hello`.
        case awaitingHello
        /// The hello exchange finished.
        case ready
        /// Either side ended it.
        case closed
    }

    /// One outstanding request (`SpoolConnection.Pending`).
    struct Pending: Sendable {
        enum Kind: Sendable {
            case list
            case pull
            case push
        }

        let kind: Kind
        let scope: SpoolID
        /// The send plus 30 s; nothing moves it.
        let deadline: Int64
        /// The ids a pull named and the spool has not yet served: drained by each `blob`, so its first size bounds them.
        var unserved: Set<SpoolID> = []
        /// Named ids served past the declared `maxBlob`.
        var oversize: [SpoolID] = []
    }

    /// A `sub` the spool has not finished answering: the scopes still waiting for their `digest` or scoped `err`, and the
    /// send plus 30 s.
    struct SubInFlight: Sendable {
        var waiting: Set<SpoolID>
        let deadline: Int64
    }

    private(set) var phase = Phase.awaitingHello
    /// The spool's limits, clamped, once it has said `hello`; `nil` when it advertised none.
    private(set) var limits: SpoolLimits?
    /// The spool's proof-of-work difficulty, 0 to 24.
    private(set) var powBits = 0
    /// Why this side ended the connection, or `nil`.
    private(set) var fault: SpoolFault?
    /// Whether the spool has answered a request here (`SpoolConnection.answered`), which a `digest` never counts as.
    private(set) var hasAnswered = false

    private let helloDeadline: Int64
    private(set) var nextRequest: Int64 = 1
    private var silent = 0
    var pending: [Int64: Pending] = [:]
    /// Each subscribed scope and the bounds this side declared for it: the one `maxBlob` the spool did not choose.
    private(set) var subscriptions: [SpoolID: ScopeBounds] = [:]
    var anchors: [SpoolID: SpoolAnchor] = [:]
    var claims: [SpoolID: ClaimSet] = [:]
    var subsInFlight: [Int64: SubInFlight] = [:]
    private var outbox: [SpoolSessionOutput] = []

    /// A session for a socket that opened at `now`, on the monotonic clock.
    init(openedAt now: Int64) {
        helloDeadline = Self.later(now, by: Self.handshakeMilliseconds)
    }

    /// Whether the hello exchange finished on a connection still open (`SpoolConnection.isReady`).
    var isReady: Bool { phase == .ready }

    /// Everything to do since the last drain, in order.
    mutating func drain() -> [SpoolSessionOutput] {
        defer { outbox.removeAll() }
        return outbox
    }

    /// When ``tick(now:)`` next has something to do: the handshake's deadline, or the earliest request's or `sub`'s.
    var nextDeadline: Int64? {
        switch phase {
        case .awaitingHello:
            helloDeadline
        case .ready:
            (pending.values.map(\.deadline) + subsInFlight.values.map(\.deadline)).min()
        case .closed:
            nil
        }
    }

    /// Runs the timers due at `now`: a handshake that never finished, `sub`s and requests that went unanswered.
    mutating func tick(now: Int64) {
        switch phase {
        case .awaitingHello where now >= helloDeadline:
            end(.noHello)
        case .ready:
            lapseSubs(now: now)
            for request in pending.keys.sorted() where phase == .ready {
                guard let entry = pending[request], now >= entry.deadline else {
                    continue
                }
                pending[request] = nil
                emit(.answered(request: request, .unanswered))
                silent += 1
                if silent >= Self.maxSilentRequests {
                    end(.unresponsive)
                }
            }
        default:
            break
        }
    }

    /// The socket is gone, whoever closed it (`onClosed`): every request fails and every per-connection set goes.
    mutating func socketClosed() {
        guard phase != .closed else {
            return
        }
        phase = .closed
        for request in pending.keys.sorted() {
            emit(.answered(request: request, .closed))
        }
        pending.removeAll()
        subsInFlight.removeAll()
        subscriptions.removeAll()
        anchors.removeAll()
        claims.removeAll()
        emit(.ended(fault: fault))
    }

    /// Ends the connection for a reason of our own (`abort`): a close with 1000, then the teardown.
    mutating func end(_ reason: SpoolFault) {
        end(reason, code: SpoolCloseCode.normal)
    }

    /// Ends the connection for a reason of our own with close `code`, then the teardown.
    mutating func end(_ reason: SpoolFault, code: Int) {
        guard phase != .closed else {
            return
        }
        fault = reason
        outbox.append(.close(code: code))
        socketClosed()
    }

    // MARK: Requests

    /// Forgets every subscription not in `live`, with its anchor and claims (`retainSubscriptions`). There is no `unsub`;
    /// a scope that comes back is subscribed again and answered with a fresh `digest`.
    mutating func retainSubscriptions(_ live: Set<SpoolID>) {
        for scope in subscriptions.keys where !live.contains(scope) {
            forget(scope)
        }
    }

    /// Whether `scope` is subscribed on this connection.
    func isSubscribed(_ scope: SpoolID) -> Bool {
        subscriptions[scope] != nil
    }

    /// Asks for a subscribed scope's listing. Answers the request's `q`, or `nil` when nothing was sent.
    mutating func list(_ scope: SpoolID, now: Int64) -> Int64? {
        request(.list, scope, now: now) { request in SpoolList(request: request, scope: scope.bytes).encoded }
    }

    /// Pulls `blobIds` from a subscribed scope: at least one, and at most the spool's `maxPull` (the caller batches, C-7.2-6).
    mutating func pull(_ scope: SpoolID, _ blobIds: [SpoolID], now: Int64) -> Int64? {
        let named = Set(blobIds)
        guard !named.isEmpty, named.count <= limits?.maxPull ?? SpoolLimits.maxPullCeiling else {
            return nil
        }
        let request = request(.pull, scope, now: now) { request in
            SpoolPull(request: request, scope: scope.bytes, blobIds: blobIds.map(\.bytes)).encoded
        }
        if let request {
            pending[request]?.unserved = named
        }
        return request
    }

    /// Pushes one sealed blob into a subscribed scope, with a stamp only after the spool asked for one (C-8-4).
    mutating func push(_ scope: SpoolID, blobId: SpoolID, data: [UInt8], pow: PowStamp?, now: Int64) -> Int64? {
        request(.push, scope, now: now) { request in
            SpoolPush(request: request, scope: scope.bytes, blobId: blobId.bytes, data: data, pow: pow).encoded
        }
    }

    private mutating func request(_ kind: Pending.Kind, _ scope: SpoolID, now: Int64, encode: (Int64) -> [UInt8]) -> Int64? {
        guard isReady, isSubscribed(scope) else {
            return nil
        }
        let request = takeRequest()
        guard send(encode(request)) else {
            return nil
        }
        pending[request] = Pending(kind: kind, scope: scope, deadline: Self.later(now, by: Self.requestMilliseconds))
        return request
    }

    mutating func takeRequest() -> Int64 {
        defer { nextRequest += 1 }
        return nextRequest
    }

    // MARK: Plumbing

    /// Queues `bytes` unless they are past the spool's `maxRecord` (`SpoolConnection.send`): never hand a spool a record it
    /// must refuse.
    mutating func send(_ bytes: [UInt8]) -> Bool {
        guard bytes.count <= limits?.maxRecord ?? Int.max else {
            return false
        }
        outbox.append(.send(bytes))
        return true
    }

    mutating func emit(_ event: SpoolSessionEvent) {
        outbox.append(.event(event))
    }

    /// A reply arrived: the silent streak is over (`replied`).
    mutating func replied() {
        silent = 0
        hasAnswered = true
    }

    /// Marks `scope` subscribed with the bounds this side declared for it.
    mutating func subscribed(_ scope: SpoolID, _ bounds: ScopeBounds) {
        subscriptions[scope] = bounds
    }

    /// Drops a subscription and every book kept for it, a `sub` still waiting on it included.
    mutating func forget(_ scope: SpoolID) {
        subscriptions[scope] = nil
        anchors[scope] = nil
        claims[scope] = nil
        subAnswered(scope)
    }

    mutating func negotiated(limits: SpoolLimits?, powBits: Int) {
        self.limits = limits
        self.powBits = powBits
        phase = .ready
    }

    /// `now + milliseconds`, held at `Int64.max` rather than trapping on a clock near the end of its range.
    static func later(_ now: Int64, by milliseconds: Int64) -> Int64 {
        let (sum, overflow) = now.addingReportingOverflow(milliseconds)
        return overflow ? Int64.max : sum
    }
}
