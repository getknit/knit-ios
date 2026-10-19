import KnitStore
import KnitWire

/// The group form's seeds received in the mesh, with the switch on (ADR 2026-10.5sk9, phase P6a2): `holdGroupKeyForUnknownGroup`,
/// `pinRosterFromSeed`, `replayHeldGroupKeys`, `adoptGroupSeeds` and `ackGroupSeed` in knit-next's `InboundPipeline.kt` (at
/// `cbf2a487`, `:1440-1585`), the ack's half of `applyCtlInTxn` (`:1213-1217`), and `replayCustodiedSeedDms`
/// (`MeshManager.kt:1772-1830`).
///
/// A seed rides a `CTL_GROUP_KEY` DM, and its adoption commits in that DM's open unit, or nothing does. A seed for a group
/// we do not hold yet, or from a sender we hold as departed, waits for its roster before anything commits: it pins the
/// roster it carries through the one door every roster takes (``reconcile(_:from:_:seedPinning:origin:)``), or parks in memory
/// (``PendingGroupKeys``) until a roster lets its sender in. Everything that is not a store write, the floor's move, the
/// ack and the custody replay, waits for the outermost commit.
extension MeshEngine {
    /// Adopts the seeds `seeds` carries from `sender`, inside the open's unit of the DM that carried them (`adoptGroupSeeds`,
    /// `InboundPipeline.kt:1535-1548`): only for a group we hold, have not left, and whose effective roster has the sender,
    /// and only when it carries keys. A root-only distribution commits the chain's advance and nothing else, its `gr` kept
    /// raw and never acted on. The facade's adoption joins the unit, and a store that fails fails it.
    func adoptGroupSeeds(_ seeds: GroupKeyPayload?, from sender: NodeId) -> SeedAdoption? {
        guard let seeds, !seeds.keys.isEmpty, GroupRatchetInbound.admitsSeeds(of: sender, in: stores.groups.group(seeds.groupId)) else {
            return nil
        }
        // Joined is the one answer inside the DM's unit that stands; a store that failed has failed that unit already.
        let answer = groupRatchet.adoptSeeds(seeds.keys, in: seeds.groupId, from: sender, now: clock.wallMilliseconds())
        guard case .joined(let adoption, let settlement) = answer else {
            return nil
        }
        return SeedAdoption(group: seeds.groupId, ackEpoch: adoption.ackEpoch, freshChains: adoption.freshChains, settlement: settlement)
    }

    /// Records a member's `CTL_GROUP_KEY_ACK` in the seed outbox, inside the open's unit of the DM that carried it (`onKeyAck`,
    /// `InboundPipeline.kt:1213-1217`): only a newer epoch moves the row, and an ack with no row is ignored. A store that fails
    /// fails the unit.
    func recordSeedAck(_ seeds: GroupKeyPayload?, from sender: NodeId) {
        guard let seeds, let epoch = seeds.ackEpoch else {
            return
        }
        _ = groupRatchet.onKeyAck(epoch, from: sender, in: seeds.groupId, now: clock.wallMilliseconds())
    }

    /// After the outermost commit, the group facade's floor moves for what the DM's unit adopted, and the fresh chains are
    /// counted. Called before anything else may open, so the next DM's adoption reads the floor as it now stands.
    func settleSeeds(_ seeds: SeedAdoption?) {
        guard let seeds else {
            return
        }
        groupRatchet.settle(seeds.settlement)
        groupCounts.groupSeedsAdopted += seeds.freshChains
    }

