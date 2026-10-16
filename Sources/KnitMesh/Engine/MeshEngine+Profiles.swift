import KnitCrypto
import KnitStore
public import KnitWire

extension MeshEngine {
    // MARK: Our profile

    /// Changes what we publish, and floods it (`MeshManager.broadcastProfile`). The version, the clock receivers
    /// order profiles by, moves to `max(now, version + 1)`, and the publish stamp to a fresh one, so the frame has a
    /// new id that no seen set or custody check can swallow.
    public func updateProfile(name: String, status: String, openToChat: Bool) {
        publishEdit { own in
            own.name = name
            own.status = status
            own.openToChat = openToChat
        }
    }

    /// Applies `change` to what we present as an edit, and floods the result: the version moves to
    /// `max(now, version + 1)` and the publish stamp to a fresh one. With the ratchet's switch on, the sealed profile then
    /// goes to every peer we hold a confirmed session with, as `watchProfileChanges` follows `broadcastProfile` with
    /// `broadcastSealedProfile` (`MeshManager.kt:2687-2688`; ``broadcastSealedProfile()``, phase P5e). A prekey's edit
    /// (``syncPrekey(atStart:)``) changes nothing presented, so it waits for the heal's fan-out, as a rotation does in Kotlin.
    /// A photo's edit pushes the photo between the two (``setAvatar(_:)``).
    func publishEdit(_ change: (inout OwnProfile) -> Void) {
        publishEdit(of: stores.ownProfile.load(), change)
        broadcastSealedProfile()
    }

    /// Applies `change` to `own`, our profile as just read, as an edit, and floods the result: the cleartext profile
    /// alone, nothing sealed.
    func publishEdit(of own: OwnProfile, _ change: (inout OwnProfile) -> Void) {
        let now = clock.wallMilliseconds()
        var own = own
        change(&own)
        own.version = max(now, own.version + 1)
        own.publishedAt = max(now, own.publishedAt + 1)
        stores.ownProfile.save(own)
        if let frame = ownProfile() {
            originate(frame)
        }
    }

    /// Refreshes the publish stamp once it is 12 hours old (`MeshManager.republishProfileIfStale`), which keeps our
    /// profile inside custody's 24-hour window. Not an edit: the version stays, so no receiver's watermark moves.
    /// The fresh frame goes into custody and reaches neighbours through the next digest exchange.
    func republishIfStale() {
        let now = clock.wallMilliseconds()
        // A store that cannot be read now answers no profile, never a fresh one to save over the edited row.
        guard let own = stores.ownProfile.loadIfReadable(), now - own.publishedAt >= configuration.republishMilliseconds else {
            return
        }
        republish(own, now: now)
    }

    /// Saves `own` under a fresh publish stamp and signs it into custody, its version as it is, so no receiver's
    /// watermark moves.
    private func republish(_ own: OwnProfile, now: Int64) {
        var own = own
        own.publishedAt = max(now, own.publishedAt + 1)
        stores.ownProfile.save(own)
        _ = ownProfile()
    }

