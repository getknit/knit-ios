import KnitStore
public import KnitWire

/// The profile photo's ceiling (ADR 2026-10.r88m, contract `profile-door-cap` section 6): a peer's photo larger than
/// ``FileIntake/maxAvatarBytes`` is never kept or shown as their face, pushed or fetched.
///
/// The fetch carries the ceiling (``BlobExchange/overPhotoCeiling(_:from:)``): the links keep a photo-only want's bytes
/// to it, and a holder past it, by the stream that answered the want or by its `blobhas` size, is passed over for that
/// hash this session, the photo's author included (contract revision 5, knit-next ADR 2026-10.jgeg). A pushed AVATAR
/// past the ceiling is cut off at the link and passes nobody over (contract `ios-avatar-push-mark`). Adoption is the backstop: a held blob
/// over the ceiling is never shown as a face (``isAdoptablePhoto(_:)``), is refused as a photo for the session, and
/// goes once nothing else names it, a message row naming the same bytes keeping it as that message's photo. A message's
/// attachment keeps Android's ceiling, and a blob wanted both ways keeps the larger.
extension MeshEngine {
    // MARK: The signals

    /// An ATTACHMENT `peer` streamed us passed the photo-only ceiling its link kept it under at its header, or its header
    /// declared more (``LinkManager/Event/fileOverLimit(_:from:)``). The link raises it for no other file: a pushed AVATAR
    /// cut off answers no want and passes nobody over (`ceilingOf` and `refuseOver`, knit-next `FileIntake.kt:344-363`
    /// and `:388-398` at `a0b52f865`, contract `ios-avatar-push-mark`). For a want of ours still made only for a profile
    /// photo, `peer` is passed over; a want widened since was the link's business alone (`passOver`'s filter,
    /// `BlobExchange.kt:491-520`). The bytes it still sends are read past, never kept.
    public func fileOverLimit(_ hash: BlobHash, from peer: NodeId) {
        overPhotoCeiling(hash, from: peer, "streamed past the ceiling")
    }

    /// The items of a `blobhas` answer from `peer` that hold a blob wanted only as a profile photo and claim a size over its
    /// ceiling: each passes `peer` over before any byte is asked of it. The size is the holder's own claim, which is why
    /// only that holder pays for it.
    func notePhotoClaims(_ items: [BlobHasItem], from peer: NodeId) {
        for item in items where item.state.isHeld {
            guard let size = item.size, size > Int64(FileIntake.maxAvatarBytes), let hash = BlobHash(item.hash) else {
                continue
            }
            overPhotoCeiling(hash, from: peer, "claims \(size)B")
        }
    }

    /// `peer`'s copy of `hash` is over the photo's ceiling, as `why` says. A want made only for a photo passes `peer` over,
    /// its ask on `peer` withdrawn, and goes on to the next holder now rather than at the next timer. Logged in the blob
    /// exchange's words, the hash's first characters and the holder named.
    private func overPhotoCeiling(_ hash: BlobHash, from peer: NodeId, _ why: String) {
        guard let cancels = blobExchange.overPhotoCeiling(hash, from: peer) else {
            return
        }
        note(["blob photo \(hash.string.prefix(BlobExchange.shownHashCharacters))… from \(peer) \(why): passed over"])
        withdrawAsks(hash, from: cancels)
        stepBlobs([hash])
        syncAcceptedFiles()
    }

    /// A whole file wanted only as a photo whose bytes are over the ceiling, which the link should have stopped: rejected,
    /// and its sender passed over as the link's report would have.
    func refuseOversizePhoto(_ file: InboundFile) {
        reject(file, "is over the photo's ceiling")
        fileOverLimit(file.hash, from: file.from)
    }

    /// Whether a photo want of `hash` is refused this session: the hash is refused as a photo (`want`, `BlobExchange.kt:289`
    /// at knit-next `a0b52f865`). The caller then records nothing, so a want already standing on the hash, an echo or a
    /// message's, goes on as it was, under the attachment's ceiling: never made photo-only by a want that was refused.
    func isRefusedPhoto(_ hash: BlobHash) -> Bool {
        blobExchange.isPhotoRefused(hash)
    }