    /// Acknowledges `epoch` of our adopted seeds in `group` back to `sender` (`ackGroupSeed`, `InboundPipeline.kt:1554-1585`):
    /// a `CTL_GROUP_KEY_ACK`, always v2, sealed through the DM ratchet in a unit of its own and originated once it commits, so
    /// the sender's outbox stops re-sending. Best effort: a lost ack costs one idempotent re-distribution later, and a seal
    /// that cannot be made sends nothing, as Kotlin's `sealDm` answering null does.
    func acknowledgeSeeds(_ epoch: Int, in group: String, to sender: NodeId) {
        let ack = MessageContent(body: "", ctl: MessageContent.Control.groupKeyAck, gk: GroupKeyPayload(groupId: group, ackEpoch: epoch))
        let what = "ack of group seed \(epoch) for \(group)"
        let sent = sendMachinery(ack, to: sender, what: what) { GroupRatchetInbound.seedAckPlan(to: stores.peers.peer(sender)) }
        if let id = sent {
            log.log(.info, "mesh sent \(sender) the \(what) as \(id)")
        }
    }

    /// The group form's machinery, `content`, sealed to `peer` through the DM ratchet in a unit of its own, as `plan` says,
    /// originated once it commits (``sealControl(_:to:in:plan:)``), and answers its frame's id, or `nil`, logged as `what`,
    /// when nothing went: no way to seal it, or a store that failed.
    func sendMachinery(_ content: MessageContent, to peer: NodeId, what: String, plan: () -> RatchetOutbound.ReceiptPlan?) -> String? {
        switch sealControl(content, to: peer, in: .machinery, plan: plan) {
        case .sealed(let sealed):
            originateSealed(sealed)
            return sealed.frame.envelope.id
        case .unreadable, .unsealable:
            log.log(.info, "mesh no \(what) to \(peer): nothing to seal it with")
        case .failed, .joined:
            // Nothing opens a unit around these calls, so a joined seal cannot happen here.
            log.log(.warning, "mesh no \(what) to \(peer): a store failed")
        }
        return nil
    }

    /// A seed from `sender` whose open was abandoned because its roster is not here (`holdGroupKeyForUnknownGroup`,
    /// `InboundPipeline.kt:1454-1478`): with nothing committed, it pins the roster it carries, if any, through the one door
    /// every roster takes (`pinRosterFromSeed`, `:1490-1497`), and opens again on the ordinary path once that row admits the
    /// sender. Otherwise it parks, its chain left where it was, and a park already full for its group lets it take the
    /// ordinary path, where the frame commits with nothing adopted, as Kotlin's does.
    ///
    /// Only at its first verdict. Out of our own custody at start (``RatchetInbound/Origin/startReplay``) it is left
    /// unopened instead: the park is in memory, and custody already holds the frame for the replay at its group's first
    /// sight (``replayCustodiedSeedDirectMessages(of:except:)``), which is where a park that died with the process comes
    /// back.
    func seedAwaitsRoster(
        _ envelope: RelayEnvelope, _ enc: EncEnvelope, _ seeds: GroupKeyPayload, sender: NodeId, route: RatchetInbound.Route
    ) {
        guard route.origin == .firstVerdict else {
            log.log(.info, "mesh group seed \(envelope.id) from \(sender) left in custody: no roster for group \(seeds.groupId)")
            return
        }
        let roster = GroupRatchetInbound.roster(pinnedBy: seeds)
        if let roster, reconcile(roster, from: sender, envelope, seedPinning: envelope.id, origin: route.origin) {
            log.log(.info, "mesh pinned group \(seeds.groupId) from the seed \(envelope.id) of \(sender)")
        }
        let group = stores.groups.group(seeds.groupId)
        guard GroupRatchetInbound.awaitsRoster(group, from: sender) else {
            openRatchetDirect(envelope, enc, sender: sender, route: route, parksSeeds: false)
            return
        }
        switch pendingGroupKeys.hold(envelope, for: seeds.groupId, route: route, now: clock.monotonicMilliseconds()) {
        case .parked:
            groupCounts.groupSeedsHeld += 1
            let why = group == nil ? "not held yet" : "sender departed"
            log.log(.info, "mesh holding group key \(envelope.id) from \(sender): group \(seeds.groupId) \(why)")
        case .alreadyParked:
            return
        case .full:
            openRatchetDirect(envelope, enc, sender: sender, route: route, parksSeeds: false)
        }
    }

