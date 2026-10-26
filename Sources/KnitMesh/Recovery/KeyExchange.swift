public import KnitWire

/// Recovers a missing sender's key, its profile, hop by hop (`KeyExchange.kt`).
///
/// A profile floods once, so a node that joined late can miss it and then drop everything its sender floods.
/// Such a node asks its neighbours with a signed, point-to-point `keyreq`. A neighbour holding the profile serves
/// its cached signed frame verbatim; one that does not remembers who asked, asks its own neighbours, and passes
/// the profile back once it arrives. The profile self-certifies on pin, so the answer needs no signature of its
/// own.
///
/// The cache is the hot layer over the pin store, which keeps the signed frame each pin came from (knit-next ADR
/// 2026-09.g64k). A carrier must still prove the key of anyone whose frames it serves after a restart has emptied
/// the cache and custody has lost their profile to the quota or the TTL. ``serveKey(_:)`` is the other door onto
/// it: a digest reply sends a key ahead of a backlog its reader could not otherwise verify.
///
/// Every key here is an unauthenticated sender id, so everything is bounded: 256 wanted ids and 256 relayed
/// wants, oldest first, a 30-second cooldown per id, and 128 ids per request each way. What a neighbour is served,
/// on request or when a key it waited for pins, draws on its byte budget (``KeyAnswerBudget``, ADR 2026-10.f5zs);
/// a digest round's keys ahead (``serveKey(_:)``) are that round's to bound. This type is bookkeeping only: the
/// engine builds, signs and sends the requests it asks for. Times are on the monotonic clock.
public struct KeyExchange: Sendable {
    /// The shortest gap between two broadcast requests for one id (`REQUEST_COOLDOWN_MS`).
    public static let requestCooldownMilliseconds: Int64 = 30_000
    /// A want nobody refreshed ages out after this (`MISSING_TTL_MS`).
    public static let missingMilliseconds: Int64 = 1_800_000
    /// The most ids wanted at once (`MAX_MISSING`).
    public static let maxMissing = 256
    /// The most ids relayed for other nodes at once (`MAX_WANTERS`).
    public static let maxWanters = 256
    /// The most ids in one request we send (`MAX_IDS_PER_REQ`).
    public static let maxIdsPerRequest = 128
    /// The most ids read from one request we receive (`MAX_REQUEST_IDS`).
    public static let maxRequestIds = 128
    /// The profile bytes a neighbour may be served in a burst (ADR 2026-10.f5zs); Android has no such bound.
    public static let answerBurstBytes = Int(KeyAnswerBudget.burstBytes)
    /// The bytes a second a neighbour's answer budget refills by.
    public static let answerRefillBytesPerSecond = Int(KeyAnswerBudget.refillBytesPerSecond)
    /// The most neighbours whose answer budgets are remembered.
    public static let maxAnswerPeers = KeyAnswerBudget.maxPeers

    /// What an inbound request asks of the engine.
    public struct Answer: Sendable, Equatable {
        /// Cached profiles to send back to the requester, already in their `relay = false` wrapper.
        public var serve: [WireEnvelope] = []
        /// Ids to ask every neighbour for now.
        public var ask: [NodeId] = []
        /// Held ids not served, the requester over its budget: neither wanted nor asked on, since we hold them.
        public var skipped = 0
        /// Held ids not served because their profile already crossed the requester's link, so the link would not write it
        /// again: neither charged, wanted nor asked on. Counted apart from ``skipped``, and only here.
        public var crossed = 0
    }

    /// Every pinned peer's verbatim signed profile, to serve on request: each one pinned since launch, and each one
    /// read from the pin store since. Unbounded: each entry cost a self-certifying pin.
    private var cache: [NodeId: WireEnvelope] = [:]
    /// The pin store's copy of a pinned peer's signed profile, read on a cache miss only.
    private let storedProfile: @Sendable (NodeId) -> WireEnvelope?
    /// Wanted ids, oldest first, each with when it was last broadcast.
    private var missing: [(id: NodeId, askedAt: Int64)] = []
    /// Ids we are fetching for neighbours, oldest first, each with the neighbours waiting.
    private var wanters: [(id: NodeId, neighbors: Set<NodeId>)] = []
    /// What each neighbour may still be served.
    private var answerBudget = KeyAnswerBudget()

    /// Profiles held but not served, their asker over its budget, on request and at pin time: a count only.
    public private(set) var skippedAnswers = 0

    /// An empty exchange over `storedProfile`, the pin store's signed profiles. The default holds none.
    @preconcurrency
    public init(storedProfile: @escaping @Sendable (NodeId) -> WireEnvelope? = { _ in nil }) {
        self.storedProfile = storedProfile
    }

    /// The ids still wanted, oldest first.
    public var missingIds: [NodeId] { missing.map(\.id) }

    /// The signed profiles cached.
    public var cachedProfileCount: Int { cache.count }

    /// The cached signed profile of `nodeId`, if pinned.
    public func cachedProfile(of nodeId: NodeId) -> WireEnvelope? {
        cache[nodeId]
    }

    /// We dropped a frame from `nodeId` for want of its key. Remembers it, and answers whether to ask every
    /// neighbour now: not for ourselves, not for a key we hold, and not again inside the cooldown.
    public mutating func want(_ nodeId: NodeId, me: NodeId, now: Int64) -> Bool {
        guard nodeId != me, cache[nodeId] == nil else {
            return false
        }
        if let index = missing.firstIndex(where: { $0.id == nodeId }) {
            guard now - missing[index].askedAt >= Self.requestCooldownMilliseconds else {
                return false
            }
            missing[index].askedAt = now
            return true
        }
        missing.append((nodeId, now))
        if missing.count > Self.maxMissing {
            missing.removeFirst()
        }
        return true
    }

