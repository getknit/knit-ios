import KnitStore
public import KnitWire

/// Blocking (ADR 2026-10.5wgg, after knit-next's ADRs 010 and 2026-09.bts9). A block is presentation only: it is read
/// on the delivery path, where a blocked sender's messages are neither stored nor notified, and never by custody, the
/// relay, key exchange or receipts, so a blocker carries, relays and accounts their frames like any other node's and
/// every node's digest still converges.
extension MeshEngine {
    /// Blocks `peer`, and the device tag their profile carried, so the block holds when they make new keys
    /// (`SettingsStore.block`). Our own id is never blocked.
    public func block(_ peer: NodeId) {
        guard peer != nodeId else {
            return
        }
        stores.blocks.block(peer, deviceTag: stores.peers.peer(peer)?.deviceTag)
    }

    /// Unblocks `peer`, and the device tag their profile carried (`SettingsStore.unblock`). What they sent before the
    /// block shows again. What they sent during it was never stored: a DM or room post stays unseen, and a group
    /// message our custody still holds is delivered at the next start (``replayCustodiedGroupFrames(in:from:)``), and with
    /// the ratchet's switch on within the hour, as Android's heal delivers it (ADR 2026-10.5sk9).
    public func unblock(_ peer: NodeId) {
        stores.blocks.unblock(peer, deviceTag: stores.peers.peer(peer)?.deviceTag)
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
