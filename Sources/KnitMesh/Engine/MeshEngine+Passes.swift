import KnitStore

/// The engine's periodic passes, which ``MeshEngine/advance()`` fires when each falls due (ADR 2026-09.gq84): the
/// 60-second re-offer, the sweep and the 15-minute heal (`MeshManager`'s `reofferToNeighborsPeriodically`,
/// `sweepExpired` and `heal` in knit-next).
extension MeshEngine {
    /// The 60-second re-offer to every linked neighbour (`MeshManager.reofferToNeighborsPeriodically`): the blobs and
    /// keys we still lack, our digest, and any ticks owed. A Bluetooth link stays up, so this is what reconciles
    /// custody that drifts after link-up, and what opens a blob's next cycle, which moves it one hop nearer.
    func reoffer() {
        let neighbors = neighborIds
        rewantMissingBlobs(sparing: [])
        stepBlobs()
        askForMissingKeys(to: neighbors)
        let ids = stores.custody.liveIds(now: clock.wallMilliseconds())
        for peer in neighbors {
            transport.sendDigest(ids, to: peer)
            sendOwedTicks(to: peer)
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
    /// republish) and seal again the DMs a store failure left waiting.
    func heal() {
        askForMissingKeys(to: neighborIds)
        retryOwedTicks()
        syncPrekey(atStart: false)
        republishIfStale()
        broadcastSealedProfile()
        retryWaitingDirectMessages()
    }
}
