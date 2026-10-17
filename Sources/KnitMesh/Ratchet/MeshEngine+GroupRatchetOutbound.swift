import KnitCrypto
import KnitStore
import KnitWire

/// The group form sent in the mesh, with the switch on (ADR 2026-10.5sk9, phase P6b): `sealEnvelopeFor`'s group arm,
/// `sealGroupRatchet`, `distributeGroupSeed`, `sendSeedDm`, `flushPendingGroupKeysFor`, `redistributeGroupKey` and
/// `sealGroupReaction` in knit-next's `MeshManager.kt` (at `cbf2a487`, `:1302-1484` and `:2227-2247`), over
/// ``GroupRatchetOutbound``'s pure rules.
///
/// **All or nothing per frame.** One read of every other member's pinned row decides, inside the send's unit: the group
/// form only when each of them has a bundle, `CAP_RATCHET` and a valid prekey, and only when the epoch's seed, if this
/// seal mints one, seals to every one of them through the DM ratchet; anything short of that seals the frame v1 to the
/// bundles that read gave, so no member gets a group frame it cannot open while v1 would reach it. The attempt at the
/// group form is a unit nested in the send's, so a seed that will not seal to one member abandons the mint, the group
/// chain's advance and every seed sealed before it, and the v1 seal then stands alone. Kotlin keeps the mint and the seeds
/// already sent there (`MeshManager.kt:1333-1339`), and its next send reuses that chain toward the member the seed never
/// reached.
///
/// **The send unit** is P5b's (``sendRatchet(_:to:_:purpose:riders:)``). A message's row is saved waiting first. Then one
/// store unit, the outermost, takes the group seal and any mint, every seed DM's DM-ratchet seal and its outbox row, the
/// signatures, each frame of ours into our own custody, and the cleared `pendingKey`. Only once it commits does anything
/// leave it: the seeds' settlements, then the seed DMs on the air, then the group frame, so the seeds flood first, and the
/// counts and ``MeshEvent/sent(messageId:)``. A unit that fails leaves the row waiting and nothing on the air, and the heal
/// seals it again (``retryWaitingGroupMessages()``). Every frame is signed once, inside the unit.
///
/// **Seed DMs** are `CTL_GROUP_KEY` ctl DMs, always v2 named, flooded and carried like any chat and never a row; they carry
/// the group's founding roster, never a root. A first distribution is not floored; a re-send is, per group, member and
/// pairwise root (``GroupSendFloors``): on the member's profile, at each link-up and re-offer, after its reset (forced past
/// the outbox's ack), and as the answer to its key request.
extension MeshEngine {
    // MARK: Our group frames

    /// Our group message `message` in `group`, with the switch on, sealed and sent as one read of its members' rows decides,
    /// in a send unit of its own: answers whether it went, so its row waits no more, and the members with no pinned bundle,
    /// for a key request. A store that fails leaves it waiting for the heal; a v1 seal with nobody to wrap to leaves it
    /// waiting for a key.
    @discardableResult
    func sendGroupRatchet(_ message: MessageRecord, in group: GroupRecord) -> (sent: Bool, unkeyed: [NodeId]) {
        let job = GroupSendJob(
            id: message.id,
            sentAt: message.sentAt,
            content: Self.content(of: message),
            attachmentHash: message.attachment?.hash.string,
            waits: true
        )
        let (unit, fellBack) = groupSend(job, in: group)
        guard case .committed(let sent) = unit else {
            // Failed: a store failed. Abandoned: a signature failed. Joined cannot happen, since nothing opens a unit around
            // a send; were it to, its frames could not go before an outer commit this never sees.
            let why = if case .failed = unit { "a store failed" } else { "its unit did not commit" }
            log.log(.warning, "mesh group message \(message.id) to \(group.id) not sealed: \(why), and nothing was sent")
            return (false, [])
        }
        guard fly(sent, in: group, fellBack: fellBack) else {
            return (false, sent.unkeyed)
        }
        events.append(.sent(messageId: message.id))
        return (true, sent.unkeyed)
    }

