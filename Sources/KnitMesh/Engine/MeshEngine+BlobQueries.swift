import KnitWire

/// The blob holder query, both ends (`BlobExchange.onHaveQuery` and `onHaveAnswer`, knit-next ADR 2026-10.6e5t), and the
/// progress report a file's receiver sends its sender under the same bit (`onFileProgress` and `onProgressReport`,
/// knit-next ADR 2026-10.nsr7).
extension MeshEngine {
    /// Whether a holder query, its answer or a progress report came point to point from the neighbour whose link carried
    /// it, the only way any is taken (`InboundPipeline.kt:316`, `:587`). None is signed, so its sender id is a claim,
    /// checked here against the link, and one marked to be relayed is no query of anyone's.
    private func isFromItsLink(_ frame: InboundFrame) -> Bool {
        !frame.wire.relay && NodeId(frame.envelope.senderId) == frame.from
    }

    /// A neighbour asked which of some blobs we hold (`onHaveQuery`, `BlobExchange.kt:744-784`). Each is answered from
    /// reads alone, in the order the bytes move, backwards:
    ///
    /// - **SENDING** when a copy is on the link to it, was served to it inside the memo, or its ask is parked behind
    ///   another copy's feed, so a `blobreq` now would be refused or parked: it should wait. The memo is peeked at, never
    ///   stamped. It carries `eta`, when its copy should land (``eta(of:to:now:)``, knit-next ADR 2026-10.nsr7), and
    ///   renews a parked ask.
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
                    || blobExchange.isParked(hash, for: peer)
            })
        let arriving = transport.arrivingFileKeys
        let items = asked.map { named -> BlobHasItem in
            guard let hash = BlobHash(named) else {
                return BlobHasItem(hash: named, state: .notHeld)
            }
            if let size = outboundFile(hash, kind: .attachment)?.size {
                guard sending.contains(hash) else {
                    return BlobHasItem(hash: named, state: .have, size: Int64(size))
                }
                return BlobHasItem(hash: named, state: .sending, size: Int64(size), eta: eta(of: hash, to: peer, now: now))
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

    // MARK: Progress reports

    /// A file streaming in from a neighbour has got this far (`BlobExchange.onFileProgress`): tell its sender how much of
    /// it we hold, so it measures the drain its stack's queue hides from it and times the asks it parked behind the feed
    /// by it. Only to a neighbour that reads one (``readsBlobUpkeep(_:)``).
    public func fileProgress(_ progress: FileProgress) {
        guard readsBlobUpkeep(progress.from) else {
            return
        }
        let report = BlobProgressContent(hash: progress.hash.string, held: progress.held, ms: progress.milliseconds)
        transport.send(unsignedPointToPoint(.blobProgress, id: newFrameId(), payload: report.encoded), to: progress.from)
        blobExchange.counts.progressSent += 1
    }

    /// A neighbour said how much of a file we feed it holds (`BlobExchange.onProgressReport`): the link feeding it clocks
    /// its window by the report (knit-next ADR 2026-10.5buf), and its meter by it, which times the asks parked behind
    /// that feed (knit-next ADR 2026-10.nsr7): they are judged on the next pass. It is taken only from the link's own
    /// peer, as a holder query is, and its sender's key is never asked for.
    func handleBlobProgress(_ frame: InboundFrame) {
        guard isFromItsLink(frame) else {
            return
        }
        guard let report = try? BlobProgressContent(decoding: frame.envelope.payload) else {
            drop(.undecodable, frame.envelope)
            return
        }
        // Android's `plausible`: counts that cannot be negative, and a key no longer than a hash.
        guard report.held >= 0, report.ms >= 0, !report.hash.isEmpty, report.hash.utf16.count <= BlobExchange.maxHashCharacters else {
            return
        }
        blobExchange.counts.progressTaken += 1
        guard let hash = BlobHash(report.hash) else {
            return
        }
        transport.fileProgressReported(from: frame.from, hash: hash, held: report.held, milliseconds: report.ms)
    }

    /// Whether `peer` is sent progress reports and withdrawals (knit-next ADR 2026-10.nsr7): a neighbour whose link
    /// carries ``Capabilities/blobHave``, an iPhone included. An iPhone holder clocks its feed by the reports since ADR
    /// 2026-10.xwjc; Android sends none to an iPhone yet (`BlobExchange.onFileProgress`). An iPhone on a build before ADR
    /// 2026-10.ds45 takes either unsigned type for a signed one, and a build that does not know a type drops it.
    func readsBlobUpkeep(_ peer: NodeId) -> Bool {
        transport.neighbors.first { $0.nodeId == peer }?.capabilities.contains(.blobHave) ?? false
    }

    // MARK: Withdrawals

    /// Withdraws our ask for `hash` from each of `peers` that reads a withdrawal (`withdrawAsk`, knit-next ADR
    /// 2026-10.nsr7): its holder drops a copy it queued for us and has not started.
    func withdrawAsks(_ hash: BlobHash, from peers: [NodeId]) {
        let shown = hash.string.prefix(BlobExchange.shownHashCharacters)
        for peer in peers where readsBlobUpkeep(peer) {
            let content = BlobCancelContent(hash: hash.string)
            transport.send(unsignedPointToPoint(.blobCancel, id: newFrameId(), payload: content.encoded), to: peer)
            blobExchange.counts.cancelsSent += 1
            log.log(.debug, "mesh blob cancel \(shown)… → \(peer)")
        }
    }

    /// A neighbour withdrew its ask for a blob (`BlobExchange.onCancel`): its ask is dropped if it was parked, and a copy
    /// queued for it and not yet streaming comes off its link, and the serve memo forgets it, so a later ask of its own
    /// is served. A copy already streaming goes on. Taken only from the link's own peer, and its sender's key is never
    /// asked for. Every one taken is logged, a withdrawal of nothing queued too, so a device run
    /// can tell one that came too late from one that never came.
    func handleBlobCancel(_ frame: InboundFrame) {
        guard isFromItsLink(frame) else {
            return
        }
        guard let cancel = try? BlobCancelContent(decoding: frame.envelope.payload) else {
            drop(.undecodable, frame.envelope)
            return
        }
        let line = "mesh blob cancel ← \(frame.from) \(cancel.hash.prefix(BlobExchange.shownHashCharacters))…"
        guard let hash = BlobHash(cancel.hash) else {
            log.log(.debug, "\(line): nothing queued")
            return
        }
        let parkedOne = blobExchange.takeParked(hash, for: frame.from)
        let queued = transport.cancelQueuedFile(hash, to: frame.from)
        if queued {
            blobExchange.forgetServe(hash, to: frame.from)
        }
        guard parkedOne || queued else {
            log.log(.debug, "\(line): nothing queued")
            return
        }
        blobExchange.counts.cancelsTaken += 1
        log.log(.debug, "\(line): \(parkedOne ? "parked ask dropped" : "queued copy dropped")")
    }
}
