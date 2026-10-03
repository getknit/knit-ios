import KnitWire

/// Fetches content-addressed blobs one hop at a time (`BlobExchange.kt` in knit-next, ADR 2026-10.nh55).
///
/// A node that wants a blob asks its neighbours with an unsigned, point-to-point `blobreq`. A neighbour holding it
/// serves it back as FILE records. One that lacks it wants it itself, so the asker's next ask finds a holder one hop
/// nearer. That next ask is the 60-second re-ask (`onNeighborAdded`), and nothing is ever pushed to a node that did
/// not just ask, since a holder cannot tell a node still waiting from one whose copy is already on its way from
/// someone else (knit-next ADR 2026-09.4tx5).
///
/// The request is unsigned, so the bookkeeping is bounded: at most 256 blobs wanted, the oldest dropped first and any
/// unrefreshed for 30 minutes swept, and a 45-second serve memo of at most 512 entries. This type keeps the books
/// only: the engine builds and sends the requests, reads the link for files in flight, and serves the files. Times
/// are on the monotonic clock.
internal struct BlobExchange: Sendable {
    /// The most blobs wanted at once (`MAX_FETCHING`), the bound on what unsigned requests can make us fetch.
    static let maxWanted = 256
    /// A want nobody refreshed ages out after this (`FETCH_TTL_MS`), generous because a blob can take minutes.
    static let wantMilliseconds: Int64 = 1_800_000
    /// How long a serve to one neighbour holds off another of the same blob (`SERVE_MEMO_MS`): shorter than the
    /// 60-second re-ask, so a serve lost when its link died is tried again at the next round.
    static let serveMemoMilliseconds: Int64 = 45_000
    /// The most serves remembered at once (`MAX_SERVE_MEMO`). Android's `FALLBACK_MIME` has no twin here: every blob
    /// this port holds was stored with its type.
    static let maxServeMemo = 512

    /// One blob served to one neighbour.
    struct Serve: Hashable {
        var hash: BlobHash
        var peer: NodeId
    }

    /// Wanted blobs, oldest first, each with when it was last wanted.
    private var wants: [(hash: BlobHash, at: Int64)] = []
    /// Recent serves, oldest first.
    private var serves: [(serve: Serve, at: Int64)] = []

    /// The blobs still wanted, oldest first.
    var wanted: [BlobHash] { wants.map(\.hash) }

    /// How many serves are remembered.
    var servedCount: Int { serves.count }

    /// Whether `hash` is wanted.
    func isWanted(_ hash: BlobHash) -> Bool {
        wants.contains { $0.hash == hash }
    }

    /// Wants `hash`, or refreshes the want, and answers whether it is new, so the caller asks every neighbour only once
    /// (`recordFetch`). A full set drops its oldest want.
    mutating func want(_ hash: BlobHash, now: Int64) -> Bool {
        if let index = wants.firstIndex(where: { $0.hash == hash }) {
            // Refreshed in place: the order is when it was first wanted, as in Android's insertion-ordered map.
            wants[index].at = now
            return false
        }
        wants.append((hash, now))
        if wants.count > Self.maxWanted {
            wants.removeFirst(wants.count - Self.maxWanted)
        }
        return true
    }

    /// Stops wanting `hash`: it arrived, or is held some other way.
    mutating func forget(_ hash: BlobHash) {
        wants.removeAll { $0.hash == hash }
    }

    /// Whether to serve `hash` to `peer` now, which stamps the serve (`servedRecently`): not inside the memo of an
    /// earlier serve to that neighbour.
    mutating func shouldServe(_ hash: BlobHash, to peer: NodeId, now: Int64) -> Bool {
        serves.removeAll { now - $0.at >= Self.serveMemoMilliseconds }
        let serve = Serve(hash: hash, peer: peer)
        guard !serves.contains(where: { $0.serve == serve }) else {
            return false
        }
        serves.append((serve, now))
        if serves.count > Self.maxServeMemo {
            serves.removeFirst(serves.count - Self.maxServeMemo)
        }
        return true
    }

    /// Forgets a serve that never went out, so the next ask is served at once (`forgetServed`).
    mutating func forgetServe(_ hash: BlobHash, to peer: NodeId) {
        let serve = Serve(hash: hash, peer: peer)
        serves.removeAll { $0.serve == serve }
    }

    /// Drops wants no one refreshed within ``wantMilliseconds``, and answers how many (`sweepExpired`). The database
    /// re-arms a blob still missing at the next re-ask (knit-next ADR 2026-09.ptv8).
    mutating func sweep(now: Int64) -> Int {
        let before = wants.count
        wants.removeAll { now - $0.at > Self.wantMilliseconds }
        return before - wants.count
    }
}