    /// Our reaction `reaction` to a message in `group`, with the switch on (`sealGroupReaction`, `MeshManager.kt:2227-2247`): a
    /// `CTL_REACTION` in the group form, under a fresh id dated by the row's own clock, its seed distributed as a message's is,
    /// when every other member can read it; otherwise the cleartext frame, counted, as Kotlin counts a group that cannot seal
    /// (`:2189`). A store that fails sends neither, and the row stays applied.
    func sendGroupReaction(_ reaction: ReactionRecord, in group: GroupRecord?) {
        guard let group, !group.hasLeft else {
            seals.reactionsSealedFallback += 1
            originateCleartext(reaction)
            return
        }
        let content = RatchetOutbound.reaction(on: reaction.messageId, emoji: reaction.emoji)
        let job = GroupSendJob(id: newFrameId(), sentAt: reaction.updatedAt, content: content, attachmentHash: nil, waits: false)
        let (unit, fellBack) = groupSend(job, in: group)
        switch unit {
        case .committed(let sent):
            fly(sent, in: group, fellBack: fellBack)
            seals.reactionsSealed += 1
        case .abandoned:
            groupCounts.groupSealedV1Fallback += fellBack ? 1 : 0
            seals.reactionsSealedFallback += 1
            originateCleartext(reaction)
        case .failed, .joined:
            // A store failed, or the reaction was asked for inside a unit, whose commit this never sees: nothing goes.
            let why = if case .failed = unit { "a store failed" } else { "asked for inside a store unit" }
            log.log(.warning, "mesh reaction on \(reaction.messageId) not sent: \(why)")
        }
    }

    /// With the switch on, every group message of ours still waiting in a group we are in, sealed and sent (phase P6b): the
    /// heal's retry of a send unit a store failed, as P5b's ``retryWaitingDirectMessages()`` is the DMs'. One that waits for
    /// a key waits on, and goes when one pins.
    func retryWaitingGroupMessages() {
        guard configuration.ratchet else {
            return
        }
        for group in stores.groups.groups() where !group.hasLeft && hasOthers(group) {
            for message in stores.messages.pendingKey(in: group.id) {
                sendGroupRatchet(message, in: group)
            }
        }
    }

    // MARK: The send unit

    /// `job` sealed to `group` in one store unit, the outermost, as the type's doc says, and whether it took the v1 seal in
    /// the group form's stead. A frame `job` lets fall back goes v1; one that does not, a reaction, abandons the unit, and its
    /// caller sends the cleartext frame.
    func groupSend(_ job: GroupSendJob, in group: GroupRecord) -> (Transacted<GroupSent>, fellBack: Bool) {
        var fellBack = false
        let unit = stores.transactor.atomically { () -> GroupSent? in
            let now = clock.wallMilliseconds()
            let form = GroupRatchetOutbound.form(of: members(of: group), ratchet: configuration.ratchet)
            if case .groupForm(let targets) = form {
                switch sealGroupForm(job, in: group, to: targets, now: now) {
                case .sealed(let sent):
                    return sent
                case .failed:
                    return nil
                case .unsealable:
                    fellBack = true
                }
            }
            guard job.waits else {
                return nil
            }
            let unkeyed: [NodeId] = if case .staticKeys(_, let missing) = form { missing } else { [] }
            return sealGroupStatic(job, in: group, to: form.bundles, unkeyed: unkeyed, now: now)
        }
        return (unit, fellBack)
    }

    /// The other members of `group` and the rows pinned for them, read inside the caller's unit, so a read that fails fails it.
    private func members(of group: GroupRecord) -> [GroupRatchetOutbound.Member] {
        GroupRatchetOutbound.others(in: group, me: nodeId).map { id in
            let member = NodeId(id)
            return GroupRatchetOutbound.Member(nodeId: member, row: member.flatMap { stores.peers.peer($0) })
        }
    }

