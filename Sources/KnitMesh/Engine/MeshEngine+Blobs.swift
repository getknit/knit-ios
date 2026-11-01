import KnitCrypto
import KnitStore
import KnitWire

/// Blobs: asking for them, serving them and taking them in (`BlobExchange.kt`,
/// `MeshManager.rewantMissingBlobs` and `sendAvatarIfNeeded`, `InboundPipeline.onAvatarReceived` and `storeProfileRow`
/// in knit-next; ADR 2026-10.nh55).
extension MeshEngine {
    // MARK: Asking

    /// Wants `hash` (`BlobExchange.want`) and takes its first step: a query of the neighbours that can answer one, or
    /// the blind round's first ask (knit-next ADRs 2026-10.6e5t and 2026-10.f7gg). `author` and `via` rank the neighbours
    /// that cannot be queried, and `asker` is a neighbour we are pulling it for. `reach` is the budget and deadline it is
    /// wanted with (knit-next ADR 2026-10.2drc): ``BlobExchange/Reach/own(until:rederived:)`` for a want of ours,
    /// ``BlobExchange/Reach/asked(pull:until:)`` for an asker's. Answers whether it is wanted: a blob held, or on its way
    /// in, is not. An echo the want set would turn away (``BlobExchange/echoRefusal(_:)``) never gets here: the one caller
    /// that passes an asker, ``serveOrWant(_:to:mayPark:reached:)``, declines it first, and ``makeRoom(for:asker:)`` leaves the room it found.
    /// A want of ours for an echo whose bytes are already on their way makes it ours (``promoteArriving(_:)``). `kind`
    /// ``BlobExchange/WantKind/photo`` is a peer's profile photo alone, kept to its ceiling, and never wanted again once
    /// refused this session (``BlobExchange/overPhotoCeiling(_:from:)``).
    @discardableResult
    func wantBlob(
        _ hash: BlobHash, author: NodeId?, via: NodeId?, asker: NodeId?, reach: BlobExchange.Reach,
        // Every site's kind but a profile photo's, cleartext or sealed, which passes `.photo`.
        kind: BlobExchange.WantKind = .attachment // swiftlint:disable:this discouraged_default_parameter
    ) -> Bool {
        // Kotlin's order (`BlobExchange.kt:289` before `:295`): a refused photo want promotes no arriving echo either.
        if asker == nil, kind == .photo, isRefusedPhoto(hash) {
            return false
        }
        guard !isBlobOnItsWayOrHeld(hash) else {
            if asker == nil {
                promoteArriving(hash)
            }
            return false
        }
        let now = clock.monotonicMilliseconds()
        let wall = clock.wallMilliseconds()
        makeRoom(for: hash, asker: asker)
        note(blobExchange.recordWant(hash, now: now, wall: wall, author: author, via: via, asker: asker, reach: reach, kind: kind))
        withdrawEvicted()
        stepBlob(hash, among: blobCandidates(), now: now, wall: wall)
        flushBlobQueries()
        return true
    }