    /// What a roster that just landed in `group` lets in (`reconcileGroup`'s second half, `InboundPipeline.kt:2167-2178`):
    /// the seeds parked for it whose sender the row admits, and at its first sight the ratchet DMs our custody holds from
    /// its roster, all but `except` and the seeds just released, which have opened already: opened again, each would only
    /// drop as `DUPLICATE`.
    func seedsMayLand(in group: GroupRecord, firstSight: Bool, except: String?) {
        let released = releaseHeldSeeds(of: group)
        if firstSight {
            replayCustodiedSeedDirectMessages(of: group, except: Set(([except].compactMap(\.self) + released).map(ExactKey.init)))
        }
    }

    /// Opens again, past the router, every seed parked for `group` whose sender the row as it now stands does not hold as
    /// departed (`replayHeldGroupKeys`, `InboundPipeline.kt:1505-1527`), oldest first, each as it came: the open that was
    /// abandoned commits now and adopts. A departed sender's seed waits for that sender's own rejoin, in place, its clock
    /// untouched, so no other member's traffic keeps it alive.
    @discardableResult
    func releaseHeldSeeds(of group: GroupRecord) -> [String] {
        let departed = Set(group.departed.map(ExactKey.init))
        let released = pendingGroupKeys.release(group.id) { !departed.contains(ExactKey($0.envelope.senderId)) }
        for parked in released {
            groupCounts.groupSeedsReplayed += 1
            handleChat(parked.envelope, via: parked.route.hop, signed: parked.route.signed, origin: parked.route.origin)
        }
        return released.map(\.envelope.id)
    }

    /// Opens again, at `group`'s first sight, every ratchet DM to us our own custody holds from its effective roster with no
    /// row, by `sentAt`, oldest first, so a chain walks forward, but those `except` names (`replayCustodiedSeedDms`,
    /// `MeshManager.kt:1772-1830`). A seed that parked and died with the process was custodied before it parked, and no
    /// neighbour serves it again since our digest lists it: this is where it opens. A DM already delivered stops at its row,
    /// read in a unit of its own, and a ctl the ratchet already consumed drops as `DUPLICATE`.
    ///
    /// It opens them as the start's replay does, with the era held (``RatchetInbound/Origin/startReplay``), where Kotlin's
    /// opens them as first verdicts: our custody keeps a day of these frames, and one whose first verdict committed in an
    /// era the pair has since left would open under its draining root and, as a first verdict, apply a reaction or a
    /// profile again, re-seal for a reset, or race the session with its old init. A seed never committed opens all the same,
    /// unless it carries an init the held session has not resolved, which then waits for the sender's re-send.
    func replayCustodiedSeedDirectMessages(of group: GroupRecord, except skipped: Set<ExactKey>) {
        let me = ExactKey(nodeId.string)
        let senders = Set(group.members.map(ExactKey.init)).subtracting([me])
        let frames = stores.custody.liveFrames(now: clock.wallMilliseconds()).reversed().filter { carried in
            let envelope = carried.envelope
            guard envelope.type == .chat, envelope.group == nil, envelope.recipientId.map(ExactKey.init) == me,
                senders.contains(ExactKey(envelope.senderId)), !skipped.contains(ExactKey(envelope.id)),
                let enc = (try? ChatContent(decoding: envelope.payload))?.enc
            else {
                return false
            }
            // The ratchet's forms only: its `DUPLICATE` is what makes opening a consumed one again harmless, and a seed is
            // never anything else. A v1 DM has no such guard.
            return RatchetInbound.isDirectRatchet(enc)
        }
        // A stable order by the sender's stamp, ties left in custody's order.
        let ordered = frames.enumerated().sorted { ($0.element.envelope.sentAt, $0.offset) < ($1.element.envelope.sentAt, $1.offset) }
        for (_, carried) in ordered {
            replayUnread(carried)
        }
    }
}