    /// `job` sealed in the group form inside a unit nested in the caller's (`sealGroupRatchet`, `MeshManager.kt:1319-1343`):
    /// the group seal, minting when the advance rules say, then a minted seed sealed to each of `targets` with its outbox row,
    /// then the frame signed and carried. A seed that will not seal, or a group seal that will not go, abandons the nested
    /// unit, which undoes every write in it and leaves the caller's: `unsealable`, for the v1 seal.
    private func sealGroupForm(_ job: GroupSendJob, in group: GroupRecord, to targets: [GroupSeedTarget], now: Int64) -> GroupFormAttempt {
        let aad = MessageCrypto.header(id: job.id, senderId: nodeId.string, sentAt: job.sentAt, thread: group.id)
        let attempt = stores.transactor.atomically { () -> GroupSent? in
            let sealing = groupRatchet.sealGroup(plaintext: job.content.encoded, aad: aad, in: group.id, now: now)
            guard case .joined(.sealed(let enc, let minted), _) = sealing else {
                return nil
            }
            var seeds: [SealedSeed] = []
            if let minted {
                // The seeds before the frame, so they flood first; never a seed in v1 (`distributeGroupSeed`, `:1363-1371`).
                let seed = GroupRatchetOutbound.seed([minted], of: group)
                for target in targets {
                    guard let sealed = sealSeed(seed, epoch: minted.epoch, to: target, in: group.id, now: now) else {
                        return nil
                    }
                    seeds.append(sealed)
                }
            }
            let chat = ChatContent(attachmentHash: job.attachmentHash, enc: enc)
            let envelope = chatEnvelope(id: job.id, sentAt: job.sentAt, recipient: nil, group: group.info, content: chat)
            return signedAndCarried(envelope, now: now).map { frame in
                if job.waits {
                    stores.messages.clearPendingKey(job.id)
                }
                return GroupSent(frame: frame, seeds: seeds, groupForm: true, unkeyed: [])
            }
        }
        switch attempt {
        case .joined(let sent), .committed(let sent):
            return .sealed(sent)
        case .abandoned:
            return .unsealable
        case .failed:
            return .failed
        }
    }

    /// `job` sealed v1 to `bundles` inside the caller's unit, as today's group seal wraps it (`recipientBundles`,
    /// `MeshManager.kt:1933-1952`), signed and carried with its row's wait cleared; or waiting, with nobody to wrap to or a
    /// key v1 refuses, as today's send leaves it. A signature that fails abandons the unit.
    private func sealGroupStatic(
        _ job: GroupSendJob, in group: GroupRecord, to bundles: [NodeId: PublicKeyBundle], unkeyed: [NodeId], now: Int64
    ) -> GroupSent? {
        let header = MessageCrypto.header(id: job.id, senderId: nodeId.string, sentAt: job.sentAt, thread: group.id)
        guard !bundles.isEmpty, let sealed = try? MessageCrypto.seal(job.content.encoded, header: header, to: bundles) else {
            return GroupSent(frame: nil, seeds: [], groupForm: false, unkeyed: unkeyed)
        }
        let chat = ChatContent(attachmentHash: job.attachmentHash, enc: sealed)
        let envelope = chatEnvelope(id: job.id, sentAt: job.sentAt, recipient: nil, group: group.info, content: chat)
        return signedAndCarried(envelope, now: now).map { frame in
            stores.messages.clearPendingKey(job.id)
            return GroupSent(frame: frame, seeds: [], groupForm: false, unkeyed: unkeyed)
        }
    }

    /// `envelope` signed once, `relay = true`, and taken into our custody inside the caller's unit; `nil` when the signature
    /// fails, which abandons the unit. Custody keeps the first bytes stored under an id, and each id here is fresh.
    private func signedAndCarried(_ envelope: RelayEnvelope, now: Int64) -> CarriedOwn? {
        sign(envelope, relay: true).map { wire in
            let carried = custody.carryOwn(
                CarriedFrame(envelope: envelope, sig: wire.sig, signed: wire.signed), in: stores.custody, now: now)
            return CarriedOwn(frame: SignedFrame(wire: wire, envelope: envelope), carried: carried)
        }
    }

