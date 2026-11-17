import KnitWire

/// The `sub`s of one connection, and what becomes of a scope whose `sub` the spool never finishes answering.
///
/// A scope is subscribed the moment its `sub` is queued (`SpoolConnection.sub`), and each is answered by a `digest` or a
/// scoped `err`. The daemon can also answer a whole `sub` with one `err` that carries its `q` and no scope: `internal` when
/// its store fails (knit-spool `SpoolServer.kt:1562` at `a682524`), or `malformed` for a batch past its own `maxScopes`
/// (`:1622-1628`), which a spool whose hello advertised no limits leaves this side no way to see coming. Kotlin reads that
/// `err` as the connection's and keeps every scope of the batch subscribed with no anchor, so none of them heals until the
/// socket goes. Here such an `err`, or 30 s without an answer, forgets each scope of the batch still waiting without an
/// anchor, and the heal loop subscribes it again on its next round.
extension SpoolSession {
    /// Subscribes `subs` and declares their bounds (`sub`, not awaited). A scope already subscribed here is declared again
    /// (S-6.2-2); a new one takes room under the spool's `maxScopes`, at least one (`ScopeSync.subscribe`), and a batch
    /// names each scope once, since the daemon refuses a repeat as malformed. Answers the scopes sent. A `sub` past the
    /// spool's `maxRecord` ends the connection as ``SpoolFault/tooLarge``: a spool that cannot take it cannot take a blob.
    mutating func subscribe(_ subs: [ScopeSub], now: Int64) -> [SpoolID] {
        guard isReady else {
            return []
        }
        var room = max(limits?.maxScopes ?? Int.max, 1) - subscriptions.count
        var batch: [(SpoolID, ScopeSub)] = []
        var named: Set<SpoolID> = []
        for sub in subs {
            guard let scope = SpoolID(sub.scope), named.insert(scope).inserted else {
                continue
            }
            if !isSubscribed(scope) {
                guard room > 0 else {
                    continue
                }
                room -= 1
            }
            batch.append((scope, sub))
        }
        guard !batch.isEmpty else {
            return []
        }
        let request = takeRequest()
        guard send(SpoolSub(request: request, subs: batch.map(\.1)).encoded) else {
            end(.tooLarge)
            return []
        }
        for (scope, sub) in batch {
            subscribed(scope, sub.bounds)
        }
        subsInFlight[request] = SubInFlight(waiting: Set(batch.map(\.0)), deadline: Self.later(now, by: Self.requestMilliseconds))
        return batch.map(\.0)
    }

    /// `scope` was answered, by its `digest` or by its refusal: no `sub` waits on it any more.
    mutating func subAnswered(_ scope: SpoolID) {
        for request in subsInFlight.keys {
            subsInFlight[request]?.waiting.remove(scope)
        }
        subsInFlight = subsInFlight.filter { !$0.value.waiting.isEmpty }
    }

    /// Whether `request` is a `sub` still waiting on `scope`.
    func subWaits(_ request: Int64, on scope: SpoolID) -> Bool {
        subsInFlight[request]?.waiting.contains(scope) == true
    }

    /// An `err` with a waiting `sub`'s `q` and no scope refused the whole batch: each scope still without an anchor is
    /// forgotten and reported refused, under the spool's code, so the heal loop parks only on `quota` and `pow`.
    mutating func subRefused(_ request: Int64, _ refusal: SpoolRefusal) {
        for scope in settleSub(request) {
            emit(.scopeRefused(scope, refusal))
        }
    }

    /// `sub`s past their 30 s: each scope still waiting without an anchor is forgotten and reported lapsed.
    mutating func lapseSubs(now: Int64) {
        for request in subsInFlight.keys.sorted() where subsInFlight[request].map({ now >= $0.deadline }) == true {
            for scope in settleSub(request) {
                emit(.subscriptionLapsed(scope))
            }
        }
    }

    /// Closes the `sub` `request` and forgets the scopes it leaves with no anchor, in byte order. A scope already anchored
    /// was only declared again, and its earlier answer stands.
    private mutating func settleSub(_ request: Int64) -> [SpoolID] {
        var waiting: Set<SpoolID> = []
        if let sub = subsInFlight.removeValue(forKey: request) {
            waiting = sub.waiting
        }
        let stranded = waiting.filter { anchors[$0] == nil }.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
        for scope in stranded {
            forget(scope)
        }
        return stranded
    }
}