    /// Wants each of `wanted` of our own, with its author and the budget and deadline it is wanted with, stepped together
    /// so their queries share one frame per neighbour (`wantAll`).
    func wantBlobs(_ wanted: [BlobExchange.OwnWant]) {
        guard !wanted.isEmpty else {
            return
        }
        let now = clock.monotonicMilliseconds()
        let wall = clock.wallMilliseconds()
        let candidates = blobCandidates()
        for want in wanted {
            if want.kind == .photo, isRefusedPhoto(want.hash) {
                continue
            }
            guard !isBlobOnItsWayOrHeld(want.hash) else {
                promoteArriving(want.hash)
                continue
            }
            makeRoom(for: want.hash, asker: nil)
            note(
                blobExchange.recordWant(
                    want.hash, now: now, wall: wall, author: want.author, via: nil, asker: nil, reach: want.reach, kind: want.kind))
            withdrawEvicted()
            stepBlob(want.hash, among: candidates, now: now, wall: wall)
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
        let wall = clock.wallMilliseconds()
        let candidates = blobCandidates()
        for hash in hashes {
            stepBlob(hash, among: candidates, now: now, wall: wall)
        }
        flushBlobQueries()
    }

    /// Steps the wants whose timers are due: a grace up, answers due, or a holder's stream that may have ended.
    func stepDueBlobs(now: Int64) {
        let due = blobExchange.takeDue(now: now)
        guard !due.isEmpty else {
            return
        }
        let wall = clock.wallMilliseconds()
        let candidates = blobCandidates()
        for hash in due {
            stepBlob(hash, among: candidates, now: now, wall: wall)
        }
        flushBlobQueries()
    }

    /// One step of `hash`'s fetch (`step`): never for a blob on its way in or held, which is wanted no more once held.
    /// The asks it decides go out under one request, carrying the want's budget and deadline, the asks it moves on from are
    /// withdrawn, and its next step is timed. `now` is the monotonic clock and `wall` the wall clock, read together.
    func stepBlob(_ hash: BlobHash, among candidates: [BlobExchange.Candidate], now: Int64, wall: Int64) {
        if transport.arrivingFileKeys.contains(hash) {
            return
        }
        if stores.blobs.contains(hash) {
            // Held some other way: every ask still standing is withdrawn, and a kept prefix has nothing left to resume.
            withdrawAsks(hash, from: blobExchange.obtained(hash, from: nil))
            partials.drop(hash)
            syncAcceptedFiles()
            return
        }
        // An echo's next fetch reserves a whole file's room in the echo budget (knit-ios #20), its own fetch's set aside.
        let echoRoom = !blobExchange.isEcho(hash) || echoBudgetFits(Int64(FileIntake.maxFileBytes), excluding: hash)
        let plan = blobExchange.decide(hash, among: candidates, now: now, wall: wall, echoRoom: echoRoom)
        note(plan.notes)
        if let line = plan.asks.first?.line {
            let request = blobRequest(hash, pull: plan.pull, until: plan.until)
            for ask in plan.asks {
                transport.send(request, to: ask.to)
            }
            log.log(.debug, "mesh \(BlobExchange.askLine(hash, plan, line))")
        }
        withdrawAsks(hash, from: plan.cancels)
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
                capable: neighbor.capabilities.contains(.blobHave),
                streamLeftMilliseconds: transport.fileArrivingLeftMilliseconds(from: neighbor.nodeId)
            )
        }
    }

    /// Logs the blob exchange's own lines, as the mesh logs its others.
    func note(_ lines: [String]) {
        for line in lines {
            log.log(.debug, "mesh \(line)")
        }
    }

    /// Tells the links which attachments to keep as they stream in, the blobs wanted, which of those leave a prefix kept
    /// when cut, our own (knit-ios #20), and which are kept only to the photo's ceiling, those wanted only as a profile
    /// photo. Sent when any changes: a want of ours that takes over an echo changes no key wanted, and only makes it
    /// resumable, and a row's want of a photo's hash, or our photo want on an echo, changes only its limit.
    func syncAcceptedFiles() {
        let now = AcceptedFiles(keys: Set(blobExchange.wanted), resumable: blobExchange.ownWanted, photoOnly: blobExchange.photoOnlyWanted)
        guard now != acceptedFiles else {
            return
        }
        acceptedFiles = now
        transport.acceptFiles(now.keys, resumable: now.resumable, photoOnly: now.photoOnly)
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
        let reached = BlobExchange.Reached(pull: request.pull, deadline: request.until, offset: request.offset)
        serveOrWant(hash, to: frame.from, mayPark: true, reached: reached)
    }

    /// Serves `hash` to `peer` if it is held, and otherwise wants it on the asker's behalf (`serveOrWant`), with one hop
    /// less of the ask's budget and its deadline (`reached`, knit-next ADR 2026-10.2drc). `mayPark` false serves at once
    /// whatever else is being fed: a parked ask whose turn came. The log says what became of it.
    ///
    /// A held blob is served whatever the ask allows, `pull = 0` included, from the offset it named (Kotlin's order: the
    /// file, where it starts, then ``serve(_:to:mayPark:reached:)``, `BlobExchange.kt:1665-1690`). A blob we lack makes no
    /// want at all for an ask with no budget left or past its deadline (`echoFor`): it is logged as Android logs it,
    /// beside this port's `blobreq` line, and counted. So, in the same words, is an echo this port turns away for what it
    /// would cost (knit-ios #20, ``echoDecline(_:reached:)``).
    func serveOrWant(_ hash: BlobHash, to peer: NodeId, mayPark: Bool, reached: BlobExchange.Reached) {
        let answer: String
        if let file = outboundFile(hash, kind: .attachment, from: reached.offset) {
            answer = serve(file, to: peer, mayPark: mayPark, reached: reached)
        } else if let refused = echoDecline(hash, reached: reached) {
            blobExchange.counts.echoesDeclined += 1
            note(["blob no-echo \(hash.string.prefix(BlobExchange.shownHashCharacters))… for \(peer) (\(refused))"])
            answer = "not held; no echo (\(refused))"
        } else {
            // Wanted on the asker's behalf, which this cycle neither queries nor asks: it lacks the bytes.
            let reach = BlobExchange.Reach.asked(pull: reached.pull, until: reached.deadline)
            answer =
                wantBlob(hash, author: nil, via: nil, asker: peer, reach: reach) ? "not held; fetching it" : "not held; already arriving"
        }
        log.log(.debug, "mesh blobreq \(LinkManager.shown(hash.string)) from \(peer): \(answer)")
    }

    /// Streams a held blob to `peer` as kind ATTACHMENT, whatever it is, as Android serves every blob: not while a
    /// copy is already on the link to it, not while another copy of it is fed live to someone else, when `mayPark`
    /// (``parkBehindFeed(_:for:bytes:reached:now:)``, which keeps what the ask said, sized by its tail), not while
    /// ``BlobExchange/maxWaitingServes`` files wait on its link, when `mayPark` (knit-ios #20), and not twice inside
    /// the serve memo, which an unsigned asker's other offset never gets past. Answers what it did, for the log: a resumed
    /// serve's tail, then where it starts, so a whole file's line is the one it always was.
    func serve(_ file: OutboundFile, to peer: NodeId, mayPark: Bool, reached: BlobExchange.Reached) -> String {
        guard !transport.isFileInFlight(file.hash, to: peer) else {
            return "already on its way"
        }
        let now = clock.monotonicMilliseconds()
        let tail = file.size - file.start
        if mayPark, parkBehindFeed(file.hash, for: peer, bytes: Int64(tail), reached: reached, now: now) {
            return "parked behind a feed"
        }
        // The queue on the asker's link, which Android leaves unbounded: an unsigned ask per held hash would otherwise
        // queue every blob held. Nothing is stamped, so the asker's ask at its floor is served once the queue drains. A
        // parked ask whose turn came is queued whatever waits: it waited its turn already.
        let waiting = transport.filesWaiting(to: peer)
        if mayPark, waiting >= BlobExchange.maxWaitingServes {
            blobExchange.counts.servesRefused += 1
            note(["blob no-serve \(file.hash.string.prefix(BlobExchange.shownHashCharacters))… to \(peer) (\(waiting) waiting)"])
            return "not queued behind \(waiting) files waiting"
        }
        guard blobExchange.shouldServe(file.hash, to: peer, now: now) else {
            return "served to it within the serve memo"
        }
        guard transport.sendFile(file, to: peer) else {
            // Nothing went out, so the next ask is served at once (`forgetServed`).
            blobExchange.forgetServe(file.hash, to: peer)
            return "no link to it"
        }
        return "serving \(tail) bytes" + (file.start > 0 ? " resumed at \(file.start)" : "")
    }

    /// A held blob as a file to stream, its bytes read from the store as the link needs them, from the bytes a resuming
    /// asker kept, `from` (``OutboundFile/start(asked:size:)``, knit-next ADR 2026-10.wtyc).
    func outboundFile(_ hash: BlobHash, kind: FileHeader.Kind, from: Int64?) -> OutboundFile? {
        let blobs = stores.blobs
        guard let size = blobs.size(of: hash), let mime = blobs.mime(of: hash) else {
            return nil
        }
        let start = OutboundFile.start(asked: from, size: size)
        return OutboundFile(kind: kind, hash: hash, mime: mime, size: size, start: start) { offset, count in
            blobs.read(hash, offset: offset, count: count)
        }
    }

    // MARK: Taking in

    /// A whole file a neighbour streamed (`MeshBlobStore.saveIncoming`, `InboundPipeline.onAvatarReceived`). Its bytes
    /// must hash to its key, or it is dropped and the link kept. A pushed photo must be the one its pusher's signed
    /// profile advertises, and anything else must be a blob this node wants. Once it is stored, our asks for it on every
    /// other neighbour are withdrawn (`BlobExchange.onReceived`, knit-next ADR 2026-10.nsr7). Android withdraws them for
    /// a pushed photo at that blob's next step, the pusher's ask too.
    ///
    /// The link counts the file as on its way until the store has answered, kept or refused (`fileTaken`, knit-next
    /// #138): read before that, a blob past its END is neither arriving nor held, and would be asked for again. A spliced
    /// file that fails its hash starts over from 0 (``restartFailedSplice(_:)``); a whole one leaves a kept prefix alone,
    /// since the bytes were the holder's alone (`BlobExchange.kt:2018-2023`).
    ///
    /// A file wanted only as an echo, which no row names, is weighed against the echo budget at its measured size before
    /// it is stored, and refused when it does not fit (``refuseEchoFile(_:)``, knit-ios #20): the links keep any file
    /// wanted, so a peer can stream one for an echo it was never asked for. One stored adds its size to the budget.
    ///
    /// A photo pushed by someone blocked is taken as an attachment is, kept only when wanted or named (knit-ios #37): their
    /// row names it no more (``blobsTheRowsName()``), so a push of their own photo alone is refused, and one kept is never
    /// shown on their row (``adoptAvatar(_:landedAsEcho:)``).
    public func receiveFile(_ file: InboundFile) {
        defer { transport.fileTaken(from: file.from, hash: file.hash) }
        guard BlobHash(of: file.bytes) == file.hash else {
            reject(file, "does not match its hash")
            if file.resumedFrom > 0 {
                restartFailedSplice(file)
            }
            return
        }
        // What the rows name, read once and only when it decides something: a file not wanted, or wanted as an echo.
        let wanted = blobExchange.isWanted(file.hash)
        let echo = blobExchange.isEcho(file.hash)
        let blockedPush = file.kind == .avatar && isBlocked(file.from)
        let asAttachment = file.kind == .attachment || blockedPush
        let named = asAttachment && (!wanted || echo) ? blobsTheRowsName() : []
        switch file.kind {
        case .avatar where !blockedPush:
            guard takesPush(file) else {
                return
            }
        case .avatar, .attachment:
            // Never what a carried frame names: this port pulls no carried frame's photo (ADR 2026-10.ym9y).
            guard wanted || named.contains(file.hash) else {
                reject(file, blockedPush ? "is from someone blocked" : "was not asked for")
                return
            }
            // Wanted only as a photo, and past its ceiling: the link keeps none, so this holds whatever link brought it.
            if blobExchange.isPhotoOnly(file.hash), file.bytes.count > FileIntake.maxAvatarBytes {
                refuseOversizePhoto(file)
                return
            }
        }
        // Read before the want is forgotten: fetched for an asker alone, and named by no row (knit-ios #20). The rows are
        // read outside a store unit, so a failed read names nothing, and a file a row does name can be refused once while
        // the budget is full. That is the worst of it: the refused memo gates echoes alone, and the next 60 s re-offer
        // wants the blob as ours from the rows, which a cut, a landing and the budget then treat as ours.
        let echoOnly = asAttachment && echo && !named.contains(file.hash)
        if echoOnly, !echoBudgetFits(Int64(file.bytes.count), excluding: file.hash) {
            refuseEchoFile(file)
            return
        }
        let kept = stores.blobs.insert(file.bytes, hash: file.hash, mime: file.mime, storedAt: clock.wallMilliseconds())
        if echoOnly, kept {
            blobExchange.echoBudget.landed(Int64(file.bytes.count))
        }
        // Read back, since a failed insert answers as one already held does: only a blob held has nothing left to resume.
        if stores.blobs.contains(file.hash) {
            partials.drop(file.hash)
        }
        withdrawAsks(file.hash, from: blobExchange.obtained(file.hash, from: file.from))
        syncAcceptedFiles()
        adoptAvatar(file.hash, landedAsEcho: echo)
        notePlainHash(file.hash)
        if stores.messages.attachmentHashes().contains(file.hash) {
            events.append(.attachmentArrived(file.hash))
        }
    }

    /// Whether a pushed photo is its pusher's, and within the photo's ceiling, or else rejected.
    private func takesPush(_ file: InboundFile) -> Bool {
        // The HELLO that names the pusher is unauthenticated, so a push proves nothing alone. Android writes the profile
        // ahead of the push on one link (`MeshManager.kt:2562-2563`), so an honest push always matches. Android adopts any
        // push at once (`pointPeerAtAvatar`); this port adopts only a match (ADR 2026-10.nh55).
        guard stores.peers.peer(file.from)?.advertisedAvatarHash == file.hash else {
            reject(file, "is not the photo its pusher's profile names")
            return false
        }
        // The link stops a push at the ceiling; this holds whatever link brought it (ADR 2026-10.r88m).
        guard file.bytes.count <= FileIntake.maxAvatarBytes else {
            reject(file, "is over the photo's ceiling")
            return false
        }
        return true
    }

    func reject(_ file: InboundFile, _ reason: String) {
        filesRejected += 1
        log.log(.info, "mesh file \(LinkManager.shown(file.hash.string)) from \(file.from) \(reason); dropped")
    }

    /// Shows `hash` as the photo of every peer whose newest profile advertises it, now that its bytes are held
    /// (`resolveAvatarHash`, `InboundPipeline.kt:3302-3311`). The photo each replaces goes once nothing names it. Bytes
    /// over the photo's ceiling, held because a message names them too, are never shown as a face, and are declined as a
    /// photo (ADR 2026-10.r88m). A blocked person's row is never shown it (knit-ios #37): bytes wanted before the block, or
    /// kept for something else, land with their face left as their initial, and an unblock shows them (``restoreFace(of:)``).
    func adoptAvatar(_ hash: BlobHash, landedAsEcho: Bool) {
        let blocked = stores.blocks.blockedNodeIds()
        let advertisers = stores.peers.allPeers().filter { peer in
            peer.advertisedAvatarHash == hash && peer.avatarHash != hash && !blocked.contains(peer.nodeId)
        }
        guard !advertisers.isEmpty else {
            return
        }
        guard isAdoptablePhoto(hash) else {
            // An echo's bytes stay for its asker, who is served them at its next ask: the 30-minute sweep takes them after.
            declinePhoto(hash, releasing: !landedAsEcho)
            return
        }
        for var peer in advertisers {
            let replaced = peer.avatarHash
            peer.avatarHash = hash
            stores.peers.upsert(peer)
            events.append(.peerUpdated(peer.nodeId))
            if let replaced {
                releaseBlob(replaced)
            }
        }
    }
}
