import KnitCrypto
import KnitStore
import KnitWire

/// Our group seeds sent again, with the switch on (ADR 2026-10.5sk9, phase P6b): `flushPendingGroupKeysFor`,
/// `redistributeGroupKey` and `seedSendFloorOpen` in knit-next's `MeshManager.kt` (at `cbf2a487`, `:1412-1484` and
/// `:1829-1849`). The outbox, not custody, is the truth of what a member holds: a seed it never acknowledged goes again on
/// the member's profile, at each link-up and 60-second re-offer, and after its reset, forced past the outbox's ack; a key
/// request is answered with every seed we retain. Each re-send is floored per group, member and pairwise root
/// (``GroupSendFloors``), never advances the epoch, and goes in a store unit of its own, the outermost: the seeds and the
/// member's row read, the floor checked, the DM ratchet's seal, the outbox's row and our custody's copy inside it, and the
/// seed on the air, the floor's stamp and the count only once it commits. A root-only send (`gr`) never happens here.
extension MeshEngine {
    /// Sends `member` again, in every group not left that we share with it, our newest seed its outbox row shows unacknowledged
    /// (`flushPendingGroupKeysFor`, `MeshManager.kt:1444-1470`): with `force`, which only its reset passes, past the
    /// outbox's ack, since that ack predates the wipe the reset recovers from. Floored either way, so neither a reset nor a
    /// link that flaps re-sends more than once per floor under one root. Never to ourselves, which no outbox row of ours names.
    func flushPendingGroupKeys(for member: NodeId, force: Bool) {
        guard configuration.ratchet, member != nodeId else {
            return
        }
        let key = ExactKey(member.string)
        for group in stores.groups.groups() where !group.hasLeft && group.members.contains(where: { ExactKey($0) == key }) {
            resendSeeds(in: group.id, to: member, what: force ? "forced group seed" : "group seed") { () -> SeedsOwed? in
                guard case .joined(let seeds, _) = groupRatchet.currentSeeds(of: group.id),
                    case .joined(let outbox, _) = groupRatchet.keySend(to: member, in: group.id),
                    let owed = GroupRatchetOutbound.seedOwed(newest: seeds.first, outbox: outbox, force: force)
                else {
                    return nil
                }
                return SeedsOwed(group: group, seeds: [owed])
            }
        }
    }

    /// Answers `requester`'s `CTL_GROUP_KEY_REQ` for `groupId`, once its DM's unit committed (`redistributeGroupKey`,
    /// `MeshManager.kt:1474-1484`): for a group we hold and have not left, whose effective roster has the requester, our
    /// current and draining seeds in one ctl DM, floored, never advancing the epoch, since a request that advanced it would
    /// hand any member a rekey fan-out.
    func redistributeGroupKey(in groupId: String, to requester: NodeId) {
        guard configuration.ratchet, requester != nodeId else {
            return
        }
        resendSeeds(in: groupId, to: requester, what: "key request's answer") { () -> SeedsOwed? in
            // Held, not left, and the requester on the effective roster: the same three a seed's adoption asks of its sender.
            guard let group = stores.groups.group(groupId), GroupRatchetInbound.admitsSeeds(of: requester, in: group),
                case .joined(let seeds, _) = groupRatchet.currentSeeds(of: groupId), !seeds.isEmpty
            else {
                return nil
            }
            return SeedsOwed(group: group, seeds: seeds)
        }
    }

    /// Seals and sends `member` the seeds `owed` answers, read inside the unit, in a unit of its own, floored as the type's
    /// doc says, logged as `what`. The floor reads the pairwise root's fingerprint before the seal and is stamped with the
    /// root the seed went under once the unit commits, where Kotlin stamps the root it read before (`:1844-1847`): a seed
    /// that starts a session goes under that session's root, so the next trigger under it is floored rather than sent again
    /// at once. A seal that cannot be made once the floor opened stamps it all the same, as Kotlin's does, so a member we
    /// cannot seal to costs one try per floor; a unit that fails stamps nothing.
    private func resendSeeds(in groupId: String, to member: NodeId, what: String, owed: () -> SeedsOwed?) {
        let monotonic = clock.monotonicMilliseconds()
        var opened: Int64??
        let unit = stores.transactor.atomically { () -> (SealedSeed, root: Int64?)? in
            guard let due = owed(), let newest = due.seeds.first else {
                return nil
            }
            let root = rootTag(of: member)
            guard groupFloors.seedMayGo(in: groupId, to: member, root: root, now: monotonic) else {
                return nil
            }
            opened = .some(root)
            let now = clock.wallMilliseconds()
            guard let target = GroupRatchetOutbound.seedTarget(member, row: stores.peers.peer(member)),
                let sealed = sealSeed(
                    GroupRatchetOutbound.seed(due.seeds, of: due.group), epoch: newest.epoch, to: target, in: groupId, now: now)
            else {
                return nil
            }
            return (sealed, rootTag(of: member))
        }
        switch unit {
        case .committed(let (sealed, root)):
            fly(sealed)
            groupFloors.seedWent(in: groupId, to: member, root: root, now: monotonic)
            log.log(.info, "mesh sent \(member) the \(what) for \(groupId) as \(sealed.own.frame.envelope.id)")
        case .abandoned:
            if case .some(let root) = opened {
                groupFloors.seedWent(in: groupId, to: member, root: root, now: monotonic)
                log.log(.info, "mesh no \(what) for \(groupId) to \(member): nothing to seal it with")
            }
        case .failed:
            log.log(.warning, "mesh no \(what) for \(groupId) to \(member): a store failed")
        case .joined:
            // Nothing opens a unit around these calls, so a joined seal cannot happen here.
            log.log(.warning, "mesh no \(what) for \(groupId) to \(member): asked for inside a store unit")
        }
    }

    /// The fingerprint of the pairwise root we hold with `peer`, its tag (``RatchetCrypto/rootTag(_:)``), never the root, or
    /// `nil` with no session: read inside the caller's unit, so a read that fails fails it.
    private func rootTag(of peer: NodeId) -> Int64? {
        stores.ratchet.session(peer).map { RatchetCrypto.rootTag($0.root) }
    }
}

/// The seeds a re-send owes one member of a group, as read inside its unit.
private struct SeedsOwed {
    let group: GroupRecord
    let seeds: [GroupSeed]
}