    /// One seed DM, `content`, sealed to `target` inside the caller's unit (`sendSeedDm`, `MeshManager.kt:1381-1409`): a fresh
    /// frame id and our clock's now, the DM ratchet's seal joined to the unit, always v2 named, with the target's prekey where
    /// no session is held, the outbox's row for `epoch` in `group` beside it, then signed once and carried. `nil` when the DM
    /// ratchet will not seal (no session and no usable prekey, a new epoch due with no base, a key X25519 refuses), when the
    /// signature fails, or when a store failed, which fails the caller's unit with it.
    func sealSeed(_ content: MessageContent, epoch: Int, to target: GroupSeedTarget, in group: String, now: Int64) -> SealedSeed? {
        let id = newFrameId()
        let aad = MessageCrypto.header(id: id, senderId: nodeId.string, sentAt: now, thread: target.member.string)
        let sealing = ratchet.sealDm(to: target.bundle, prekey: target.prekey, plaintext: content.encoded, aad: aad, now: now)
        guard case .joined(.sealed(let enc), let settlement) = sealing,
            case .joined = groupRatchet.markKeySent(epoch, to: target.member, in: group, now: now)
        else {
            return nil
        }
        let envelope = chatEnvelope(id: id, sentAt: now, recipient: target.member, group: nil, content: ChatContent(enc: enc))
        return signedAndCarried(envelope, now: now).map { SealedSeed(own: $0, settlement: settlement) }
    }

    /// After a group send's unit committed: the seeds settle and go on the air first, then the frame, each marked seen so its
    /// echo is ignored, and the counts move. Answers whether a frame went: none when nothing was sealed and the row waits.
    @discardableResult
    private func fly(_ sent: GroupSent, in group: GroupRecord, fellBack: Bool) -> Bool {
        guard let frame = sent.frame else {
            return false
        }
        for seed in sent.seeds {
            fly(seed)
        }
        launch(frame)
        let id = frame.frame.envelope.id
        if sent.groupForm {
            groupCounts.groupSealedRatchet += 1
            log.log(.info, "mesh group frame \(id) to \(group.id) went in the group form, \(sent.seeds.count) seeds ahead")
        } else if fellBack {
            groupCounts.groupSealedV1Fallback += 1
            log.log(.info, "mesh group frame \(id) to \(group.id) went v1: a seed or the group seal would not go")
        }
        return true
    }

    /// After its unit committed, one seed DM: its seal's floors settle, and it goes on the air.
    func fly(_ seed: SealedSeed) {
        ratchet.settle(seed.settlement)
        launch(seed.own)
        groupCounts.groupSeedsSent += 1
    }

    /// One frame of ours whose unit committed, on the air at once to every neighbour, marked seen.
    private func launch(_ own: CarriedOwn) {
        router.markOwn(own.frame.envelope.id, now: clock.monotonicMilliseconds())
        transport.send(own.frame.wire, to: nil)
        if own.carried {
            noteCustodyChanged()
        }
    }
}

/// One group frame a send asks for: its id and stamp, which the AAD names, its plaintext, the attachment hash beside the
/// seal in the clear, and whether it is a message's, whose row waits until it goes and which falls back to v1, or a
/// reaction's, whose fallback is the cleartext frame.
internal struct GroupSendJob {
    let id: String
    let sentAt: Int64
    let content: MessageContent
    let attachmentHash: String?
    let waits: Bool
}

/// A frame of ours signed inside a unit, and whether our custody took it there.
internal struct CarriedOwn {
    let frame: SignedFrame
    let carried: Bool
}

/// A seed DM sealed inside a unit, and what its seal leaves for after the commit.
internal struct SealedSeed {
    let own: CarriedOwn
    let settlement: RatchetSessions.Settlement
}

/// What a group send's unit came to: the frame sealed, in the group form with the seeds of the epoch it minted, if it minted
/// one, to go ahead of it, or v1; or no frame, when nobody could be wrapped to or v1 refused a key, and the row waits on.
internal struct GroupSent {
    let frame: CarriedOwn?
    let seeds: [SealedSeed]
    let groupForm: Bool
    /// The members with no pinned bundle, for a key request.
    let unkeyed: [NodeId]
}

/// What an attempt at the group form came to, inside the send's unit.
private enum GroupFormAttempt {
    /// It stands with the send's unit.
    case sealed(GroupSent)
    /// It was abandoned with every write it made: a seed or the group seal would not go.
    case unsealable
    /// A store failed, which failed the send's unit.
    case failed
}
