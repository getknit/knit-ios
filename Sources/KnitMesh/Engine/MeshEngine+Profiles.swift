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

    /// Applies `change` to what we publish as an edit, and floods the result: the version moves to
    /// `max(now, version + 1)` and the publish stamp to a fresh one.
    func publishEdit(_ change: (inout OwnProfile) -> Void) {
        let now = clock.wallMilliseconds()
        var own = stores.ownProfile.load()
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
        var own = stores.ownProfile.load()
        guard now - own.publishedAt >= configuration.republishMilliseconds else {
            return
        }
        own.publishedAt = max(now, own.publishedAt + 1)
        stores.ownProfile.save(own)
        _ = ownProfile()
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
    func currentProfileEnvelope() -> RelayEnvelope {
        let own = stores.ownProfile.load()
        let content = ProfileContent(
            name: TextLimits.truncated(TextLimits.normalizeSingleLine(own.name), toUTF16: TextLimits.displayName),
            status: TextLimits.truncated(TextLimits.normalizeSingleLine(own.status), toUTF16: TextLimits.status),
            avatarHash: own.avatarHash?.string,
            pubKey: identity.bundle.encoded,
            deviceTag: deviceTag,
            protoVersion: WireProtocol.version,
            capabilities: Capabilities.local.rawValue,
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

    /// A verified profile (`InboundPipeline.handleProfile`). Its key pins only if it derives to the sender, which
    /// ``verify(_:)`` checked, and a pinned key never changes. The presentation follows the newest version,
    /// clamped to five minutes past our clock. Once the key pins, our DMs that waited for it go out, the frame is kept
    /// as the key's proof, neighbours that asked us for it are served, and frames parked for it are delivered.
    func handleProfile(_ wire: WireEnvelope, _ envelope: RelayEnvelope) {
        // Our own profile coming back is not a peer to pin.
        guard let sender = NodeId(envelope.senderId), sender != nodeId,
            let content = try? ProfileContent(decoding: envelope.payload), let key = content.pubKey
        else {
            return
        }
        let existing = stores.peers.peer(sender)
        let version = clampFuture(content.version ?? envelope.sentAt)
        if let existing {
            guard version >= existing.updatedAt else {
                return
            }
            guard existing.publicKey == key else {
                drop(.pinChangeRefused, envelope)
                log.log(.warning, "mesh refused a key change for pinned \(sender)")
                return
            }
        }
        let photo = photoFrom(content, existing: existing)
        let record = PeerRecord(
            nodeId: sender,
            // Our own limits bound what we send, not what a peer does.
            name: TextLimits.truncated(content.name, toUTF16: TextLimits.displayName),
            status: TextLimits.truncated(content.status, toUTF16: TextLimits.status),
            publicKey: key,
            deviceTag: content.deviceTag ?? existing?.deviceTag,
            protocolVersion: content.protoVersion ?? existing?.protocolVersion,
            capabilities: content.capabilities ?? existing?.capabilities,
            updatedAt: max(existing?.updatedAt ?? version, version),
            verified: existing?.verified ?? false,
            openToChat: content.openToChat,
            avatarHash: photo.shown,
            advertisedAvatarHash: photo.advertised
        )
        stores.peers.upsert(record)
        // Before the waiting DMs go out and the parked frames land, so both meet a block that followed new keys. It runs
        // first, so it runs every time.
        if continueBlock(of: sender, deviceTag: content.deviceTag) || record != existing {
            events.append(.peerUpdated(sender))
        }
        // A linked peer pushes its own photo right behind its profile, so only someone else's is asked for now; a push
        // that never came is asked for at the next re-offer.
        if let advertised = photo.advertised, photo.shown != advertised, !transport.isLinked(sender) {
            wantBlob(advertised)
        }
        if let replaced = existing?.avatarHash, replaced != photo.shown {
            releaseBlob(replaced)
        }
        flushPending(to: sender)
        // Keep the frame the key pinned from beside the pin, so this node can prove the key to a newcomer after a
        // restart and after custody has lost it to the quota or the TTL (knit-next ADR 2026-09.g64k). The newest
        // publish stamp wins, clamped, because the peer picks it.
        stores.peers.recordProfileFrame(wire, of: sender, sentAt: clampFuture(envelope.sentAt))
        for neighbor in keyExchange.onProfilePinned(sender, wire: wire) {
            transport.send(KeyExchange.served(wire), to: neighbor)
        }
        // Last, so the replayed frames verify against the key just pinned. Replay skips the router: each was
        // admitted, and its relay scheduled, when it first arrived.
        for parked in pendingInbound.release(sender) {
            deliver(parked.frame)
        }
    }
}
