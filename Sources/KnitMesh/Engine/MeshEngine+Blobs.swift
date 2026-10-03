import KnitCrypto
import KnitStore
public import KnitWire

/// Blobs: asking for them, serving them, taking them in, and our own photo (`BlobExchange.kt`,
/// `MeshManager.rewantMissingBlobs` and `sendAvatarIfNeeded`, `InboundPipeline.onAvatarReceived` and `storeProfileRow`
/// in knit-next; ADR 2026-10.nh55).
extension MeshEngine {
    /// The type our photo is stored and pushed as (`AVATAR_MIME`, `MeshManager.kt:3248`).
    static let avatarMime = "image/jpeg"

    // MARK: Our photo

    /// Sets our photo, or clears it with `nil`, and floods the profile that names it (`ProfileViewModel.saveAvatar`,
    /// then `MeshManager.broadcastProfile`). The bytes go into the blob store under their hash, the version and the
    /// publish stamp move as for any edit, and the photo goes to every neighbour after the profile. The photo it
    /// replaces goes once nothing names it.
    public func setAvatar(_ jpeg: [UInt8]?) {
        let hash = jpeg.map { BlobHash(of: $0) }
        let replaced = stores.ownProfile.load().avatarHash
        guard hash != replaced else {
            return
        }
        if let jpeg, let hash {
            stores.blobs.insert(jpeg, hash: hash, mime: Self.avatarMime, storedAt: clock.wallMilliseconds())
        }
        publishEdit { $0.avatarHash = hash }
        for peer in neighborIds {
            pushAvatar(to: peer)
        }
        if let replaced {
            releaseBlob(replaced)
        }
    }

    /// Pushes our photo to a neighbour (`MeshManager.sendAvatarIfNeeded`): once per neighbour per photo, as kind
    /// AVATAR. Android counts a push the moment it hands it over and never tries again. Here it counts once its END
    /// is out (``fileSent(_:to:)``), so a link that died mid-push pushes again at the next link-up.
    func pushAvatar(to peer: NodeId) {
        guard let hash = stores.ownProfile.load().avatarHash, avatarPushes[peer] != hash,
            let file = outboundFile(hash, kind: .avatar)
        else {
            return
        }
        _ = transport.sendFile(file, to: peer)
    }

    /// A file we streamed left the radio whole.
    public func fileSent(_ hash: BlobHash, to peer: NodeId) {
        if hash == stores.ownProfile.load().avatarHash {
            avatarPushes[peer] = hash
        }
    }

    // MARK: Asking

    /// Wants `hash` (`BlobExchange.want`): asks every neighbour, unless its bytes are held, arriving on a link, or
    /// already wanted. Answers whether it asked.
    @discardableResult
    func wantBlob(_ hash: BlobHash) -> Bool {
        guard !stores.blobs.contains(hash), !transport.arrivingFileKeys.contains(hash),
            blobExchange.want(hash, now: clock.monotonicMilliseconds())
        else {
            return false
        }
        syncAcceptedFiles()
        sendBlobRequests(for: [hash], to: neighborIds)
        return true
    }

    /// Asks `peers` again for every blob still wanted that is neither held nor arriving (`onNeighborAdded`), save the
    /// ones in `asked`, which every neighbour was asked for a moment ago. A blob held by now is wanted no more.
    func reaskBlobs(of peers: [NodeId], except asked: Set<BlobHash>) {
        let arriving = transport.arrivingFileKeys
        var missing: [BlobHash] = []
        for hash in blobExchange.wanted {
            if stores.blobs.contains(hash) {
                blobExchange.forget(hash)
            } else if !arriving.contains(hash), !asked.contains(hash) {
                missing.append(hash)
            }
        }
        syncAcceptedFiles()
        sendBlobRequests(for: missing, to: peers)
    }

