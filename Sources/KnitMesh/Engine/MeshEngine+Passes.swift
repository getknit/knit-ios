import KnitStore
import KnitWire

/// The engine's periodic passes, which ``MeshEngine/advance()`` fires when each falls due (ADR 2026-09.gq84): the
/// 60-second re-offer, the sweep and the 15-minute heal (`MeshManager`'s `reofferToNeighborsPeriodically`,
/// `sweepExpired` and `heal` in knit-next), and the blob re-arm the re-offer, a start and a link-up run.
extension MeshEngine {
    /// The 60-second re-offer to every linked neighbour (`MeshManager.reofferToNeighborsPeriodically`): the blobs and
    /// keys we still lack, our digest, any ticks owed, and with the ratchet's switch on the group seeds it never acknowledged.
    /// A Bluetooth link stays up, so this is what reconciles custody that drifts after link-up, and what opens a blob's next
    /// cycle, which moves it one hop nearer.
    func reoffer() {
        // First, and whoever is linked: a reset's second re-seal is due by the clock, not by a link (knit-next
        // `MeshManager.kt:2815-2818` at `4f3cd995`, ADR 2026-10.dmgw).
        resealSecondPass()
        let neighbors = neighborIds
        rewantMissingBlobs(sparing: [])
        stepBlobs()
        askForMissingKeys(to: neighbors)
        let ids = stores.custody.liveIds(now: clock.wallMilliseconds())
        for peer in neighbors {
            transport.sendDigest(ids, to: peer)
            sendOwedTicks(to: peer)
            // The group seeds it never acknowledged, floored, with the switch on (`MeshManager.kt:2467`, phase P6b).
            flushPendingGroupKeys(for: peer, force: false)
        }
    }

    /// Expired custody, parked frames, stale key wants, aged-out ticks and reactions left with no message
    /// (`MeshManager.sweepExpired`), then the ratchet frames whose unit failed, opened again from the copies kept.
    func sweep() {
        let now = clock.monotonicMilliseconds()
        if stores.custody.sweepExpired(now: clock.wallMilliseconds()) > 0 {
            noteCustodyChanged()
        }
        releaseDeletedPhotos()
        pruneOrphanReactions()
        pendingInbound.sweep(now: now)
        // Beside the key-wait park, as Android sweeps both (`sweepExpired`, `MeshManager.kt:2333-2334`).
        pendingGroupKeys.sweep(now: now)
        keyExchange.sweep(now: now)
        ackSync.sweep(now: now)
        if blobExchange.sweep(now: now) > 0 {
            syncAcceptedFiles()
        }
        replayFailedRatchetOpens()
    }

    /// The 15-minute heal pass (`MeshManager.heal`): re-ask for missing keys, go over the ticks we owe, rotate our prekey
    /// when due, republish a stale profile, and, with the ratchet's switch on, fan our sealed profile to the sessions that
    /// confirmed since it last went (`broadcastSealedProfile`, `MeshManager.kt:974`, in Kotlin's order after the
    /// republish) and seal again the DMs and group messages a store failure left waiting (phases P5b and P6b).
    func heal() {
        askForMissingKeys(to: neighborIds)
        retryOwedTicks()
        syncPrekey(atStart: false)
        republishIfStale()
        broadcastSealedProfile()
        retryWaitingDirectMessages()
        retryWaitingGroupMessages()
    }

    /// Wants every blob the stores name and the blob store lacks (`rewantMissingBlobs`, knit-next ADR 2026-09.ptv8): the
    /// photos peers' profiles advertise, each with its owner as the author, and the photos messages carry, each with the
    /// sender of the earliest message naming it. The wants are a memo of the stores and never their source, so this runs
    /// at start, at link-up and at each 60 s re-offer. At link-up a linked peer's own photo is left to its push
    /// (`sparing`), and wanted at the next re-offer if it never came; Android leaves a lost push lost.
    ///
    /// Each is a want of our own, and its deadline is re-derived from the rows that name it (`wantAll`'s `until`,
    /// `PullThroughGate`, knit-next ADR 2026-10.2drc): a DM's custody window from its latest row, none for a group's or a
    /// room's, and none for a photo. One whose rows read nothing (a store error answers as if none were there) keeps the
    /// deadline it had, so a failed read never lifts a DM's.
    func rewantMissingBlobs(sparing: Set<NodeId>) {
        let carried = stores.messages.attachmentHashes()
        let missing = carried.subtracting(stores.blobs.held(among: carried))
        let rows = stores.messages.attachmentRows(among: missing)
        var wanted: [BlobExchange.OwnWant] = []
        for peer in stores.peers.allPeers() where !sparing.contains(peer.nodeId) {
            if let advertised = peer.advertisedAvatarHash, !stores.blobs.contains(advertised) {
                // A photo has no deadline, unless a message's row names the same blob.
                let reach = missing.contains(advertised) ? PullThroughGate.reach(rows[advertised] ?? []) : .own(until: nil, rederived: true)
                wanted.append(BlobExchange.OwnWant(hash: advertised, author: peer.nodeId, reach: reach))
            }
        }
        for hash in missing.sorted() {
            wanted.append(
                BlobExchange.OwnWant(hash: hash, author: rows[hash]?.first?.senderId, reach: PullThroughGate.reach(rows[hash] ?? [])))
        }
        wantBlobs(wanted)
    }
}
