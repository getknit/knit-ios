import KnitCrypto
import KnitStore
import KnitWire

/// The group form's receive rules above its engine, pure (`decryptAndDeliverGroup`, `onGroupRatchetFailure`,
/// `maybeRequestGroupKey`, `holdGroupKeyForUnknownGroup`, `pinRosterFromSeed`, `adoptGroupSeeds` and `ackGroupSeed` in
/// knit-next's `InboundPipeline.kt`, at `cbf2a487`, `:1440-1730`): which seeds wait for their roster, which a roster
/// admits, what a refusal records, which refusals ask the sender for its key, and what a request and an ack are sealed
/// toward. ``MeshEngine``'s group arm applies them (ADR 2026-10.5sk9, phase P6a2).
internal enum GroupRatchetInbound {
    /// The drop a typed refusal records (`onGroupRatchetFailure`, `InboundPipeline.kt:1675-1682`).
    static func dropReason(for failure: GroupRatchetEngine.OpenOutcome.Failed) -> DropReason {
        switch failure {
        case .noKey:
            .groupRatchetNoKey
        case .duplicate:
            .groupRatchetDuplicate
        case .badHeader:
            .groupRatchetBadHeader
        case .aeadFail:
            .groupRatchetAeadFail
        }
    }

    /// Whether a refusal means the seed the frame needs is missing, never arrived or lost, or an era the sender left after
    /// a wipe, and so feeds the key-request heuristic (`:1686-1688`). `DUPLICATE` is a re-serve and `BAD_HEADER` a
    /// malformed frame: neither says anything about the seeds we hold.
    static func asksForKey(_ failure: GroupRatchetEngine.OpenOutcome.Failed) -> Bool {
        failure == .noKey || failure == .aeadFail
    }

    /// The seed distribution `content` carries, or `nil` when it is no `CTL_GROUP_KEY` with a payload: the only ctl the
    /// roster gate looks at (`holdGroupKeyForUnknownGroup`, `:1459-1460`).
    static func seeds(in content: MessageContent) -> GroupKeyPayload? {
        content.ctl == MessageContent.Control.groupKey ? content.gk : nil
    }

    /// Whether a seed from `sender` must wait for a roster before it may commit (`:1463-1472`): we hold no row for its
    /// group, or we hold the sender as departed, whose seed for the re-created group floods ahead of the frame that rejoins
    /// them. Every other shape takes the ordinary path, where ``admitsSeeds(of:in:)`` decides, a group we left included.
    static func awaitsRoster(_ group: GroupRecord?, from sender: NodeId) -> Bool {
        guard let group else {
            return true
        }
        return isDeparted(sender, in: group)
    }

    /// Whether we hold `sender` as departed from `group`, by its bytes.
    static func isDeparted(_ sender: NodeId, in group: GroupRecord) -> Bool {
        group.member(sender.string)?.departed == true
    }

    /// Whether `group` lets `sender`'s seeds be adopted (`adoptGroupSeeds`, `:1541-1543`): we hold it, have not left it,
    /// and the sender is on its effective roster. A departed member's stale distribution and a non-member's noise adopt
    /// nothing, and the frame still commits its chain's advance.
    static func admitsSeeds(of sender: NodeId, in group: GroupRecord?) -> Bool {
        guard let group, !group.hasLeft, let member = group.member(sender.string) else {
            return false
        }
        return !member.departed
    }

    /// The founding roster a seed carries for its own group, which may pin the group (`pinRosterFromSeed`, `:1490-1492`):
    /// none for an older build's seed, and a roster naming another group or over the cap is malformed and ignored, so the
    /// seed parks as one with none.
    static func roster(pinnedBy seeds: GroupKeyPayload) -> GroupInfo? {
        guard let roster = seeds.group, ExactKey(roster.id) == ExactKey(seeds.groupId), roster.members.count <= GroupInfo.maxMembers
        else {
            return nil
        }
        return roster
    }

