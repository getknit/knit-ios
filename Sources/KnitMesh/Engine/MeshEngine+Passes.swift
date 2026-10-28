import KnitStore
import KnitWire

/// The engine's periodic passes, which ``MeshEngine/advance()`` fires when each falls due (ADR 2026-09.gq84): the
/// 60-second re-offer, the sweep and the 15-minute heal (`MeshManager`'s `reofferToNeighborsPeriodically`,
/// `sweepExpired` and `heal` in knit-next), the blob re-arm the re-offer, a start and a link-up run, and the blob
/// collection a start and the sweep run (`BlobRepository.deleteOrphans`), with the reads it shares with a photo's replacement.
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

    /// Expired and oversize custody (knit-next #227), the room's and the message requests' retention (`sweepLocalStorage`),
    /// parked frames, stale key wants, aged-out ticks, reactions left with no message and stale kept prefixes
    /// (`MeshManager.sweepExpired`), then the ratchet frames whose unit failed, opened again from the copies kept, and last
    /// the blobs nothing names that are older than an echo's life (knit-ios #20), which weighs the echo budget anew.
    func sweep() {
        let now = clock.monotonicMilliseconds()
        if stores.custody.sweepExpired(now: clock.wallMilliseconds()) > 0 {
            noteCustodyChanged()
        }
        // Before the orphan reactions, which then take a trimmed message's, and before the blobs, which then take its photo
        // once nothing names it (knit-ios #21).
        sweepRetention()
        pruneOrphanReactions()
        pendingInbound.sweep(now: now)
        // Beside the key-wait park, as Android sweeps both (`sweepExpired`, `MeshManager.kt:2333-2334`).
        pendingGroupKeys.sweep(now: now)
        keyExchange.sweep(now: now)
        ackSync.sweep(now: now)
        if blobExchange.sweep(now: now) > 0 {
            syncAcceptedFiles()
        }
        // The kept prefixes past their hour, and those whose blob came some other way (`MeshManager.kt:2777`). A store
        // error reads as not held, which keeps the prefix to its hour.
        partials.sweep(now: now) { stores.blobs.contains($0) }
        replayFailedRatchetOpens()
        sweepUnnamedBlobs(storedBefore: clock.wallMilliseconds() - BlobExchange.wantMilliseconds)
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
    /// at start, at link-up, at each 60 s re-offer, and when a thread is accepted. At link-up a linked peer's own photo is
    /// left to its push (`sparing`), and wanted at the next re-offer if it never came; Android leaves a lost push lost.
    ///
    /// A message's photo is wanted only for a row in a thread we fetch for, and a stranger's room photo only inside the
    /// room's bound (``rowsTaken(_:fetching:)``, knit-ios #21), read once for the pass. The rows are filtered before the
    /// author and the deadline are chosen, so a message request naming a contact's photo with an earlier `sentAt` never
    /// becomes its author, and a want of ours for a room photo the bound now leaves out is withdrawn. Android wants every
    /// row's (`MeshManager.kt` `rewantMissingBlobs`).
    ///
    /// Each is a want of our own, and its deadline is re-derived from the rows that name it (`wantAll`'s `until`,
    /// `PullThroughGate`, knit-next ADR 2026-10.2drc): a DM's custody window from its latest row, none for a group's or a
    /// room's, and none for a photo. A read of the rows that fails answers none, so nothing is wanted from them until the
    /// next pass, and a photo a message also names keeps the deadline it had, so a failed read never lifts a DM's.
    func rewantMissingBlobs(sparing: Set<NodeId>) {
        withdrawLeftOutRoomPhotos()
        let rows = rowsTaken(stores.messages.allAttachmentRows(), fetching: true)
        let missing = Set(rows.keys).subtracting(stores.blobs.held(among: Set(rows.keys)))
        let carried = stores.messages.attachmentHashes()
        var wanted: [BlobExchange.OwnWant] = []
        for peer in stores.peers.allPeers() where !sparing.contains(peer.nodeId) {
            if let advertised = peer.advertisedAvatarHash, !stores.blobs.contains(advertised) {
                // A photo has no deadline, unless a message's row names the same blob. A message request's row is no
                // reason to lift or set one: its rows fold to none taken, which keeps the deadline the want had.
                let reach = carried.contains(advertised) ? PullThroughGate.reach(rows[advertised] ?? []) : .own(until: nil, rederived: true)
                wanted.append(BlobExchange.OwnWant(hash: advertised, author: peer.nodeId, reach: reach))
            }
        }
        for (hash, named) in rows.sorted(by: { $0.key < $1.key }) where missing.contains(hash) {
            wanted.append(BlobExchange.OwnWant(hash: hash, author: named.first?.senderId, reach: PullThroughGate.reach(named)))
        }
        wantBlobs(wanted)
    }

    /// Wants the photos of a thread the user just accepted, by accepting it, verifying its peer or scanning their code
    /// (knit-ios #21): the re-arm, then every want's next step, as a re-offer runs them. A group a known sender's first post
    /// accepts is left to the next re-offer.
    func wantAcceptedPhotos() {
        rewantMissingBlobs(sparing: [])
        stepBlobs()
    }

    // MARK: Collecting

    /// Every blob something here still names: what the rows name (``blobsTheRowsName()``), and the photo every live frame
    /// our custody carries names in the clear (``carriedBlobs()``).
    func referencedBlobs() -> Set<BlobHash> {
        blobsTheRowsName().union(carriedBlobs())
    }

    /// Every blob the rows name: our photo, each peer's photo, shown or advertised, every photo a message in an accepted
    /// thread carries, a stranger's room photo only inside the room's bound (``rowsTaken(_:fetching:)``, knit-ios #21), and
    /// a deleted message's photo while our custody carries its frame (ADR 2026-10.u7cq). A message request's photo is named
    /// by none of them, so bytes an echo brought for it count toward the echo budget and go on the sweep.
    ///
    /// Every read here is the caller's, made anew on each call: a sweep reads it inside its store unit, where a failed
    /// read fails the unit and removes nothing, since outside one it would read as no thread accepted.
    func blobsTheRowsName() -> Set<BlobHash> {
        var named = Set(rowsTaken(stores.messages.allAttachmentRows(), fetching: false).keys)
        for deleted in stores.messages.deletedAttachments() where stores.custody.contains(deleted.id) {
            named.insert(deleted.hash)
        }
        if let own = stores.ownProfile.load().avatarHash {
            named.insert(own)
        }
        for peer in stores.peers.allPeers() {
            if let shown = peer.avatarHash {
                named.insert(shown)
            }
            if let advertised = peer.advertisedAvatarHash {
                named.insert(advertised)
            }
        }
        return named
    }

    /// The hash each live `chat` frame in our custody names in the clear, whoever sent it: a room post's photo, or a sealed
    /// message's or profile's beside the seal. Kotlin keeps a blob while any carried frame names it (`BlobRepository.kt:100-112`,
    /// `BlobDao.kt:59-67`, at knit-next `cbf2a487`), so after our photo changes we still serve the one our sealed profiles
    /// name for their day. Decoded on demand from at most 1,000 live frames, where Kotlin keeps a column; a failed read reads
    /// as no frame, so the blob goes as before (ADR 2026-10.5sk9's P7c amendment).
    ///
    /// A room post's attachment the room refuses is left out, as Kotlin leaves it out of its carrier column
    /// (`ForwardRepository.kt`, knit-next `eccabcd72`). So is a stranger's room photo the room's bound leaves out of the rows
    /// (``StrangerRoomPhotos``, knit-ios #21), this port's alone: the frame stays carried for six hours, and naming its photo
    /// would keep every one a flood brought in while it was inside the bound, which would then bound nothing.
    func carriedBlobs() -> Set<BlobHash> {
        let leftOut = StrangerRoomPhotos.leftOut(
            Array(stores.messages.allAttachmentRows().values.joined()), isKnown: Acquaintances(reading: self).knows)
        var named: Set<BlobHash> = []
        for carried in stores.custody.liveFrames(now: clock.wallMilliseconds()) where carried.envelope.type == .chat {
            guard let chat = try? ChatContent(decoding: carried.envelope.payload), !RoomAttachments.refuses(carried.envelope, chat),
                !leftOut.contains(ExactKey(carried.envelope.id))
            else {
                continue
            }
            if let text = chat.attachmentHash, let hash = BlobHash(text) {
                named.insert(hash)
            }
        }
        return named
    }

    /// Removes `hash` once nothing names it (`BlobRepository.deleteIfUnreferenced`). A blob not held reads nothing more.
    /// What names it is read inside a store unit, and the blob goes only once that unit commits: outside one a failed
    /// read names nothing, no thread accepted included, and would take a photo a row still shows (knit-ios #21).
    func releaseBlob(_ hash: BlobHash) {
        guard stores.blobs.contains(hash) else {
            return
        }
        let unit = stores.transactor.atomically { () -> Set<BlobHash>? in
            referencedBlobs()
        }
        if case .committed(let named) = unit, !named.contains(hash) {
            stores.blobs.remove(hash)
        }
    }

    /// Removes every blob nothing names, whatever its age (`BlobRepository.deleteOrphans`, at each mesh start). One a live
    /// carried frame names lives until the first sweep after that frame leaves custody: the start sweeps custody first.
    func sweepUnreferencedBlobs() {
        sweepUnnamedBlobs(storedBefore: nil)
    }

    /// Removes the blobs nothing names, stored before `cutoff` on the wall clock, or of any age with none: the start's
    /// sweep, and the 600 s sweep's (knit-ios #20). Android collects orphans only at its mesh start too
    /// (`MeshManager.kt:2756-2758`), so a blob fetched for an asker stayed until Knit next started, which on an iPhone in
    /// the background can be days; the fork review's H3 filled a phone that way.
    ///
    /// The sweep's cutoff is ``BlobExchange/wantMilliseconds``, an echo's life, so an asker whose copy was cut still finds
    /// the blob here at its re-asks. One goes only when, besides:
    /// - no row and no live carried frame names it (``referencedBlobs()``), read with the candidates in one store unit, so
    ///   a read that fails fails the unit and removes nothing, where outside one it would read as nothing named;
    /// - and, read after the unit, nothing here is using it: it is not wanted, not arriving, not queued or streaming to any
    ///   neighbour (a file reads its bytes from the store as it streams), and no ask for it is parked
    ///   (``isBlobInUse(_:)``).
    ///
    /// The removals run once the unit has committed, as a store unit's body leaves a blob's file to the work after it. The
    /// echo budget is weighed afterwards, and the hashes refused for it may be fetched again.
    func sweepUnnamedBlobs(storedBefore cutoff: Int64?) {
        let blobs = stores.blobs
        let unit = stores.transactor.atomically { () -> [BlobHash]? in
            let candidates = cutoff.map { blobs.hashes(storedBefore: $0) } ?? blobs.allHashes()
            guard !candidates.isEmpty else {
                return []
            }
            let named = referencedBlobs()
            return candidates.filter { !named.contains($0) }
        }
        if case .committed(let unnamed) = unit {
            for hash in unnamed where !isBlobInUse(hash) {
                blobs.remove(hash)
            }
        }
        measureEchoBudget()
        blobExchange.echoBudget.forgetRefused()
    }

    /// Whether `hash` is in use here whatever names it: wanted, on its way in, queued or streaming to a neighbour, or with
    /// an ask parked for it.
    func isBlobInUse(_ hash: BlobHash) -> Bool {
        blobExchange.isWanted(hash) || transport.arrivingFileKeys.contains(hash) || blobExchange.parked[hash] != nil
            || neighborIds.contains { transport.isFileInFlight(hash, to: $0) }
    }
}
