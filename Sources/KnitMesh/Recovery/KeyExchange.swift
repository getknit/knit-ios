public import KnitWire

/// Recovers a missing sender's key, its profile, hop by hop (`KeyExchange.kt`).
///
/// A profile floods once, so a node that joined late can miss it and then drop everything its sender floods.
/// Such a node asks its neighbours with a signed, point-to-point `keyreq`. A neighbour holding the profile serves
/// its cached signed frame verbatim; one that does not remembers who asked, asks its own neighbours, and passes
/// the profile back once it arrives. The profile self-certifies on pin, so the answer needs no signature of its
/// own.
///
/// Every key here is an unauthenticated sender id, so everything is bounded: 256 wanted ids and 256 relayed
/// wants, oldest first, a 30-second cooldown per id, and 128 ids per request each way. This type is bookkeeping
/// only: the engine builds, signs and sends the requests it asks for. Times are on the monotonic clock.
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

    /// What an inbound request asks of the engine.
    public struct Answer: Sendable, Equatable {
        /// Cached profiles to send back to the requester, already in their `relay = false` wrapper.
        public var serve: [WireEnvelope] = []
        /// Ids to ask every neighbour for now.
        public var ask: [NodeId] = []
    }

    /// Every pinned peer's verbatim signed profile, to serve on request. Unbounded: each entry cost a
    /// self-certifying pin.
    private var cache: [NodeId: WireEnvelope] = [:]
    /// Wanted ids, oldest first, each with when it was last broadcast.
    private var missing: [(id: NodeId, askedAt: Int64)] = []
    /// Ids we are fetching for neighbours, oldest first, each with the neighbours waiting.
    private var wanters: [(id: NodeId, neighbors: Set<NodeId>)] = []

    /// An empty exchange.
    public init() {
        // Nothing to set up.
    }

    /// The ids still wanted, oldest first.
    public var missingIds: [NodeId] { missing.map(\.id) }

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
    /// behalf. Our own id is skipped, and so is anything past ``maxRequestIds`` or not a node id.
    public mutating func onRequest(_ ids: [String], from requester: NodeId, me: NodeId, now: Int64) -> Answer {
        var answer = Answer()
        for id in ids.prefix(Self.maxRequestIds).compactMap(NodeId.init) where id != me {
            if let profile = cache[id] {
                answer.serve.append(Self.served(profile))
                continue
            }
            addWanter(requester, for: id)
            if want(id, me: me, now: now) {
                answer.ask.append(id)
            }
        }
        return answer
    }

    /// A profile for `nodeId` pinned, delivered as `wire`: caches it, stops wanting it, and answers the
    /// neighbours that asked us for it, to serve now.
    public mutating func onProfilePinned(_ nodeId: NodeId, wire: WireEnvelope) -> Set<NodeId> {
        cache[nodeId] = wire
        missing.removeAll { $0.id == nodeId }
        guard let index = wanters.firstIndex(where: { $0.id == nodeId }) else {
            return []
        }
        return wanters.remove(at: index).neighbors
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