    /// What a key request toward `peer` is sealed with (`maybeRequestGroupKey`, `:1702-1709`): a pinned profile carrying
    /// `CAP_RATCHET` and a bundle, with its verified prekey when one is pinned, so a request starts a session where none is
    /// held. Always v2, as Kotlin encodes it named (`:1711`); the compact layout carries no `gk` anyway.
    static func keyRequestPlan(to peer: PeerRecord?) -> RatchetOutbound.ReceiptPlan? {
        RatchetOutbound.receiptPlan(to: peer, ratchet: true).map { plan in
            RatchetOutbound.ReceiptPlan(bundle: plan.bundle, prekey: plan.prekey, readsCryptoV3: false)
        }
    }

    /// What the ack of an adopted seed toward `peer` is sealed with (`ackGroupSeed`, `:1563-1569`): the pinned bundle, no
    /// prekey, since the session that carried the seed exists by construction, and v2 always. Kotlin asks for no bit here.
    static func seedAckPlan(to peer: PeerRecord?) -> RatchetOutbound.ReceiptPlan? {
        guard let peer, let bundle = PublicKeyBundle(encoded: peer.publicKey) else {
            return nil
        }
        return RatchetOutbound.ReceiptPlan(bundle: bundle, prekey: nil, readsCryptoV3: false)
    }
}

/// How the group form went so far, under the names of Android's metrics (`MeshMetrics.Groups`, at knit-next `cbf2a487`),
/// counted where Kotlin counts them: the receive side's `onGroupSeedHeld`, `onGroupSeedReplayed`, `onGroupSeedAdopted` and
/// `onGroupKeyRequested` (phase P6a2), and the send side's `onGroupSealedRatchet`, `onGroupSealedV1Fallback` and
/// `onGroupSeedSent` (phase P6b; ADR 2026-10.5sk9).
public struct RatchetGroupCounts: Sendable, Equatable {
    /// Seeds parked for a roster we did not hold yet, or a sender we held as departed, each once (`groupSeedsHeld`).
    public internal(set) var groupSeedsHeld = 0
    /// Parked seeds released once a roster let their sender in (`groupSeedsReplayed`).
    public internal(set) var groupSeedsReplayed = 0
    /// Fresh chains adopted from seeds, each once its unit committed (`groupSeedsAdopted`).
    public internal(set) var groupSeedsAdopted = 0
    /// Key requests sealed and sent (`groupKeyRequestsSent`).
    public internal(set) var groupKeyRequestsSent = 0
    /// Our group frames sealed in the group form, messages and reactions alike (`groupSealedRatchet`).
    public internal(set) var groupSealedRatchet = 0
    /// Our group frames every other member could read in the group form that went v1 instead, a seed that would not seal
    /// to one of them or a group seal that would not go (`groupSealedV1Fallback`). A group with a member who cannot read the
    /// group form is not counted: it was never eligible.
    public internal(set) var groupSealedV1Fallback = 0
    /// Seed DMs sent, a first distribution's, a re-send's and a key request's answer alike (`groupSeedsSent`).
    public internal(set) var groupSeedsSent = 0

    /// Counts as stated, each zero unless given: nothing received or sent yet.
    public init(
        groupSeedsHeld: Int = 0, groupSeedsReplayed: Int = 0, groupSeedsAdopted: Int = 0, groupKeyRequestsSent: Int = 0,
        groupSealedRatchet: Int = 0, groupSealedV1Fallback: Int = 0, groupSeedsSent: Int = 0
    ) {
        self.groupSeedsHeld = groupSeedsHeld
        self.groupSeedsReplayed = groupSeedsReplayed
        self.groupSeedsAdopted = groupSeedsAdopted
        self.groupKeyRequestsSent = groupKeyRequestsSent
        self.groupSealedRatchet = groupSealedRatchet
        self.groupSealedV1Fallback = groupSealedV1Fallback
        self.groupSeedsSent = groupSeedsSent
    }
}
