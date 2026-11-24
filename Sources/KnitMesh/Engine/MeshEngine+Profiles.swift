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
    ///
    /// A profile the store cannot read now is no profile to edit: `load()` would answer a fresh one, and the edit would
    /// save and sign a blank name under a version every receiver takes (ADR 2026-10.5sk9, ADR 2026-11.xfcq). So nothing is
    /// saved, signed or sealed, and the edit is dropped, logged.
    func publishEdit(_ change: (inout OwnProfile) -> Void) {
        guard let own = stores.ownProfile.loadIfReadable() else {
            log.log(.warning, "mesh left our profile as it was: our profile could not be read")
            return
        }
        publishEdit(of: own, change)
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
        savePublished(own)
        if let frame = signFreshProfile(publishedAt: own.publishedAt) {
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
    func republish(_ own: OwnProfile, now: Int64) {
        var own = own
        own.publishedAt = max(now, own.publishedAt + 1)
        savePublished(own)
        _ = signFreshProfile(publishedAt: own.publishedAt)
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

    /// Our profile, as an envelope (`MeshManager.currentProfileEnvelope`). The id and `sentAt` are the publish
    /// stamp; every required field is written, `status` included, or Android would never pin our key.
    ///
    /// The ratchet's bits and our prekey ride together, with the switch on and the prekey this publish names still kept
    /// (`MeshManager.kt:2963-2979`): `CAP_RATCHET` promises a published prekey, and every Android build that claims it
    /// carries one. Otherwise the profile is what it was before the ratchet but for the link-proof bit (ADR 2026-10.5sk9).
    ///
    /// `own` is our profile as the caller just read it through `loadIfReadable()`: a failed read is no fresh profile, whose
    /// stamp 0 was never ours to sign (``ownProfile()``).
    func currentProfileEnvelope(of own: OwnProfile) -> RelayEnvelope {
        let prekey = publishedPrekey(of: own)
        let content = ProfileContent(
            name: TextLimits.truncated(TextLimits.normalizeSingleLine(own.name), toUTF16: TextLimits.displayName),
            status: TextLimits.truncated(TextLimits.normalizeSingleLine(own.status), toUTF16: TextLimits.status),
            avatarHash: own.avatarHash?.string,
            pubKey: identity.bundle.encoded,
            deviceTag: deviceTag,
            protoVersion: WireProtocol.version,
            capabilities: publishedCapabilities(of: own).rawValue,
            prekey: prekey?.info,
            version: own.version,
            openToChat: own.openToChat
        )
        return RelayEnvelope(
            type: .profile,
            // The one spelling the router's gate admits (`FrameId.admits`), as `MeshManager.ownProfile` mints it since
            // knit-next `a81f2050`: a different one here and every node, this one included, refuses our profile.
            id: FrameId.profileId(sender: nodeId.string, publishedAt: own.publishedAt),
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
    /// not one can never be fetched, so the photo shown stays, as on Android, where its bytes are never local. Held bytes
    /// over the photo's ceiling are never adopted (``isAdoptablePhoto(_:)``, ADR 2026-10.r88m): the photo shown stays, and
    /// ``handleProfile(_:_:)`` declines them.
    func photoFrom(_ content: ProfileContent, existing: PeerRecord?) -> (advertised: BlobHash?, shown: BlobHash?) {
        guard let text = content.avatarHash else {
            return (nil, nil)
        }
        guard let hash = BlobHash(text) else {
            return (nil, existing?.avatarHash)
        }
        return (hash, isAdoptablePhoto(hash) ? hash : existing?.avatarHash)
    }

    /// A photo `sender`'s newer profile advertises and does not show yet, cleartext or sealed, never a blocked sender's
    /// (knit-ios #37). Held over the photo's ceiling, it is refused and let go (ADR 2026-10.r88m), so the want asks nobody.
    /// Otherwise it is wanted, of a linked sender, who pushes its own, only when `askingLinked`: our own want, reading no row,
    /// keeping a re-arm's deadline (knit-next ADR 2026-10.2drc), of a photo alone, so kept to its ceiling. Outside a unit only.
    func followAdvertisedPhoto(_ advertised: BlobHash, of sender: NodeId, askingLinked: Bool) {
        guard !isBlocked(sender) else {
            return
        }
        if isOverPhotoCeiling(advertised) {
            declinePhoto(advertised)
        }
        if askingLinked || !transport.isLinked(sender) {
            wantBlob(advertised, author: sender, via: nil, asker: nil, reach: .own(until: nil, rederived: false), kind: .photo)
        }
    }

    /// Marks a pinned peer verified, or not, once the user has compared safety numbers (`PeerRepository.setVerified`).
    /// A verified peer's DMs are never a message request. A peer that has not pinned has no key to verify.
    ///
    /// An acceptance is persisted before its basis goes (knit-ios #21): un-verifying first accepts outright the peer's DM
    /// and every group they posted in that read as accepted (``keepAccepted(_:)``). A thread accepted only by the
    /// verification would otherwise turn back into a request, and the next sweep would remove every photo in it, since a
    /// request's photos are not kept. Verifying wants the photos of the threads it accepts (``wantAcceptedPhotos()``).
    public func setVerified(_ peer: NodeId, _ verified: Bool) {
        guard var record = stores.peers.peer(peer), record.verified != verified else {
            return
        }
        if !verified {
            keepAccepted(peer.string)
            for group in stores.messages.conversationIds() where Conversations.isGroup(group) {
                if stores.messages.senders(in: group).contains(peer) {
                    keepAccepted(group)
                }
            }
        }
        record.verified = verified
        stores.peers.upsert(record)
        notePresenceKeyInputsChanged()
        events.append(.peerUpdated(peer))
        if verified {
            wantAcceptedPhotos()
        }
    }

    /// A verified profile (`InboundPipeline.handleProfile` and `storeProfileRow`, `InboundPipeline.kt:3159-3345`). Its key
    /// pins only if it derives to the sender, which ``verify(_:)`` checked, and a pinned key never changes. Two watermarks
    /// order what it changes, each on the profile's version clamped to five minutes past our clock: the presentation follows
    /// ``PeerRecord/updatedAt``, and the prekey ``PeerRecord/prekeyProfileAt``. A sealed profile update (phase P5a) moves the
    /// presentation and carries no prekey, so a cleartext profile older on the first can still be newer on the second, and
    /// its prekey must land (knit-next ADR 020's fix). A profile older on both changes nothing. A blocked sender's writes no
    /// presentation and wants no photo (knit-ios #37). Once the key pins, our DMs that waited for it go out, the frame is
    /// kept as the key's proof, neighbours that asked us for it are served, and frames parked for it are delivered. All of it
    /// runs whatever the ratchet's switch says, since none of it puts anything of the ratchet's on air (ADR 2026-10.5sk9),
    /// but for the answer an init of the peer's is owed, which goes with the switch on once the profile pins the bits and a
    /// prekey (phase P5e).
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
        // Before the row, the waiting DMs and the parked frames, so a re-keyed phone's first profile meets the block too.
        let continued = continueBlock(of: sender, deviceTag: content.deviceTag)
        let blocked = continued || isBlocked(sender)
        // A first profile starts from an empty row, both watermarks at 0, as `PeerEntity(senderId)` does (`:3301`).
        let base = existing ?? PeerRecord(nodeId: sender, name: "", status: "", publicKey: key, updatedAt: 0)
        var record = profileRecord(content, onto: base, version: version, stale: (stalePresentation, stalePrekey), blocked: blocked)
        // When the peer was last heard moves up to the profile's own stamp capped at our wall clock, blocked or not, so a new
        // pin is never born quiet (`storeProfileRow`'s `lastSeenAt = maxOf(base.lastSeenAt, seenAt)`, `InboundPipeline.kt:5725`;
        // knit-next ADR 2026-10.k8ge). A profile stale on both watermarks returned above, and was noted by ``noteHeard``.
        record.lastSeenAt = max(base.lastSeenAt, HeardFrom.heardAt(envelope, now: clock.wallMilliseconds()))
        writeProfileRow(record, was: existing)
        if continued || record != existing {
            events.append(.peerUpdated(sender))
        }
        hideBlockedPhotos(of: continued ? [sender] : []) // A block just followed new keys: hide the face, as a block does.
        // The photo moves with the presentation alone (`applyPresentationFollowUps`, `:1259-1272`). A linked peer pushes
        // its own photo right behind its profile, so only someone else's is asked for now; a push that never came is asked
        // for at the next re-offer.
        if !stalePresentation, !blocked {
            if let advertised = record.advertisedAvatarHash, record.avatarHash != advertised {
                followAdvertisedPhoto(advertised, of: sender, askingLinked: false)
            }
            if let replaced = existing?.avatarHash, replaced != record.avatarHash {
                releaseBlob(replaced)
            }
        }
        // With the switch on, the group seeds its outbox row shows unacknowledged go again, its prekey perhaps new
        // (`InboundPipeline.kt:3218-3221`, phase P6b). Before the waiting messages: a group message among them that mints
        // distributes its own seed, which this flush would otherwise send the sender a second time at once.
        flushPendingGroupKeys(for: sender, force: false)
        flushPending(to: sender)
        // Keep the frame the key pinned from beside the pin, so this node can prove the key to a newcomer after a
        // restart and after custody has lost it to the quota or the TTL (knit-next ADR 2026-09.g64k). The newest
        // publish stamp wins, clamped, because the peer picks it.
        stores.peers.recordProfileFrame(wire, of: sender, sentAt: clampFuture(envelope.sentAt))
        // Each neighbour that waited on this key is served on its own budget (ADR 2026-10.f5zs); one past it asks again.
        let skipped = keyExchange.skippedAnswers
        let pinned = clock.monotonicMilliseconds()
        for neighbor in keyExchange.onProfilePinned(sender, wire: wire, now: pinned, crossed: { transport.hasCrossed($0, to: $1) }) {
            transport.send(KeyExchange.served(wire), to: neighbor)
        }
        if keyExchange.skippedAnswers > skipped {
            log.log(.debug, "mesh key \(sender): \(keyExchange.skippedAnswers - skipped) waiting neighbours skipped over their budgets")
        }
        // An init of theirs that opened before we could seal to them is answered now, before the parked frames land, as
        // Kotlin calls `onProfilePinned` ahead of its release (`InboundPipeline.kt:3229-3236`), so one of them carrying the
        // same init meets the floor.
        answerOwedInit(of: sender, pinned: record)
        // Last, so the replayed frames verify against the key just pinned. Replay skips the router: each was
        // admitted, and its relay scheduled, when it first arrived.
        for parked in pendingInbound.release(sender) {
            deliver(parked.frame, from: nil)
        }
    }

    /// The row a profile leaves its sender with, from `base`, the row held or a fresh one under the profile's key
    /// (`storeProfileRow`, `:3285-3343`), each field on its own watermark. The name, status, photo and open-to-chat move only
    /// when the profile is not older than ``PeerRecord/updatedAt``, which never moves back, and the sender is not `blocked`,
    /// whose row keeps what it showed while its watermark moves (knit-ios #37). The prekey moves only when it is not older
    /// than ``PeerRecord/prekeyProfileAt``: a verified one is pinned, and an absent or bad one clears the pin, since the peer
    /// stopped serving it. The device tag and protocol version follow any profile that reaches here (`:3310-3318`), and the
    /// capabilities the presentation's watermark, blocked or not (knit-ios #25): a node edits when they change
    /// (``republishIfCapabilitiesChanged()``), so an older profile is from before and must not take a bit back.
    private func profileRecord(
        _ content: ProfileContent,
        onto base: PeerRecord,
        version: Int64,
        stale: (presentation: Bool, prekey: Bool),
        blocked: Bool
    ) -> PeerRecord {
        var record = stale.presentation || blocked ? base : presentation(of: content, onto: base)
        record.deviceTag = content.deviceTag ?? base.deviceTag
        record.protocolVersion = content.protoVersion ?? base.protocolVersion
        record.capabilities = stale.presentation ? base.capabilities : content.capabilities ?? base.capabilities
        record.updatedAt = max(base.updatedAt, version)
        if !stale.prekey {
            record.prekey = verifiedPrekey(content, of: base)
            record.prekeyProfileAt = version
        }
        return record
    }

    /// `row` with the presentation `content` carries, the one writer of a cleartext profile's, as it lands or on unblock: the
    /// name and status cleaned to one line and cut (knit-next #228), open-to-chat, and the photo.
    private func presentation(of content: ProfileContent, onto row: PeerRecord) -> PeerRecord {
        var record = row
        record.name = TextLimits.cleanReceived(content.name, limit: TextLimits.displayName)
        record.status = TextLimits.cleanReceived(content.status, limit: TextLimits.status)
        record.openToChat = content.openToChat
        (record.advertisedAvatarHash, record.avatarHash) = photoFrom(content, existing: row)
        return record
    }

    /// Re-applies the presentation of `peer`'s kept proof-of-key profile once a block that hid it is lifted (contract §5 of
    /// `block-hides-profile`): from `peer`, under its pinned key byte for byte, ordered as one that lands, so an equal
    /// version applies. No delivery: nothing carried, counted, flushed, released or wanted. Answers whether the row moved.
    func reapplyHeldProfile(of peer: NodeId) -> Bool {
        guard let frame = stores.peers.profileFrame(of: peer),
            let envelope = try? RelayEnvelope(decoding: frame.signed), envelope.type == .profile, NodeId(envelope.senderId) == peer,
            let content = try? ProfileContent(decoding: envelope.payload), let key = content.pubKey,
            let row = stores.peers.peer(peer), row.publicKey.utf8.elementsEqual(key.utf8),
            clampFuture(content.version ?? envelope.sentAt) >= row.updatedAt
        else {
            return false
        }
        let record = presentation(of: content, onto: row)
        if record != row {
            stores.peers.upsert(record)
            events.append(.peerUpdated(peer))
        }
        return record != row
    }

    /// The profile's prekey, or `nil` for none: its signature must verify against `peer`'s key, the one in the same
    /// profile, its public value must be 32 bytes (`verifiedPrekey`, `:3353-3368`), and X25519 must take it (knit-next
    /// `InboundPipeline.kt:3670-3674` at `4f3cd995`, #172). A signature proves the peer chose the key, not that it is one:
    /// a low-order point verifies, and every seal against it would be refused. A bad one counts as none, so it never
    /// blocks the rest of the profile, a newer profile carrying one clears the pin, and the peer gets v1.
    private func verifiedPrekey(_ content: ProfileContent, of peer: PeerRecord) -> PrekeyInfo? {
        guard let info = content.prekey else {
            return nil
        }
        guard let bundle = PublicKeyBundle(encoded: peer.publicKey), PeerPrekey(verifying: info, signedBy: bundle) != nil else {
            log.log(.warning, "mesh ignored a bad prekey from \(peer.nodeId)")
            return nil
        }
        guard RatchetCrypto.acceptsPublicKey(info.pub) else {
            log.log(.warning, "mesh ignored a prekey from \(peer.nodeId): X25519 refuses it")
            return nil
        }
        return info
    }
}
