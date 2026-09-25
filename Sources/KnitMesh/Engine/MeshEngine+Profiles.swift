import KnitCrypto
import KnitStore
import KnitWire

extension MeshEngine {
    // MARK: Our profile

    /// Changes what we publish, and floods it (`MeshManager.broadcastProfile`). The version, the clock receivers
    /// order profiles by, moves to `max(now, version + 1)`, and the publish stamp to a fresh one, so the frame has a
    /// new id that no seen set or custody check can swallow.
    public func updateProfile(name: String, status: String, openToChat: Bool) {
        let now = clock.wallMilliseconds()
        var own = stores.ownProfile.load()
        own.name = name
        own.status = status
        own.openToChat = openToChat
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

    /// A verified profile (`InboundPipeline.handleProfile`). Its key pins only if it derives to the sender, which
    /// ``verify(_:)`` checked, and a pinned key never changes. The presentation follows the newest version,
    /// clamped to five minutes past our clock. Once the key pins, our DMs that waited for it go out, neighbours that
    /// asked us for it are served, and frames parked for it are delivered.
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
            openToChat: content.openToChat
        )
        stores.peers.upsert(record)
        if record != existing {
            events.append(.peerUpdated(sender))
        }
        flushPending(to: sender)
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
