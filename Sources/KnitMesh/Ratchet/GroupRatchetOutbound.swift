import KnitCrypto
import KnitStore
import KnitWire

/// The group form's send rules above its engine, pure (`sealGroupRatchet`, `groupRatchetEligible`, `distributeGroupSeed`,
/// `flushPendingGroupKeysFor`, `redistributeGroupKey`, `groupKeyPayload` and `seedSendFloorOpen` in knit-next's
/// `MeshManager.kt`, and `rejoinRekeyDue` in `InboundPipeline.kt`, at `cbf2a487`): which form one of our group frames takes,
/// whom a minted seed goes to and what it carries, when an unacknowledged seed is sent again, and the two floors held in
/// memory that bound the re-sends and the rekeys. ``MeshEngine``'s group send arm applies them (ADR 2026-10.5sk9, phase
/// P6b).
internal enum GroupRatchetOutbound {
    /// One seed re-send per group, member and pairwise root at most this often (`SEED_RESEND_FLOOR_MS`,
    /// `MeshManager.kt:3496`): every receiver in the field holds the same floor.
    static let seedResendMilliseconds: Int64 = 900_000
    /// One rejoin rekey per group and member at most this often (`REJOIN_REKEY_FLOOR_MS`, `InboundPipeline.kt:3687`), so a
    /// member flipping leave and rejoin cannot make every other member mint and fan seeds out on each turn.
    static let rejoinRekeyMilliseconds: Int64 = 3_600_000

    /// The form one of our group frames takes (`sealEnvelopeFor`'s group arm, `MeshManager.kt:1304-1306`).
    enum Form: Equatable {
        /// The group form: every other member can read it, and a minted seed goes to each of these.
        case groupForm([GroupSeedTarget])
        /// v1, its key wrapped to each of these bundles: the members a pinned bundle names, the rest `unkeyed`.
        case staticKeys([NodeId: PublicKeyBundle], unkeyed: [NodeId])

        /// The bundles a v1 seal of this frame wraps to, the group form's members' included, for its fallback.
        var bundles: [NodeId: PublicKeyBundle] {
            switch self {
            case .groupForm(let targets):
                Dictionary(uniqueKeysWithValues: targets.map { ($0.member, $0.bundle) })
            case .staticKeys(let bundles, _):
                bundles
            }
        }
    }

    /// One member of a group as a send reads it: the node id its roster entry parses as, `nil` for one that does not,
    /// which no key is ever pinned for, and the row pinned for it.
    struct Member {
        let nodeId: NodeId?
        let row: PeerRecord?
    }

    /// The members of `group` a frame of ours goes to: its effective roster but `me`, by their bytes, in roster order
    /// (`group.members.filter { it != me }`, `MeshManager.kt:1325`).
    static func others(in group: GroupRecord, me: NodeId) -> [String] {
        let mine = ExactKey(me.string)
        return group.members.filter { ExactKey($0) != mine }
    }

    /// The form a frame to `members`, read once, takes with the switch at `ratchet` (`sealGroupRatchet` and
    /// `groupRatchetEligible`, `MeshManager.kt:1319-1353`): the group form only when there is at least one member and every
    /// one of them has a pinned bundle, a profile carrying `CAP_RATCHET` and a valid prekey, since the seed rides the DM
    /// ratchet; otherwise v1 to the bundles pinned, which every build reads, re-evaluated at every send. A member whose id
    /// does not parse keeps the group v1 and is skipped from the wraps, as the v1 seal has always skipped it, and a
    /// member with no bundle is unkeyed, for a key request. A blocked member is a member like any other: blocking is
    /// presentation (ADR 2026-10.5wgg), and withholding a seed would show the block.
    static func form(of members: [Member], ratchet: Bool) -> Form {
        var bundles: [NodeId: PublicKeyBundle] = [:]
        var unkeyed: [NodeId] = []
        var targets: [GroupSeedTarget] = []
        var eligible = ratchet && !members.isEmpty
        for member in members {
            guard let nodeId = member.nodeId else {
                eligible = false
                continue
            }
            guard let row = member.row, let bundle = PublicKeyBundle(encoded: row.publicKey) else {
                unkeyed.append(nodeId)
                eligible = false
                continue
            }
            bundles[nodeId] = bundle
            let prekey = RatchetOutbound.pinnedPrekey(of: row, signedBy: bundle)
            if Capabilities(rawValue: row.capabilities ?? 0).contains(.ratchet), let prekey {
                targets.append(GroupSeedTarget(member: nodeId, bundle: bundle, prekey: prekey))
            } else {
                eligible = false
            }
        }
        return eligible ? .groupForm(targets) : .staticKeys(bundles, unkeyed: unkeyed)
    }

    /// Whom a re-sent seed goes to, from the row pinned for `member` (`sendSeedDm`, `MeshManager.kt:1388-1393`): any pinned
    /// bundle, with its verified prekey when one is pinned, and no capability asked for, as Kotlin asks none there. With no
    /// session and no prekey the DM ratchet refuses before any key moves, and nothing goes.
    static func seedTarget(_ member: NodeId, row: PeerRecord?) -> GroupSeedTarget? {
        guard let row, let bundle = PublicKeyBundle(encoded: row.publicKey) else {
            return nil
        }
        return GroupSeedTarget(member: member, bundle: bundle, prekey: RatchetOutbound.pinnedPrekey(of: row, signedBy: bundle))
    }

