import KnitStore
public import KnitWire

/// Blocking (ADR 2026-10.5wgg, after knit-next's ADRs 010 and 2026-09.bts9). A block is presentation only: it is read
/// on the delivery path, where a blocked sender's messages are neither stored nor notified, and never by custody, the
/// relay, key exchange or receipts, so a blocker carries, relays and accounts their frames like any other node's and
/// every node's digest still converges.
///
/// It hides their profile too (ADR 2026-11.y793, knit-ios #37, after knit-next ADR 2026-11.nsbf): a blocked person's
/// profile pins and is carried as anyone's but writes no name, status or photo, their face turns to their initial, and
/// their photo is neither wanted, taken from their push, shown nor named for the collector (``hideBlockedPhotos(of:)``,
/// ``blobsTheRowsName()``). That is this phone's rows and wants alone, which no digest lists, so custody still converges.
/// An unblock shows the profile held for them again (``unblock(_:)``).
extension MeshEngine {
    /// Blocks `peer`, and the device tag their profile carried, so the block holds when they make new keys
    /// (`SettingsStore.block`), and hides their photo at once (``hideBlockedPhotos(of:)``). Our own id is never blocked.
    public func block(_ peer: NodeId) {
        guard peer != nodeId else {
            return
        }
        stores.blocks.block(peer, deviceTag: stores.peers.peer(peer)?.deviceTag)
        hideBlockedPhotos(of: [peer])
    }

    /// Unblocks `peer`, and the device tag their profile carried (`SettingsStore.unblock`). What they sent before the
    /// block shows again. What they sent during it was never stored: a DM or room post stays unseen, and a group
    /// message our custody still holds is delivered at the next start (``replayCustodiedGroupFrames(in:from:)``), and with
    /// the ratchet's switch on within the hour, as Android's heal delivers it (ADR 2026-10.5sk9). So is their leave from a
    /// group, or their roster frame, where Android keeps a blocked member's leave lost for good (phase P7a).
    ///
    /// When `peer` was blocked, by id or by their row's tag, the profile kept as their key's proof shows again
    /// (``reapplyHeldProfile(of:)``), and then their face (``restoreFace(of:)``), with no frame kept too, since the row kept
    /// the photo they advertised (contract revision 1 of `block-hides-profile`). An unblock of nobody blocked moves nothing.
    public func unblock(_ peer: NodeId) {
        let tag = stores.peers.peer(peer)?.deviceTag
        let wasBlocked = isBlocked(peer) || tag.map(stores.blocks.isBlocked(deviceTag:)) == true
        stores.blocks.unblock(peer, deviceTag: tag)
        guard wasBlocked else {
            return
        }
        _ = reapplyHeldProfile(of: peer)
        restoreFace(of: peer)
    }

    /// Shows again the photo `peer`'s row advertises, once their block is lifted, whatever the re-apply decided: held and
    /// within the photo's ceiling, at once; held over it, declined; not held, wanted as a photo of anyone who has it, `peer`
    /// too when linked, even when the row already names it as its face (``followAdvertisedPhoto(_:of:askingLinked:)``). A
    /// photo refused this session stays refused (``wantBlob(_:author:via:asker:reach:kind:)``). After the unblock, which
    /// the follow reads. The face the row showed before is not let go here: the block cleared it, and the sweep takes the rest.
    func restoreFace(of peer: NodeId) {
        guard var row = stores.peers.peer(peer), let advertised = row.advertisedAvatarHash else {
            return
        }
        guard isAdoptablePhoto(advertised) else {
            followAdvertisedPhoto(advertised, of: peer, askingLinked: true)
            return
        }
        if row.avatarHash != advertised {
            row.avatarHash = advertised
            stores.peers.upsert(row)
            events.append(.peerUpdated(peer))
        }
    }

    /// The "on block" step for `peers`, all blocked (knit-ios #37): each row's face is cleared, its advertised photo kept for
    /// an unblock, so their initial shows, and then the wants of our own for a blocked person's photo are withdrawn
    /// (``withdrawBlockedPhotos()``). A row with no face is left alone, so the sweep's pass over every blocked id is a no-op
    /// the second time. Never ``releaseBlob(_:)``: the bytes go by the 30-minute sweep of unnamed blobs once nothing uses
    /// them (``isBlobInUse(_:)``), so a copy on its way, or served to an asker, is not cut. Run by ``block(_:)``, by a block
    /// that followed new keys (``continueBlock(of:deviceTag:)``'s callers), and by the sweep for every blocked id, which
    /// covers a block written past the engine (a restore, the demo, the debug bridge). An empty `peers` does nothing.
    func hideBlockedPhotos(of peers: Set<NodeId>) {
        guard !peers.isEmpty else {
            return
        }
        for peer in peers.sorted() {
            guard var row = stores.peers.peer(peer), row.avatarHash != nil else {
                continue
            }
            row.avatarHash = nil
            stores.peers.upsert(row)
            events.append(.peerUpdated(peer))
        }
        withdrawBlockedPhotos()
    }

