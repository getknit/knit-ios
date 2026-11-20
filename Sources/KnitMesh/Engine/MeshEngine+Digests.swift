import KnitStore
public import KnitWire

/// The digest exchange's answer (`ForwardSync.onDigest`, the `custody-carry-policy` contract, §1 to §3 and §6): paced rounds
/// of what a neighbour's digest omits, the carry ledger the digests and rounds feed, and the custody writes that feed it.
/// What a round picks is ``CustodySync``'s, the answers' pace ``CustodyAnswers``', and the ledger ``CarryLedger``'s; this is
/// their wiring.
extension MeshEngine {
    /// What the paced answers, the memo and the re-offer back-off did so far, under Android's names (`MeshMetrics`).
    public var custodyRoundCounts: CustodyRoundCounts { custodyRounds }

    /// A neighbour's custody digest arrived (`ForwardSync.onDigest`). A proven link's digest judges its memo and counts its
    /// holders first (§6, then §3); then the answer to it opens, its first round cut now, or the answer under way takes the
    /// newer digest and keeps its pace. An unproven link is answered at the same pace and leaves nothing in the ledger: its
    /// node id is only a claim.
    public func receiveDigest(_ ids: [String], from neighbor: NodeId) {
        // When each one lands shows what a slow link spends on them: every 60 s at most, the whole live id set each way.
        log.log(.debug, "mesh digest from \(neighbor): \(ids.count) ids")
        let now = clock.monotonicMilliseconds()
        let wall = clock.wallMilliseconds()
        // The digest is kept only as the ids we hold, so a digest of junk costs nothing to keep.
        guard let live = custodyLiveIds(now: wall) else {
            // A read that failed would answer nothing held, and every id would read as lacked: the answer stays as it was.
            log.log(.debug, "mesh digest from \(neighbor) dropped: custody could not be read")
            return
        }
        let listed = Set(ids.map(ExactKey.init)).intersection(live)
        if transport.hasProvenLink(to: neighbor) {
            custodyRounds.custodyNotKept += custody.ledger.noteDigest(
                listing: listed, from: neighbor, live: live, now: now, spreadMax: stores.custody.limits.spreadMax)
        }
        if custodyAnswers.receive(listed, from: neighbor, now: now) {
            serveCustodyRound(to: neighbor, now: now)
        }
    }

    /// Our digest at a link-up to `peer`: never held back, and an offer, so the back-off starts over at its base (§7).
    func sendLinkUpDigest(to peer: NodeId) {
        transport.sendDigest(stores.custody.liveIds(now: clock.wallMilliseconds()), to: peer)
        reoffers.linkedUp(peer, now: clock.monotonicMilliseconds())
    }

    /// `peer`'s link went: its answer ends, and the next link's digest says what it lacks then; its memo goes, pending and
    /// not kept alike, since a release may have died with the link, and so do its uncredited hand-offs and its pace.
    func custodyLinkDown(_ peer: NodeId) {
        endAnswer(to: peer, now: clock.monotonicMilliseconds())
        custody.ledger.linkDown(peer)
        reoffers.linkDown(peer)
    }

    /// Cuts each answer's round that is due, credits the hand-offs due, ends each answer that aged out, and keeps the ledger
    /// within custody's row cap.
    func serveCustodyRounds(now: Int64) {
        if custody.ledger.count > stores.custody.limits.maxFrames {
            pruneCarryLedger()
        }
        custody.ledger.credit(now: now, spreadMax: stores.custody.limits.spreadMax)
        // By peer, never over a copy of the answers, whose sets a round's write would then copy whole.
        for timing in custodyAnswers.timings {
            if CustodyAnswers.isAged(arrivedAt: timing.arrivedAt, now: now) {
                endAnswer(to: timing.peer, now: now)
            } else if timing.due <= now {
                serveCustodyRound(to: timing.peer, now: now)
            }
        }
    }

    /// Cuts `peer`'s round now, fresh from the store, so a DM that arrived mid-answer goes next: keys, then frames, each
    /// point to point, as a key request's answer goes, so it is never flooded (knit-next ADR 2026-09.7bu7). A round that finds
    /// nothing ends the answer; one due while the link holds a round unwritten waits for the line (``HeldDigests``).
    func serveCustodyRound(to peer: NodeId, now: Int64) {
        guard transport.isLinked(peer) else {
            custodyAnswers.end(peer)
            return
        }
        let queued = transport.queuedBytes(to: peer)
        guard queued < HeldDigests.lineBytes else {
            if custodyAnswers.wait(peer, until: now + HeldDigests.recheckMilliseconds) {
                log.log(.debug, "mesh digest from \(peer) waits: \(queued) bytes still queued")
            }
            return
        }
        let proven = transport.hasProvenLink(to: peer)
        // The answer's copy lives only for the cut, so the write after it changes the sets in place.
        let reply = custodyAnswers.answer(for: peer).map { answer in
            custody.round(
                answer,
                memo: proven,
                in: stores.custody,
                now: clock.wallMilliseconds(),
                at: now,
                crossed: { transport.hasCrossed($0, to: peer) },
                key: { keyExchange.serveKey($0) }
            )
        }
        guard let reply else {
            return
        }
        for envelope in reply.loaded {
            custody.ledger.remember(envelope)
        }
        guard !reply.frames.isEmpty else {
            custodyAnswers.end(peer)
            return
        }
        for key in reply.keys {
            transport.send(key, to: peer)
        }
        for wire in reply.frames {
            transport.send(wire, to: peer)
        }
        custodyAnswers.released(reply, to: peer, now: now)
        if proven {
            custody.ledger.released(reply.released, to: peer, now: now, linked: Set(neighborIds))
        }
        custodyRounds.custodyRoundsCut += 1
    }