    /// Forgets the session's photo refusals (``BlobExchange/forgetPhotoRefusals()``), beside the kept prefixes, at the
    /// mesh's start and stop: a session's refusals rest on its links.
    public func forgetPhotoRefusals() {
        blobExchange.forgetPhotoRefusals()
    }

    // MARK: Adoption

    /// Whether the held blob `hash` may be shown as a peer's face: it is held, and no larger than the photo's ceiling. A
    /// size the store cannot read reads as not held, so nothing is adopted on a failed read. The sealed profile's photo
    /// reads it too, inside its unit, and lets a blob go only after the unit commits.
    func isAdoptablePhoto(_ hash: BlobHash) -> Bool {
        stores.blobs.size(of: hash).map { $0 <= FileIntake.maxAvatarBytes } ?? false
    }

    /// Whether the held blob `hash` is over the photo's ceiling. A failed read says no, so it keeps whatever it decides.
    func isOverPhotoCeiling(_ hash: BlobHash) -> Bool {
        stores.blobs.size(of: hash).map { $0 > FileIntake.maxAvatarBytes } ?? false
    }

    /// Declines the held blob `hash` as a peer's photo: refused as a photo for the session first, so no re-want fetches it
    /// again, then let go unless something else names it, a peer's row no longer naming it while it is over the ceiling
    /// (``peerPhotoNamesBlob(_:)``). `releasing` false leaves the bytes to the 30-minute sweep of unnamed blobs: an echo's,
    /// which its asker is still to be served (``isBlobInUse(_:)`` covers it while it is wanted, not once it has landed).
    /// Outside a store unit only: the release reads what names the blob inside one of its own.
    func declinePhoto(_ hash: BlobHash, releasing: Bool = true) { // swiftlint:disable:this discouraged_default_parameter
        blobExchange.refusePhoto(hash)
        log.log(.info, "mesh photo \(LinkManager.shown(hash.string)) is over the photo's ceiling; not shown")
        if releasing {
            releaseBlob(hash)
        }
    }

    /// Clears every peer's face whose held bytes are over the photo's ceiling, as one adopted before the ceiling was, and
    /// declines the blob (the 600 s sweep, and so the start). A size that cannot be read keeps the face.
    func clearOversizePhotos() {
        var declined: Set<BlobHash> = []
        for var peer in stores.peers.allPeers() {
            guard let shown = peer.avatarHash, isOverPhotoCeiling(shown) else {
                continue
            }
            peer.avatarHash = nil
            stores.peers.upsert(peer)
            events.append(.peerUpdated(peer.nodeId))
            declined.insert(shown)
        }
        for hash in declined.sorted() {
            declinePhoto(hash)
        }
    }

    /// Whether a peer's photo `hash`, shown or advertised, names its blob for the collector. Held, by its size alone: not
    /// while it is over the ceiling, so a release removes it, but an in-ceiling copy is named whatever the session refused,
    /// since it may be a peer's face again (a later push of the same hash). Not held, by the refusal: a hash refused as a
    /// photo this session names nothing, so a file of it nobody wants is not taken in. A size the store cannot read, of a
    /// blob it holds, keeps it named.
    func peerPhotoNamesBlob(_ hash: BlobHash) -> Bool {
        if let size = stores.blobs.size(of: hash) {
            return size <= FileIntake.maxAvatarBytes
        }
        return stores.blobs.contains(hash) || !blobExchange.isPhotoRefused(hash)
    }
}

/// What the links were last told to keep as they stream in (``MeshEngine/syncAcceptedFiles()``): the blobs wanted, of
/// those our own, which a cut leaves a prefix of (knit-ios #20), and those kept only to the photo's ceiling.
internal struct AcceptedFiles: Equatable {
    var keys: Set<BlobHash> = []
    var resumable: Set<BlobHash> = []
    var photoOnly: Set<BlobHash> = []
}