    /// Wants every blob the stores name and the blob store lacks (`rewantMissingBlobs`, knit-next ADR 2026-09.ptv8):
    /// the photos peers' profiles advertise, and the photos messages carry. The wants are a memo of the stores and never
    /// their source, so this runs at start, at link-up and at each 60 s re-offer. At link-up a linked peer's own photo
    /// is left to its push (`sparing`), and asked for at the next re-offer if it never came; Android leaves a lost push
    /// lost. Answers the blobs it asked every neighbour for, so the re-ask that follows does not ask again: Android
    /// does (knit-next ADR 2026-09.ptv8, "What it costs").
    @discardableResult
    func rewantMissingBlobs(sparing: Set<NodeId>) -> Set<BlobHash> {
        var asked: Set<BlobHash> = []
        for peer in stores.peers.allPeers() where !sparing.contains(peer.nodeId) {
            if let advertised = peer.advertisedAvatarHash, !stores.blobs.contains(advertised), wantBlob(advertised) {
                asked.insert(advertised)
            }
        }
        let carried = stores.messages.attachmentHashes()
        for hash in carried.subtracting(stores.blobs.held(among: carried)) where wantBlob(hash) {
            asked.insert(hash)
        }
        return asked
    }

    /// Point-to-point blob requests for `hashes`, one each, to each of `peers`.
    func sendBlobRequests(for hashes: [BlobHash], to peers: [NodeId]) {
        guard !peers.isEmpty else {
            return
        }
        for hash in hashes {
            let request = blobRequest(hash)
            for peer in peers {
                transport.send(request, to: peer)
            }
            log.log(.debug, "mesh blobreq \(LinkManager.shown(hash.string)) to \(peers.map(\.string).joined(separator: ", "))")
        }
    }

    /// One blob request (`BlobExchange.blobRequest`): unsigned by design, a fresh id, our id as its sender, `relay =
    /// false` so no router floods it, and `sentAt` left at 0, as Android leaves it.
    func blobRequest(_ hash: BlobHash) -> WireEnvelope {
        let envelope = RelayEnvelope(
            type: .blobRequest,
            id: newFrameId(),
            senderId: nodeId.string,
            payload: BlobRequestContent(hash: hash.string).encoded
        )
        return WireEnvelope(relay: false, sig: [], signed: envelope.encoded)
    }

    /// Tells the links which attachments to keep as they stream in: the blobs wanted.
    func syncAcceptedFiles() {
        let wanted = Set(blobExchange.wanted)
        guard wanted != acceptedFiles else {
            return
        }
        acceptedFiles = wanted
        transport.acceptFiles(wanted)
    }

    // MARK: Serving

    /// A neighbour's blob request (`BlobExchange.onRequest`): serve the blob if held, and otherwise want it, so the
    /// asker's next ask finds it here. The asker is the neighbour whose link carried the request, never the sender
    /// the unsigned frame names. The log says what became of each request.
    func handleBlobRequest(_ frame: InboundFrame) {
        guard let request = try? BlobRequestContent(decoding: frame.envelope.payload), let hash = BlobHash(request.hash) else {
            drop(.undecodable, frame.envelope)
            return
        }
        let answer: String
        if let file = outboundFile(hash, kind: .attachment) {
            answer = serve(file, to: frame.from)
        } else {
            answer = wantBlob(hash) ? "not held; asked our neighbours" : "not held; already asked for or arriving"
        }
        log.log(.debug, "mesh blobreq \(LinkManager.shown(hash.string)) from \(frame.from): \(answer)")
    }

    /// Streams a held blob to `peer` as kind ATTACHMENT, whatever it is, as Android serves every blob: not while a
    /// copy is already on the link to it, and not twice inside the serve memo. Answers what it did, for the log.
    func serve(_ file: OutboundFile, to peer: NodeId) -> String {
        guard !transport.isFileInFlight(file.hash, to: peer) else {
            return "already on its way"
        }
        guard blobExchange.shouldServe(file.hash, to: peer, now: clock.monotonicMilliseconds()) else {
            return "served to it within the serve memo"
        }
        guard transport.sendFile(file, to: peer) else {
            // Nothing went out, so the next ask is served at once (`forgetServed`).
            blobExchange.forgetServe(file.hash, to: peer)
            return "no link to it"
        }
        return "serving \(file.size) bytes"
    }