    /// Ends `peer`'s answer, by its link going or its age: counted cut short when a round cut now would still release
    /// something (``CustodySync/wouldRelease(_:memo:in:now:at:crossed:)``). What is left waits for its next digest.
    func endAnswer(to peer: NodeId, now: Int64) {
        guard let answer = custodyAnswers.answer(for: peer) else {
            return
        }
        custodyAnswers.end(peer)
        let proven = transport.hasProvenLink(to: peer)
        let wall = clock.wallMilliseconds()
        let releasable = custody.wouldRelease(answer, memo: proven, in: stores.custody, now: wall, at: now) { key in
            transport.hasCrossed(key, to: peer)
        }
        if releasable {
            custodyRounds.custodyAnswersCutShort += 1
        }
    }

    // MARK: Custody writes

    /// What a custody write of `frame` did, for the engine's part of the one feed every write passes through (the ledger's
    /// is ``CustodySync``'s): the digest cue re-read when custody changed, and, for a frame that arrived from the neighbour
    /// `source` and is held, that neighbour's answer told not to serve it back and its offer marked as one that drew (§7).
    func noteCustodyWrite(_ result: CustodyStoreResult?, of frame: RelayEnvelope, from source: NodeId?) {
        guard let result else {
            return
        }
        if result.changed {
            noteCustodyChanged()
        }
        if let source, result.held, result.changed {
            custodyAnswers.noteArrived(frame.id, from: source)
            reoffers.kept(from: source)
        }
    }

    /// Takes a frame being delivered into custody, if the carry gate lets it (`isCarriable`). `source` is its hop at first
    /// sight, or `nil` for a parked frame replayed once its key pins, whose hop was judged when it arrived and is not judged
    /// again now; a proven source counts among the frame's holders in its own write (§3).
    func carryDelivered(_ frame: InboundFrame, from source: NodeId?) {
        let envelope = frame.envelope
        let carried = CarriedFrame(envelope: envelope, sig: frame.wire.sig, signed: frame.wire.signed)
        let result = custody.carrying(carried, in: stores.custody, now: clock.wallMilliseconds(), from: source.flatMap(provenSource)) {
            isCarriable(envelope)
        }
        noteCustodyWrite(result, of: envelope, from: source)
    }

    /// The proven peer whose link carried a frame from `neighbor`, the one source the ledger may count (§3), or `nil`.
    func provenSource(_ neighbor: NodeId) -> NodeId? {
        transport.hasProvenLink(to: neighbor) ? neighbor : nil
    }

    /// Keeps the ledger to the ids custody holds, read in a store unit of its own; a read that fails prunes nothing.
    func pruneCarryLedger() {
        guard let live = custodyLiveIds(now: clock.wallMilliseconds()) else {
            return
        }
        custody.ledger.prune(keeping: live)
    }

    /// The live ids custody holds, read in a store unit of its own, or `nil` when the unit failed, which a SQL store would
    /// otherwise answer as nothing held (ADR 2026-09.nyya).
    func custodyLiveIds(now: Int64) -> Set<ExactKey>? {
        let read = stores.transactor.atomically { () -> Set<ExactKey>? in Set(stores.custody.liveIds(now: now).map(ExactKey.init)) }
        guard case .committed(let live) = read else {
            return nil
        }
        return live
    }

    /// Remembers the roster of every live group row, once at the start: rows custody kept before a restart order in the
    /// round's fourth tier until then (§1). The index names the group rows, and only those are loaded.
    func classifyCustody() {
        let wall = clock.wallMilliseconds()
        for entry in stores.custody.liveIndex(now: wall) where entry.groupId != nil {
            if let frame = stores.custody.frame(entry.id, now: wall) {
                custody.ledger.remember(frame.envelope)
            }
        }
    }
}

/// What the paced answers, the memo and the re-offer back-off did (the `custody-carry-policy` contract, §8), each under the
/// key both platforms report it by.
public struct CustodyRoundCounts: Sendable, Equatable {
    /// Rounds released.
    public var custodyRoundsCut = 0
    /// Answers ended by a lost link or by age while a round cut at that moment would still have released something.
    public var custodyAnswersCutShort = 0
    /// Not-kept marks set.
    public var custodyNotKept = 0
    /// Ticks on which a neighbour's digest was held back.
    public var custodyReoffersHeld = 0

    /// Nothing counted yet.
    public init() {
        // All zero.
    }
}