    /// Keeps the prekey our profile carries in step with the ring and the switch, at start and on every heal
    /// (`MeshManager.rotatePrekeyIfDue`, `MeshManager.kt:995-1003`, which the start's seeding and `heal` run, `:2550`,
    /// `:972`). With the switch on, a due prekey is minted, the first one on demand, and kept in the identity's store before
    /// any profile names it; then, when the newest differs from the one our profile carries, the profile is republished
    /// as an edit, its version and stamp moved, as Android's rotation bumps its version. With the switch off, or nothing
    /// kept, a profile that still names a prekey is republished without it. So every toggle is a new stamp, and a new
    /// version once the profile has been edited (ADR 2026-10.5sk9), and a crash between the store's write and the publish
    /// is mended by the next comparison.
    ///
    /// A profile at version 0 has never been edited, and after a reinstall its name is empty until onboarding publishes
    /// it. An edit then would flood the empty name at a version every peer takes, and Android writes a rename line into
    /// each thread for it (`InboundPipeline.kt:1299-1301`). So the profile is republished instead: under a fresh stamp,
    /// so that one stamp still names one payload, and at version 0, so no peer that holds an edit of ours takes its name,
    /// and one that pinned our prekey from an edit keeps that prekey, which the ring still holds. A first profile is
    /// never stale, so a peer that holds none pins it. The first edit, onboarding's
    /// (``updateProfile(name:status:openToChat:)``), carries the prekey and the name together.
    ///
    /// A start that finds prekeys over a profile never published is a reinstall: the Keychain kept the identity and its
    /// prekeys, and the database is new (ADR 2026-09.tkww). As Android's restore does (`MeshManager.finishRestore`,
    /// `:1036-1047`; `IdentityKeyStore.rotatePrekey`, `IdentityKeyStore.kt:111-120`), a fresh prekey is minted then,
    /// whatever the newest one's age, before the first publish, and no resets follow: there is no peer list to send them
    /// to (ADR 2026-10.5sk9). Android's restore brings the name back with the database, so it bumps the version; a
    /// reinstall here has no name yet, so its prekey takes the republish above. A profile the store cannot read now is
    /// neither a reinstall nor a profile to edit, so nothing is done until a heal reads it.
    func syncPrekey(atStart: Bool) {
        guard let own = stores.ownProfile.loadIfReadable() else {
            log.log(.warning, "mesh left our prekey as it was: our profile could not be read")
            return
        }
        var wanted: Int?
        if configuration.ratchet, var ring = prekeyRing {
            let now = clock.wallMilliseconds()
            let reinstall = atStart && ring.newest != nil && own.publishedAt == 0
            do {
                let minted: SignedPrekey? = try reinstall ? ring.rotate(now: now) : ring.rotateIfDue(now: now)
                if let minted {
                    prekeyRing = ring
                    log.log(.info, "mesh minted prekey \(minted.id)")
                }
            } catch {
                log.log(.warning, "mesh kept no new prekey: \(error)")
            }
            wanted = prekeyRing?.newest?.id
        }
        guard own.prekeyId != wanted else {
            return
        }
        guard own.version != 0 else {
            var carrying = own
            carrying.prekeyId = wanted
            republish(carrying, now: clock.wallMilliseconds())
            return
        }
        publishEdit(of: own) { $0.prekeyId = wanted }
    }

    /// Our profile frame for the current publish stamp (`MeshManager.ownProfile`): the carried copy when custody
    /// holds one, else the copy signed earlier, else a fresh signing that goes into custody now. One id, one set of
    /// bytes.
    func ownProfile() -> SignedFrame? {
        let envelope = currentProfileEnvelope()
        if let held = stores.custody.frame(envelope.id, now: clock.wallMilliseconds()) {
            return SignedFrame(wire: held.reserved, envelope: held.envelope)
        }
        if let signed = signedProfile, ExactKey(signed.envelope.id) == ExactKey(envelope.id) {
            return signed
        }
        let frame = sign(envelope, relay: true).map { SignedFrame(wire: $0, envelope: envelope) }
        if let frame {
            signedProfile = frame
            carryOwn(frame)
        }
        return frame
    }

    /// Our profile, as an envelope (`MeshManager.currentProfileEnvelope`). The id and `sentAt` are the publish
    /// stamp; every required field is written, `status` included, or Android would never pin our key.
    ///
    /// The ratchet's bits and our prekey ride together, with the switch on and the prekey this publish names still kept
    /// (`MeshManager.kt:2963-2979`): `CAP_RATCHET` promises a published prekey, and every Android build that claims it
    /// carries one. Otherwise the profile is byte for byte what it was before the ratchet (ADR 2026-10.5sk9).
    func currentProfileEnvelope() -> RelayEnvelope {
        let own = stores.ownProfile.load()
        let prekey = configuration.ratchet ? own.prekeyId.flatMap { prekeyRing?.prekey(id: $0) } : nil
        let content = ProfileContent(
            name: TextLimits.truncated(TextLimits.normalizeSingleLine(own.name), toUTF16: TextLimits.displayName),
            status: TextLimits.truncated(TextLimits.normalizeSingleLine(own.status), toUTF16: TextLimits.status),
            avatarHash: own.avatarHash?.string,
            pubKey: identity.bundle.encoded,
            deviceTag: deviceTag,
            protoVersion: WireProtocol.version,
            capabilities: (prekey == nil ? Capabilities.local : configuration.capabilities).rawValue,
            prekey: prekey?.info,
            version: own.version,
            openToChat: own.openToChat
        )
        return RelayEnvelope(
            type: .profile,
            id: "profile-\(nodeId)-\(own.publishedAt)",
            senderId: nodeId.string,
            sentAt: own.publishedAt,
            payload: content.encoded
        )
    }