    /// A neighbour asked us for `ids`: serve what we hold, and for the rest remember the neighbour and ask on its
    /// behalf. Our own id is skipped, and so is anything past ``maxRequestIds`` or not a node id. Each profile served is
    /// charged to `requester`, the link peer's HELLO id and never the request's signer, on a budget remembered for
    /// ``maxAnswerPeers`` peers. A held one past it is skipped, neither wanted nor asked on. The asker still wants the key,
    /// so it asks again on its own schedule: this port at its next dropped frame from that sender past the cooldown, at
    /// link-up, at the 60 s re-offer and at the heal; Android at the dropped frame, at link-up (`onNeighborAdded`) and at
    /// its 15-minute heal's `retryMissing` (`MeshManager.kt:1320` at knit-next `e63f15f4`).
    ///
    /// A held profile whose `FrameKey` `crossed` says already crossed the requester's link is neither sent nor charged,
    /// as a digest round skips one (``CustodySync``): the link would not write it twice inside its window
    /// (`LinkManager.send`), so charging it would spend an honest asker's budget on bytes that never go.
    public mutating func onRequest(
        _ ids: [String], from requester: NodeId, me: NodeId, now: Int64, crossed: (String) -> Bool = { _ in false }
    ) -> Answer {
        var answer = Answer()
        for id in ids.prefix(Self.maxRequestIds).compactMap(NodeId.init) where id != me {
            if let profile = serveKey(id) {
                if let key = FrameKey.ofSigned(profile), crossed(key) {
                    answer.crossed += 1
                } else if answerBudget.charge(profile.encoded.count, to: requester, now: now) {
                    answer.serve.append(profile)
                } else {
                    answer.skipped += 1
                    skippedAnswers += 1
                }
                continue
            }
            addWanter(requester, for: id)
            if want(id, me: me, now: now) {
                answer.ask.append(id)
            }
        }
        return answer
    }

    /// The key of `nodeId`, its signed profile in the point-to-point wrapper it is served in, if we hold one: the
    /// cache, else the pin store, cached on the way out (`KeyExchange.serveKey` and `profileFor`).
    public mutating func serveKey(_ nodeId: NodeId) -> WireEnvelope? {
        if let held = cache[nodeId] {
            return Self.served(held)
        }
        guard let kept = storedProfile(nodeId) else {
            return nil
        }
        cache[nodeId] = kept
        return Self.served(kept)
    }

    /// A profile for `nodeId` pinned, delivered as `wire`: caches it, stops wanting it, and answers the
    /// neighbours that asked us for it, to serve now. Each is charged the served profile on its own budget, keyed on its
    /// HELLO id, and one past it is dropped unserved. It still wants the key, so it asks again as ``onRequest(_:from:me:now:)``
    /// says, and we hold the key then. A wanter whose link `crossed` says already carried the profile, by its `FrameKey`, is
    /// neither served nor charged, and not counted as skipped.
    public mutating func onProfilePinned(
        _ nodeId: NodeId, wire: WireEnvelope, now: Int64, crossed: (String, NodeId) -> Bool = { _, _ in false }
    ) -> Set<NodeId> {
        cache[nodeId] = wire
        missing.removeAll { $0.id == nodeId }
        guard let index = wanters.firstIndex(where: { $0.id == nodeId }) else {
            return []
        }
        let bytes = Self.served(wire).encoded.count
        let key = FrameKey.ofSigned(wire)
        let waiting = wanters.remove(at: index).neighbors.filter { neighbor in !(key.map { crossed($0, neighbor) } ?? false) }
        // In id order, so which buckets the LRU keeps never rests on a set's hash seed.
        let admitted = Set(waiting.sorted().filter { answerBudget.charge(bytes, to: $0, now: now) })
        skippedAnswers += waiting.count - admitted.count
        return admitted
    }

    /// Drops wants nobody refreshed for ``missingMilliseconds``. Hygiene only: the caps are the bound.
    @discardableResult
    public mutating func sweep(now: Int64) -> Int {
        let before = missing.count
        missing.removeAll { now - $0.askedAt > Self.missingMilliseconds }
        return before - missing.count
    }

    /// `ids` in requests of at most ``maxIdsPerRequest``, so no request can outgrow a link record.
    public static func chunked(_ ids: [NodeId]) -> [[NodeId]] {
        stride(from: 0, to: ids.count, by: maxIdsPerRequest).map { Array(ids[$0..<min($0 + maxIdsPerRequest, ids.count)]) }
    }

    /// A cached profile in the point-to-point wrapper it is served in, its signed bytes untouched.
    public static func served(_ profile: WireEnvelope) -> WireEnvelope {
        WireEnvelope(relay: false, sig: profile.sig, signed: profile.signed)
    }

    private mutating func addWanter(_ neighbor: NodeId, for id: NodeId) {
        if let index = wanters.firstIndex(where: { $0.id == id }) {
            wanters[index].neighbors.insert(neighbor)
            return
        }
        wanters.append((id, [neighbor]))
        if wanters.count > Self.maxWanters {
            wanters.removeFirst()
        }
    }
}