    /// Withdraws each want of our own for a photo only a blocked person's row advertises, as a want for a room photo the
    /// bound leaves out is (``withdrawLeftOutRoomPhotos()``): forgotten, and every holder still asked sent a `blobcancel`
    /// (knit-next ADR 2026-10.nsr7). Only a want of ours made as a photo alone: a want of an attachment's clears its
    /// `photoOnly`, and an echo is an asker's, so both stand, as does one an unblocked peer's row also advertises. Nor one
    /// we pull for a neighbour too (its `pullers`), which would cut the copy that neighbour waits for: it lands, is shown on
    /// no blocked row (``adoptAvatar(_:landedAsEcho:)``), and goes by the sweep. Nor one whose bytes are already arriving.
    ///
    /// The block list and the rows are read in one store unit, and nothing is withdrawn unless it commits: outside one a
    /// failed read of the rows would see no unblocked contact advertising the photo, and withdraw a want they need. At the
    /// head of each re-want too (``rewantMissingBlobs(sparing:)``), so a want an older pass made goes at the next.
    func withdrawBlockedPhotos() {
        let unit = stores.transactor.atomically { () -> [BlobHash]? in
            let blocked = stores.blocks.blockedNodeIds()
            guard !blocked.isEmpty else {
                return []
            }
            let rows = stores.peers.allPeers()
            let theirs = Set(rows.filter { blocked.contains($0.nodeId) }.compactMap(\.advertisedAvatarHash))
            let others = Set(rows.filter { !blocked.contains($0.nodeId) }.compactMap(\.advertisedAvatarHash))
            return theirs.subtracting(others).filter { hash in
                blobExchange.wants[hash].map { $0.origin == .own && $0.photoOnly && $0.pullers.isEmpty } ?? false
            }.sorted()
        }
        guard case .committed(let photos) = unit else {
            return
        }
        let arriving = transport.arrivingFileKeys
        let withdrawn = photos.filter { !arriving.contains($0) }
        guard !withdrawn.isEmpty else {
            return
        }
        for hash in withdrawn {
            log.log(.debug, "mesh blob \(LinkManager.shown(hash.string)) want withdrawn (someone blocked)")
            withdrawAsks(hash, from: blobExchange.obtained(hash, from: nil))
        }
        syncAcceptedFiles()
    }

    /// Whether the user blocked `sender`.
    func isBlocked(_ sender: NodeId) -> Bool {
        stores.blocks.blockedNodeIds().contains(sender)
    }

    /// Drops a chat frame from a blocked sender, with what it still earns (`InboundPipeline.ackBlockedRoomChat`,
    /// `InboundPipeline.kt:903-915`): a room post its tick, and a group message one when the group is ours and we have not
    /// left it, owed as any other's is, the group's free to go into custody. That tick is fragile, so withholding it could
    /// strand the sender's ✓✓ when we are their only acker, and would tell them they are blocked (knit-next ADR 010). A DM
    /// gets nothing: its receipt floods and is carried, and would purge the DM from every carrier's custody.
    func dropBlocked(_ envelope: RelayEnvelope, sender: NodeId) {
        drop(.blocked, envelope)
        if let group = envelope.group {
            if let held = stores.groups.group(group.id), !held.hasLeft {
                tickPost(envelope.id, author: sender, escalatable: true)
            }
        } else if envelope.recipientId == nil {
            tickPost(envelope.id, author: sender, escalatable: false)
        }
    }

    /// Whether a group frame from `sender` is refused for a block (`InboundPipeline.groupFrameRefused`): a blocked
    /// sender, or the first frame of a group a blocked person made, which a member we have not blocked may relay.
    func isBlockedGroupFrame(_ info: GroupInfo, from sender: NodeId, existing: GroupRecord?) -> Bool {
        let blocked = stores.blocks.blockedNodeIds()
        if blocked.contains(sender) {
            return true
        }
        return existing == nil && NodeId(info.createdBy).map(blocked.contains) == true
    }

    /// Keeps a block on someone who made new keys (`InboundPipeline.applyDeviceTagBlockContinuity`): a profile from a
    /// node id we have not blocked, carrying a device tag we have, blocks that node id too. Runs before the frames
    /// parked for its key are released, so they meet the block. Answers whether it blocked anyone.
    func continueBlock(of sender: NodeId, deviceTag: String?) -> Bool {
        guard let deviceTag, stores.blocks.isBlocked(deviceTag: deviceTag), !isBlocked(sender) else {
            return false
        }
        stores.blocks.block(sender, deviceTag: deviceTag)
        log.log(.info, "mesh blocked \(sender), whose device tag is blocked")
        return true
    }
}
