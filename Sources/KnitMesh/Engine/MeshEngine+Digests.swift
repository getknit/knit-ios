public import KnitWire

/// The digest exchange's answer (`ForwardSync.onDigest`): a capped round of what a neighbour's digest omits, sent once its
/// link has room for one (ADR 2026-10.f5zs). What the round picks is ``CustodySync``'s and when it waits is
/// ``HeldDigests``'s; this is their wiring.
extension MeshEngine {
    /// A neighbour's custody digest arrived (`ForwardSync.onDigest`): serve a round of the live frames it lacks, each
    /// sender's key ahead of a backlog the neighbour could not otherwise verify, once its link has room for one.
    public func receiveDigest(_ ids: [String], from neighbor: NodeId) {
        // When each one lands shows what a slow link spends on them: every 60 s, the whole live id set each way.
        log.log(.debug, "mesh digest from \(neighbor): \(ids.count) ids")
        answerDigest(ids, from: neighbor, atLook: false)
    }

    /// Serves the round `ids` leave out, or holds the digest while the link to `neighbor` still holds a round unwritten
    /// (``HeldDigests``, ADR 2026-10.f5zs): the round waits on the link, not on the peer.
    ///
    /// The wait is logged once, when a neighbour's first digest is held: a newer one in its place, and the hold again at
    /// each look, log nothing, so a link that stays full writes one line, not one every 5 s.
    func answerDigest(_ ids: [String], from neighbor: NodeId, atLook: Bool) {
        let queued = transport.queuedBytes(to: neighbor)
        guard queued < HeldDigests.lineBytes else {
            let first = heldDigests.hold(ids, from: neighbor, now: clock.monotonicMilliseconds())
            if first, !atLook {
                log.log(.debug, "mesh digest from \(neighbor) waits: \(queued) bytes still queued")
            }
            return
        }
        // This digest is newer than any held: answering it answers that one too.
        heldDigests.drop(neighbor)
        let reply = custody.missing(
            from: ids,
            for: neighbor,
            in: stores.custody,
            now: clock.wallMilliseconds(),
            crossed: { transport.hasCrossed($0, to: neighbor) },
            key: { keyExchange.serveKey($0) }
        )
        // Point to point, as a key request's answer goes, so it is never flooded (knit-next ADR 2026-09.7bu7). Every key
        // goes ahead of every frame.
        for key in reply.keys {
            transport.send(key, to: neighbor)
        }
        for wire in reply.frames {
            transport.send(wire, to: neighbor)
        }
        if reply.isCapped {
            log.log(.debug, "mesh digest round to \(neighbor) capped: \(reply.frames.count) frames, \(reply.bytes) bytes")
        }
    }

    /// Answers each held digest whose link fell below the line, and holds the rest again for the next look. A link that
    /// went since is forgotten.
    func answerHeldDigests(now: Int64) {
        for held in heldDigests.takeDue(now: now) where transport.isLinked(held.neighbor) {
            answerDigest(held.ids, from: held.neighbor, atLook: true)
        }
    }
}