    /// A held blob as a file to stream, its bytes read from the store as the link needs them.
    func outboundFile(_ hash: BlobHash, kind: FileHeader.Kind) -> OutboundFile? {
        let blobs = stores.blobs
        guard let size = blobs.size(of: hash), let mime = blobs.mime(of: hash) else {
            return nil
        }
        return OutboundFile(kind: kind, hash: hash, mime: mime, size: size) { offset, count in
            blobs.read(hash, offset: offset, count: count)
        }
    }

    // MARK: Taking in

    /// A whole file a neighbour streamed (`MeshBlobStore.saveIncoming`, `InboundPipeline.onAvatarReceived`). Its bytes
    /// must hash to its key, or it is dropped and the link kept. A pushed photo must be the one its pusher's signed
    /// profile advertises, and anything else must be a blob this node wants.
    public func receiveFile(_ file: InboundFile) {
        guard BlobHash(of: file.bytes) == file.hash else {
            reject(file, "does not match its hash")
            return
        }
        switch file.kind {
        case .avatar:
            // The HELLO that names the pusher is unauthenticated, so a push proves nothing alone. Android writes the
            // profile ahead of the push on one link (`MeshManager.kt:2562-2563`), so an honest push always matches.
            // Android adopts any push at once (`pointPeerAtAvatar`); this port adopts only a match (ADR 2026-10.nh55).
            guard stores.peers.peer(file.from)?.advertisedAvatarHash == file.hash else {
                reject(file, "is not the photo its pusher's profile names")
                return
            }
        case .attachment:
            guard blobExchange.isWanted(file.hash) || referencedBlobs().contains(file.hash) else {
                reject(file, "was not asked for")
                return
            }
        }
        stores.blobs.insert(file.bytes, hash: file.hash, mime: file.mime, storedAt: clock.wallMilliseconds())
        blobExchange.forget(file.hash)
        syncAcceptedFiles()
        adoptAvatar(file.hash)
        if stores.messages.attachmentHashes().contains(file.hash) {
            events.append(.attachmentArrived(file.hash))
        }
    }

    private func reject(_ file: InboundFile, _ reason: String) {
        filesRejected += 1
        log.log(.info, "mesh file \(LinkManager.shown(file.hash.string)) from \(file.from) \(reason); dropped")
    }

    /// Shows `hash` as the photo of every peer whose newest profile advertises it, now that its bytes are held
    /// (`resolveAvatarHash`, `InboundPipeline.kt:3302-3311`). The photo each replaces goes once nothing names it.
    func adoptAvatar(_ hash: BlobHash) {
        for var peer in stores.peers.allPeers() where peer.advertisedAvatarHash == hash && peer.avatarHash != hash {
            let replaced = peer.avatarHash
            peer.avatarHash = hash
            stores.peers.upsert(peer)
            events.append(.peerUpdated(peer.nodeId))
            if let replaced {
                releaseBlob(replaced)
            }
        }
    }

    // MARK: Collecting

    /// Every blob something here still names: our photo, each peer's photo, shown or advertised, and every photo a
    /// message carries.
    func referencedBlobs() -> Set<BlobHash> {
        var named = stores.messages.attachmentHashes()
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

    /// Removes `hash` once nothing names it (`BlobRepository.deleteIfUnreferenced`).
    func releaseBlob(_ hash: BlobHash) {
        if !referencedBlobs().contains(hash) {
            stores.blobs.remove(hash)
        }
    }

    /// Removes every blob nothing names (`BlobRepository.deleteOrphans`, at each mesh start). A blob fetched on an
    /// asker's behalf lives until then, so the asker's next ask still finds it here.
    func sweepUnreferencedBlobs() {
        let named = referencedBlobs()
        for hash in stores.blobs.allHashes() where !named.contains(hash) {
            stores.blobs.remove(hash)
        }
    }
}