    /// Pushes our profile to a neighbour that just linked (`MeshManager.pushProfileTo`). Every node pushes its own,
    /// because Android skips a key request for its own id.
    func pushProfile(to peer: NodeId) {
        if let frame = ownProfile() {
            router.markOwn(frame.envelope.id, now: clock.monotonicMilliseconds())
            transport.send(frame.wire, to: peer)
        }
    }

    // MARK: Their profiles

    /// The photo a newer profile leaves a peer with (`storeProfileRow` and `resolveAvatarHash`,
    /// `InboundPipeline.kt:3186-3207` and `:3302-3326`): the hash it advertises, and the photo shown, which follows that
    /// hash once its bytes are held and otherwise stays as it was. A profile with no photo clears both. A hash that is
    /// not one can never be fetched, so the photo shown stays, as on Android, where its bytes are never local.
    func photoFrom(_ content: ProfileContent, existing: PeerRecord?) -> (advertised: BlobHash?, shown: BlobHash?) {
        guard let text = content.avatarHash else {
            return (nil, nil)
        }
        guard let hash = BlobHash(text) else {
            return (nil, existing?.avatarHash)
        }
        return (hash, stores.blobs.contains(hash) ? hash : existing?.avatarHash)
    }

    /// Marks a pinned peer verified, or not, once the user has compared safety numbers (`PeerRepository.setVerified`).
    /// A verified peer's DMs are never a message request. A peer that has not pinned has no key to verify.
    public func setVerified(_ peer: NodeId, _ verified: Bool) {
        guard var record = stores.peers.peer(peer), record.verified != verified else {
            return
        }
        record.verified = verified
        stores.peers.upsert(record)
        events.append(.peerUpdated(peer))
    }

    /// A verified profile (`InboundPipeline.handleProfile` and `storeProfileRow`, `InboundPipeline.kt:3159-3345`). Its
    /// key pins only if it derives to the sender, which ``verify(_:)`` checked, and a pinned key never changes. Two
    /// watermarks order what it changes, each on the profile's version clamped to five minutes past our clock: the
    /// presentation follows ``PeerRecord/updatedAt``, and the prekey ``PeerRecord/prekeyProfileAt``. A sealed profile
    /// update (phase P5a) moves the presentation and carries no prekey, so a cleartext profile older on the first can
    /// still be newer on the second, and its prekey must land (knit-next ADR 020's fix). A profile older on both changes
    /// nothing. Once the key pins, our DMs that waited for it go out, the frame is kept as the key's proof, neighbours that
    /// asked us for it are served, and frames parked for it are delivered. All of it runs whatever the ratchet's switch
    /// says, since none of it puts anything of the ratchet's on air (ADR 2026-10.5sk9), but for the answer an init of the
    /// peer's is owed, which goes with the switch on once the profile pins the bits and a prekey (phase P5e).
    func handleProfile(_ wire: WireEnvelope, _ envelope: RelayEnvelope) {
        // Our own profile coming back is not a peer to pin.
        guard let sender = NodeId(envelope.senderId), sender != nodeId,
            let content = try? ProfileContent(decoding: envelope.payload), let key = content.pubKey
        else {
            return
        }
        let existing = stores.peers.peer(sender)
        let version = clampFuture(content.version ?? envelope.sentAt)
        let stalePresentation = existing.map { version < $0.updatedAt } ?? false
        let stalePrekey = existing.map { version < $0.prekeyProfileAt } ?? false
        guard !(stalePresentation && stalePrekey) else {
            return
        }
        if let existing, existing.publicKey != key {
            drop(.pinChangeRefused, envelope)
            log.log(.warning, "mesh refused a key change for pinned \(sender)")
            return
        }
        // A first profile starts from an empty row, both watermarks at 0, as `PeerEntity(senderId)` does (`:3301`).
        let base = existing ?? PeerRecord(nodeId: sender, name: "", status: "", publicKey: key, updatedAt: 0)
        let record = profileRecord(content, onto: base, version: version, stale: (stalePresentation, stalePrekey))
        stores.peers.upsert(record)
        // Before the waiting DMs go out and the parked frames land, so both meet a block that followed new keys. It runs
        // first, so it runs every time.
        if continueBlock(of: sender, deviceTag: content.deviceTag) || record != existing {
            events.append(.peerUpdated(sender))
        }
        // The photo moves with the presentation alone (`applyPresentationFollowUps`, `:1259-1272`). A linked peer pushes
        // its own photo right behind its profile, so only someone else's is asked for now; a push that never came is asked
        // for at the next re-offer.
        if !stalePresentation {
            if let advertised = record.advertisedAvatarHash, record.avatarHash != advertised, !transport.isLinked(sender) {
                wantBlob(advertised, author: sender, via: nil, asker: nil)
            }
            if let replaced = existing?.avatarHash, replaced != record.avatarHash {
                releaseBlob(replaced)
            }
        }
        flushPending(to: sender)
        // Keep the frame the key pinned from beside the pin, so this node can prove the key to a newcomer after a
        // restart and after custody has lost it to the quota or the TTL (knit-next ADR 2026-09.g64k). The newest
        // publish stamp wins, clamped, because the peer picks it.
        stores.peers.recordProfileFrame(wire, of: sender, sentAt: clampFuture(envelope.sentAt))
        for neighbor in keyExchange.onProfilePinned(sender, wire: wire) {
            transport.send(KeyExchange.served(wire), to: neighbor)
        }
        // An init of theirs that opened before we could seal to them is answered now, before the parked frames land, as
        // Kotlin calls `onProfilePinned` ahead of its release (`InboundPipeline.kt:3229-3236`), so one of them carrying the
        // same init meets the floor.
        answerOwedInit(of: sender, pinned: record)
        // Last, so the replayed frames verify against the key just pinned. Replay skips the router: each was
        // admitted, and its relay scheduled, when it first arrived.
        for parked in pendingInbound.release(sender) {
            deliver(parked.frame)
        }
    }

