import KnitWire

/// The blob holder query, both ends (`BlobExchange.onHaveQuery` and `onHaveAnswer`, knit-next ADR 2026-10.6e5t).
extension MeshEngine {
    /// Whether a holder query or its answer came point to point from the neighbour whose link carried it, the only way
    /// either is taken (`InboundPipeline.kt:316`, `:587`). Neither is signed, so its sender id is a claim, checked here
    /// against the link, and one marked to be relayed is no query of anyone's.
    private func isFromItsLink(_ frame: InboundFrame) -> Bool {
        !frame.wire.relay && NodeId(frame.envelope.senderId) == frame.from
    }

    /// A neighbour asked which of some blobs we hold (`onHaveQuery`, `BlobExchange.kt:744-784`). Each is answered from
    /// reads alone, in the order the bytes move, backwards:
    ///
    /// - **SENDING** when a copy is on the link to it, or was served to it inside the memo, so a `blobreq` now would be
    ///   refused: it should wait. The memo is peeked at, never stamped.
    /// - **HAVE**, with its size, when a `blobreq` now would be served: the serve's own test, which reads the store's
    ///   index and never the bytes.
    /// - **FETCHING** when its bytes are streaming in or landing. Android also reads its store's screening here
    ///   (`storing`); this store takes a file in one step on this actor, so a file is never between the two.
    /// - **NONE** otherwise, a hash that is not one included.
    ///
    /// A query is not an ask: nothing is served, wanted or stamped, and each neighbour's budget bounds an unsigned flood.
    func handleBlobHave(_ frame: InboundFrame) {
        guard isFromItsLink(frame) else {
            return
        }
        guard let query = try? BlobHaveContent(decoding: frame.envelope.payload) else {
            drop(.undecodable, frame.envelope)
            return
        }
        let asked = BlobExchange.answerable(query.hashes)
        guard !asked.isEmpty else {
            return
        }
        let peer = frame.from
        let now = clock.monotonicMilliseconds()
        guard blobExchange.admitQuery(from: peer, now: now) else {
            blobExchange.counts.queriesRefused += 1
            return
        }
        let sending = Set(
            asked.compactMap(BlobHash.init).filter { hash in
                transport.isFileInFlight(hash, to: peer) || blobExchange.memoHolds(hash, for: peer, now: now)
            })
        let arriving = transport.arrivingFileKeys
        let items = asked.map { named -> BlobHasItem in
            guard let hash = BlobHash(named) else {
                return BlobHasItem(hash: named, state: .notHeld)
            }
            if let size = outboundFile(hash, kind: .attachment)?.size {
                return BlobHasItem(hash: named, state: sending.contains(hash) ? .sending : .have, size: Int64(size))
            }
            return BlobHasItem(hash: named, state: arriving.contains(hash) ? .fetching : .notHeld)
        }
        let load = transport.feedingLoad
        let answer = BlobHasContent(items: items, load: load, re: frame.envelope.id)
        transport.send(unsignedPointToPoint(.blobHas, id: newFrameId(), payload: answer.encoded), to: peer)
        blobExchange.counts.queriesAnswered += 1
        let held = items.count { $0.state.isHeld }
        let shown = items.filter { $0.state != .notHeld }.map(BlobExchange.label).joined(separator: ", ")
        let listed = shown.isEmpty ? "" : ": \(shown)"
        let queryId = frame.envelope.id.prefix(BlobExchange.shownIdCharacters)
        log.log(.debug, "mesh blob has → \(peer) #\(queryId) \(held)/\(items.count) held\(listed) load=\(load)")
    }

    /// A neighbour answered a query of ours (`onHaveAnswer`, `BlobExchange.kt:791-808`). The hashes it counted for take
    /// their next step at once, so a late answer still counts.
    func handleBlobHas(_ frame: InboundFrame) {
        guard isFromItsLink(frame) else {
            return
        }
        guard let answer = try? BlobHasContent(decoding: frame.envelope.payload) else {
            drop(.undecodable, frame.envelope)
            return
        }
        let now = clock.monotonicMilliseconds()
        let recorded = blobExchange.recordAnswers(answer, from: frame.from, now: now)
        guard !recorded.touched.isEmpty else {
            return
        }
        let id = answer.re.map { " #\($0.prefix(BlobExchange.shownIdCharacters))" } ?? ""
        let latency = recorded.latency.map { " in \($0) ms" } ?? ""
        let items = recorded.touched.map(BlobExchange.label).joined(separator: ", ")
        log.log(.debug, "mesh blob answer ← \(frame.from)\(id)\(latency): \(items) load=\(answer.load ?? 0)")
        let candidates = blobCandidates()
        var stepped = Set<BlobHash>()
        for hash in recorded.touched.compactMap({ BlobHash($0.hash) }) where stepped.insert(hash).inserted {
            stepBlob(hash, among: candidates, now: now)
        }
        flushBlobQueries()
    }
}