    /// The `CTL_GROUP_KEY` plaintext carrying `keys` for `group` (`groupKeyPayload`, `MeshManager.kt:1500-1515`): always the
    /// group's founding roster beside them (spec C-3.2-16), so a member holding no row pins the group from the seed, and
    /// never a root (`gr`), which this port does not send (ADR 2026-10.5sk9). Always the named layout: a ctl with `gk` has no
    /// compact form, and a seed is v2.
    static func seed(_ keys: [GroupSeed], of group: GroupRecord) -> MessageContent {
        let payload = GroupKeyPayload(groupId: group.id, keys: keys, group: founding(group))
        return MessageContent(body: "", ctl: MessageContent.Control.groupKey, gk: payload)
    }

    /// The roster half of the frames' self-describing roster (`toFoundingInfo`, `GroupEntity.kt:87`): the founding set, the
    /// creator and the name, never the photo, which is a blob that rides the group's own frames.
    static func founding(_ group: GroupRecord) -> GroupInfo {
        var info = group.info
        info.photoHash = nil
        info.photoUpdatedAt = nil
        return info
    }

    /// The seed a member is owed again, or `nil` (`flushPendingGroupKeysFor`'s seed half, `MeshManager.kt:1452`): our
    /// newest retained seed when the outbox says the member never acknowledged it, or always under `force`, which only a
    /// peer's reset passes, since the reset means the ack predates the wipe it just recovered from. Never one when we hold
    /// no live send chain, a retired one included, which has no seed to serve.
    static func seedOwed(newest: GroupSeed?, outbox: GroupKeySendRecord?, force: Bool) -> GroupSeed? {
        guard let newest else {
            return nil
        }
        let acknowledged = outbox.map { $0.ackedEpoch >= newest.epoch } ?? false
        return force || !acknowledged ? newest : nil
    }
}

/// The two floors our group sends hold in memory, as Kotlin holds them, which die with the process (phase P6b): the seed
/// re-send floor per group and member (`lastSeedSendAt`, `MeshManager.kt:1412-1421`) and the rejoin rekey floor per group
/// and member (`lastRejoinRekeyAt`, `InboundPipeline.kt:2305-2321`). Both run on our monotonic clock, as this port's other
/// floors in memory do, where Kotlin reads its wall clock; and both move only once the unit that acted on them commits,
/// where Kotlin stamps them as it checks.
internal struct GroupSendFloors {
    /// A group and one of its members: the group by its bytes (ADR 2026-09.jc2x).
    struct Key: Hashable {
        let group: ExactKey
        let member: NodeId

        init(_ group: String, _ member: NodeId) {
            self.group = ExactKey(group)
            self.member = member
        }
    }

    /// When a seed last went to a member, and the fingerprint of the pairwise root it went under, `nil` for none: the
    /// root's tag, never the root (``RatchetCrypto/rootTag(_:)``).
    struct SeedSend: Equatable {
        let at: Int64
        let root: Int64?
    }

    private(set) var seeds: [Key: SeedSend] = [:]
    private(set) var rejoins: [Key: Int64] = [:]

    /// Whether a seed may go to `member` in `group` at `now`, the pairwise root we hold with it now fingerprinted as `root`
    /// (`seedSendFloorOpen`, `MeshManager.kt:1829-1849`, ADR 2026-09.qerd): a seed sent under a root the member has since
    /// left is one it can never open, so it never holds back the one that replaces it; under an unchanged root, once per
    /// ``GroupRatchetOutbound/seedResendMilliseconds``, forced or not.
    func seedMayGo(in group: String, to member: NodeId, root: Int64?, now: Int64) -> Bool {
        guard let last = seeds[Key(group, member)], last.root == root else {
            return true
        }
        return now &- last.at >= GroupRatchetOutbound.seedResendMilliseconds
    }

    /// Stamps a seed's send to `member` in `group` at `now`, under the root fingerprinted as `root`.
    mutating func seedWent(in group: String, to member: NodeId, root: Int64?, now: Int64) {
        seeds[Key(group, member)] = SeedSend(at: now, root: root)
    }

    /// Whether `member`'s rejoin of `group` at `now` retires our send chains (`rejoinRekeyDue`, `InboundPipeline.kt:2310-2321`):
    /// the first, and then one per ``GroupRatchetOutbound/rejoinRekeyMilliseconds``. The rejoin itself always lands.
    func rekeyDue(in group: String, for member: NodeId, now: Int64) -> Bool {
        rejoins[Key(group, member)].map { now &- $0 >= GroupRatchetOutbound.rejoinRekeyMilliseconds } ?? true
    }

    /// Stamps a rejoin rekey of `member`'s in `group` at `now`.
    mutating func rekeyed(in group: String, for member: NodeId, now: Int64) {
        rejoins[Key(group, member)] = now
    }
}

/// One member a seed of ours goes to (phase P6b): the bundle pinned for it, whose node id keys the DM session, and its verified
/// prekey, if one is pinned, so a seed starts a session where none is held.
internal struct GroupSeedTarget: Equatable {
    let member: NodeId
    let bundle: PublicKeyBundle
    let prekey: PeerPrekey?
}