    /// The row a profile leaves its sender with, from `base`, the row held or a fresh one under the profile's key
    /// (`storeProfileRow`, `:3285-3343`), each field on its own watermark. The name, status, photo and open-to-chat move
    /// only when the profile is not older than ``PeerRecord/updatedAt``, which never moves back. The prekey moves only when
    /// it is not older than ``PeerRecord/prekeyProfileAt``: a verified one is pinned, and an absent or bad one clears the
    /// pin, since the peer stopped serving it. The device tag, protocol version and capabilities follow any profile that
    /// reaches here, as Android's do (`:3310-3318`): one older on the presentation's watermark is still the newest
    /// cleartext profile on the prekey's, and the bits and the prekey ride it together.
    private func profileRecord(
        _ content: ProfileContent,
        onto base: PeerRecord,
        version: Int64,
        stale: (presentation: Bool, prekey: Bool)
    ) -> PeerRecord {
        var record = base
        if !stale.presentation {
            // Our own limits bound what we send, not what a peer does.
            record.name = TextLimits.truncated(content.name, toUTF16: TextLimits.displayName)
            record.status = TextLimits.truncated(content.status, toUTF16: TextLimits.status)
            record.openToChat = content.openToChat
            (record.advertisedAvatarHash, record.avatarHash) = photoFrom(content, existing: base)
        }
        record.deviceTag = content.deviceTag ?? base.deviceTag
        record.protocolVersion = content.protoVersion ?? base.protocolVersion
        record.capabilities = content.capabilities ?? base.capabilities
        record.updatedAt = max(base.updatedAt, version)
        if !stale.prekey {
            record.prekey = verifiedPrekey(content, of: base)
            record.prekeyProfileAt = version
        }
        return record
    }

    /// The profile's prekey, or `nil` for none: its signature must verify against `peer`'s key, the one in the same
    /// profile, and its public value must be 32 bytes (`verifiedPrekey`, `:3353-3368`). A bad one counts as none, so it
    /// never blocks the rest of the profile.
    private func verifiedPrekey(_ content: ProfileContent, of peer: PeerRecord) -> PrekeyInfo? {
        guard let info = content.prekey else {
            return nil
        }
        guard let bundle = PublicKeyBundle(encoded: peer.publicKey), PeerPrekey(verifying: info, signedBy: bundle) != nil else {
            log.log(.warning, "mesh ignored a bad prekey from \(peer.nodeId)")
            return nil
        }
        return info
    }
}
