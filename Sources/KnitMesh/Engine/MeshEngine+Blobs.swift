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

    /// Wants `hash` (`BlobExchange.want`) and takes its first step: a query of the neighbours that can answer one, or
    /// the blind round's first ask (knit-next ADRs 2026-10.6e5t and 2026-10.f7gg). `author` and `via` rank the neighbours
    /// that cannot be queried, and `asker` is a neighbour we are pulling it for. Answers whether it is wanted: a blob
    /// held, or on its way in, is not.
    @discardableResult
    func wantBlob(_ hash: BlobHash, author: NodeId?, via: NodeId?, asker: NodeId?) -> Bool {
        guard !isBlobOnItsWayOrHeld(hash) else {
            return false
        }
        let now = clock.monotonicMilliseconds()
        note(blobExchange.recordWant(hash, now: now, author: author, via: via, asker: asker))
        stepBlob(hash, among: blobCandidates(), now: now)
        flushBlobQueries()
        return true
    }

    /// Wants each of `wanted`, with its author, stepped together so their queries share one frame per neighbour
    /// (`wantAll`).
    func wantBlobs(_ wanted: [(hash: BlobHash, author: NodeId?)]) {
        guard !wanted.isEmpty else {
            return
        }
        let now = clock.monotonicMilliseconds()
        let candidates = blobCandidates()
        for (hash, author) in wanted where !isBlobOnItsWayOrHeld(hash) {
            note(blobExchange.recordWant(hash, now: now, author: author, via: nil, asker: nil))
            stepBlob(hash, among: candidates, now: now)
        }
        flushBlobQueries()
    }

    /// Every blob still wanted takes its next step (`reask`): at link-up and at each 60 s re-offer. That is the query
    /// owed a newcomer, the next holder once an ask's grace is up, the widened blind ask, or the next cycle, which is
    /// the re-ask that moves a hop-by-hop pull on.
    func stepBlobs() {
        stepBlobs(blobExchange.wanted)
    }

    /// Each of `hashes` takes its next step against one look at the links, and their queries share one flush.
    func stepBlobs(_ hashes: [BlobHash]) {
        guard !hashes.isEmpty else {
            return
        }
        let now = clock.monotonicMilliseconds()
        let candidates = blobCandidates()
        for hash in hashes {
            stepBlob(hash, among: candidates, now: now)
        }
        flushBlobQueries()
    }

    /// Steps the wants whose timers are due: a grace up, answers due, or a holder's stream that may have ended.
    func stepDueBlobs(now: Int64) {
        let due = blobExchange.takeDue(now: now)
        guard !due.isEmpty else {
            return
        }
        let candidates = blobCandidates()
        for hash in due {
            stepBlob(hash, among: candidates, now: now)
        }
        flushBlobQueries()
    }

    /// One step of `hash`'s fetch (`step`): never for a blob on its way in or held, which is wanted no more once held.
    /// The asks it decides go out under one request, and its next step is timed.
    func stepBlob(_ hash: BlobHash, among candidates: [BlobExchange.Candidate], now: Int64) {
        if transport.arrivingFileKeys.contains(hash) {
            return
        }
        if stores.blobs.contains(hash) {
            blobExchange.forget(hash)
            syncAcceptedFiles()
            return
        }
        let plan = blobExchange.decide(hash, among: candidates, now: now)
        note(plan.notes)
        if let line = plan.asks.first?.line {
            let request = blobRequest(hash)
            for ask in plan.asks {
                transport.send(request, to: ask.to)
            }
            log.log(.debug, "mesh \(BlobExchange.askLine(hash, plan, line))")
        }
        if let wake = plan.wake {
            blobExchange.arm(hash, at: now + wake)
        }
        syncAcceptedFiles()
    }

    /// Whether `hash`'s bytes are on their way in or held, read in the order the bytes move: the link, then the store
    /// (knit-next #138), so a blob that lands between the two reads is seen by the second.
    func isBlobOnItsWayOrHeld(_ hash: BlobHash) -> Bool {
        transport.arrivingFileKeys.contains(hash) || stores.blobs.contains(hash)
    }

    /// The linked neighbours as a step reads them (`linkedNow`), in the order their links came up.
    func blobCandidates() -> [BlobExchange.Candidate] {
        transport.neighbors.map { neighbor in
            BlobExchange.Candidate(
                id: neighbor.nodeId,
                streaming: transport.isFileArriving(from: neighbor.nodeId),
                capable: neighbor.capabilities.contains(.blobHave)
            )
        }
    }

    /// Wants every blob the stores name and the blob store lacks (`rewantMissingBlobs`, knit-next ADR 2026-09.ptv8): the
    /// photos peers' profiles advertise, each with its owner as the author, and the photos messages carry, each with the
    /// sender of the earliest message naming it. The wants are a memo of the stores and never their source, so this runs
    /// at start, at link-up and at each 60 s re-offer. At link-up a linked peer's own photo is left to its push
    /// (`sparing`), and wanted at the next re-offer if it never came; Android leaves a lost push lost.
    func rewantMissingBlobs(sparing: Set<NodeId>) {
        var wanted: [(hash: BlobHash, author: NodeId?)] = []
        for peer in stores.peers.allPeers() where !sparing.contains(peer.nodeId) {
            if let advertised = peer.advertisedAvatarHash, !stores.blobs.contains(advertised) {
                wanted.append((advertised, peer.nodeId))
            }
        }
        let carried = stores.messages.attachmentHashes()
        let missing = carried.subtracting(stores.blobs.held(among: carried))
        let senders = stores.messages.attachmentSenders(among: missing)
        for hash in missing.sorted() {
            wanted.append((hash, senders[hash]))
        }
        wantBlobs(wanted)
    }

    /// Point-to-point holder queries for what the steps since the last flush owe, one frame per neighbour.
    func flushBlobQueries() {
        let now = clock.monotonicMilliseconds()
        for query in blobExchange.takeQueries() {
            let id = newFrameId()
            blobExchange.noteQuerySent(id, to: query.peer, hashes: query.hashes, now: now)
            let content = BlobHaveContent(hashes: query.hashes.map(\.string))
            transport.send(unsignedPointToPoint(.blobHave, id: id, payload: content.encoded), to: query.peer)
            let shown = query.hashes.map { String($0.string.prefix(BlobExchange.shownHashCharacters)) }.joined(separator: ", ")
            let queryId = id.prefix(BlobExchange.shownIdCharacters)
            log.log(.debug, "mesh blob query → \(query.peer) \(query.hashes.count) hashes #\(queryId) [\(shown)]")
        }
    }

    /// One blob request (`BlobExchange.blobRequest`). This port keeps no prefix of a cut transfer, so it never names an
    /// offset (knit-ios #2).
    func blobRequest(_ hash: BlobHash) -> WireEnvelope {
        unsignedPointToPoint(.blobRequest, id: newFrameId(), payload: BlobRequestContent(hash: hash.string).encoded)
    }

    /// An unsigned, point-to-point frame (`unsignedPointToPoint`): our id as its sender, `relay = false` so no router
    /// floods it, and `sentAt` left at 0, as Android leaves it.
    func unsignedPointToPoint(_ type: FrameType, id: String, payload: [UInt8]) -> WireEnvelope {
        let envelope = RelayEnvelope(type: type, id: id, senderId: nodeId.string, payload: payload)
        return WireEnvelope(relay: false, sig: [], signed: envelope.encoded)
    }

    /// Logs the blob exchange's own lines, as the mesh logs its others.
    func note(_ lines: [String]) {
        for line in lines {
            log.log(.debug, "mesh \(line)")
        }
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
            // Wanted on the asker's behalf, which this cycle neither queries nor asks: it lacks the bytes.
            answer = wantBlob(hash, author: nil, via: nil, asker: frame.from) ? "not held; fetching it" : "not held; already arriving"
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
    ///
    /// The link counts the file as on its way until the store has answered, kept or refused (`fileTaken`, knit-next
    /// #138): read before that, a blob past its END is neither arriving nor held, and would be asked for again.
    public func receiveFile(_ file: InboundFile) {
        defer { transport.fileTaken(from: file.from, hash: file.hash) }
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

    /// Every blob something here still names: our photo, each peer's photo, shown or advertised, every photo a
    /// message carries, and a deleted message's photo while our custody carries its frame (ADR 2026-10.u7cq).
    func referencedBlobs() -> Set<BlobHash> {
        var named = stores.messages.attachmentHashes()
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
