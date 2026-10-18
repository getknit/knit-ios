import KnitCrypto
import KnitStore
import KnitWire

/// Our DMs with the switch on (ADR 2026-10.5sk9, phase P5b): `sendChat`, `sealEnvelopeFor`, `flushPendingFor`,
/// `resealRecentDmsTo` and `resealAndFlood` in knit-next's `MeshManager.kt` (at `cbf2a487`, `:1189-1308` and
/// `:3345-3407`), sealed with the ratchet toward a peer whose pinned profile carries `CAP_RATCHET` (``RatchetOutbound``).
///
/// **One read decides.** A send, a flush and a re-seal each read the peer's pinned row once, and take the scheme, the
/// bundle and the prekey from that read. A read that fails leaves a send or a flush waiting, as no row does, and loses a
/// re-seal, as Kotlin's throw does. A second read for the v1 arm could find the row the first one missed and send a
/// ratchet peer v1, uncounted and never upgraded. Kotlin's read throws when it fails, out of `sendChat`, and nothing is
/// sealed (`MeshManager.kt:1290`, `PeerRepository.kt:138`).
///
/// **The send unit.** The row is saved first, waiting (`pendingKey`), and then one store unit, the outermost, seals the DM
/// through ``RatchetSessions/sealDm(to:prekey:plaintext:aad:now:v3:)`` joined to it, signs the frame once, clears
/// `pendingKey` and takes the frame into our own custody. Only once that unit commits does anything leave it: the seal's
/// settlement, the router's mark, the transport's send, the count and the ``MeshEvent/sent(messageId:)`` event. A unit
/// that fails leaves the row waiting and nothing on the air, its chain advance undone with it, so no message key is
/// spent on a frame that never left; the heal seals it again (``retryWaitingDirectMessages()``). Kotlin seals, commits,
/// then saves the row and floods (`MeshManager.kt:1189-1235`); here the chain, the row's flag and custody's copy stand
/// together, and a frame whose unit committed survives a crash before its send when custody keeps it, served at the
/// next digest. Custody keeps no DM that waited more than a day, which is dead on arrival, none past our 200 newest
/// frames, and none past its 1,000 newest.
///
/// **The v1 fallback** is part of the same unit: a facade that has no session and no usable prekey, a new epoch due with
/// no base, or a peer key X25519 refuses (Kotlin's throw out of `sendChat`, `:1189`, `:1295`) seals the same content v1 to
/// the pinned bundle, counted, which every build reads. That DM is never upgraded. An identity key that v1 refuses too, a
/// low-order point, leaves the DM waiting, as today's v1 send leaves it; Kotlin throws out of `sendChat` there (`:1307`).
///
/// **The re-seal** after a peer's reset (``resealRecentDirectMessages(to:)``) takes the same unit, under the message's own
/// id and `sentAt`, and signs the id again: one more signature for each committed first verdict of a reset from that
/// peer within the day, with no per-id guard, as in Kotlin (ADR 2026-09.2ved, amended). It flies live, and custody keeps
/// the first bytes it stored under the id (``CustodySync/carryOwn(_:in:now:)``, `ForwardSync.kt:75`).
///
/// **Inline acks** (phase P5d; `inlineAcksFor` and `sendChat`, `MeshManager.kt:2004-2026` and `:1185-1202`, knit-next ADRs
/// 054 and 2026-09.aa27). A DM's first seal toward a peer whose pinned profile carries `CAP_INLINE_ACK` carries the room
/// ticks waiting for a ride toward it, inside the ratchet's plaintext only, as many as Kotlin's LoRa budget for that DM
/// leaves room for (``RatchetOutbound/inlineAckRoom(for:)``). They are taken before the unit and, within the same call,
/// said to have ridden once the unit commits with the ratchet's seal, or given back with their stamps: on a v1 fallback,
/// which carries none, and on a unit that fails, joins or is abandoned. A flush and a re-seal carry none, as Kotlin's
/// `flushPendingFor` and `resealAndFlood` carry none. This port has no DM coalescer, so only room ticks ride.
extension MeshEngine {
    /// What one send unit is for.
    enum RatchetSendPurpose {
        /// The DM's first seal, which clears its `pendingKey` and is announced as sent.
        case first
        /// The re-seal a peer's reset asks for, of a DM that already went.
        case reseal
    }

    /// The scheme our DM `message` takes toward the peer pinned as `peer` (`nil` for none), with the switch as configured.
    func directScheme(for message: MessageRecord, to peer: PeerRecord?) -> RatchetOutbound.Scheme {
        RatchetOutbound.scheme(for: Self.content(of: message), to: peer, ratchet: configuration.ratchet)
    }

    // MARK: Our DMs, with the switch on

    /// Our new DM `record` to `recipient`, with the switch on, sent as `scheme`, which one read of the peer's row decided,
    /// and answered as stored:
    /// - the ratchet: saved waiting first, so a unit that fails leaves the row for the heal and nothing on the air, and
    ///   carrying the room ticks waiting for a ride toward the peer when its profile reads inline acks;
    /// - v1, to the bundle that read gave, as today's send seals it: sent at once, or waiting when v1 refuses the key;
    /// - waiting: no bundle pinned, or a read that failed, for the key's arrival or the heal, with no second read.
    ///
    /// Only this first seal carries inline acks, and only the ratchet's arm: Kotlin takes them for every send and gives
    /// them back unless the seal came out v2 or v3 (`MeshManager.kt:1187-1202`), so a v1 or a waiting DM is sent none here.
    func sendDirect(_ record: MessageRecord, to recipient: NodeId, as scheme: RatchetOutbound.Scheme) -> MessageRecord {
        var record = record
        switch scheme {
        case .ratchet(let plan):
            record.pendingKey = true
            stores.messages.save(record)
            let riders = plan.readsInlineAcks ? ackSync.takeRiding(recipient, limit: RatchetOutbound.inlineAckRoom(for: record)) : []
            record.pendingKey = !sendRatchet(record, to: recipient, plan, purpose: .first, riders: riders)
        case .staticKeys(let bundle):
            let sealed = sealStatic(record, to: recipient, bundle)
            record.pendingKey = sealed == nil
            stores.messages.save(record)
            if let sealed {
                originate(staticEnvelope(sealed, of: record, to: recipient))
            }
        case .waiting:
            record.pendingKey = true
            stores.messages.save(record)
        }
        return record
    }

    /// Our DMs `waiting` for `recipient`, with the switch on, each sealed and sent as one read of the peer's row decides:
    /// with the ratchet in a send unit of its own, or v1 to that read's bundle, after which it waits no more and is
    /// announced as sent. A read that fails, or a row with no bundle, leaves every one waiting.
    func flushWaitingDirect(_ waiting: [MessageRecord], to recipient: NodeId) {
        guard !waiting.isEmpty, let peer = stores.peers.peer(recipient) else {
            return
        }
        for message in waiting {
            let scheme = directScheme(for: message, to: peer)
            if case .ratchet(let plan) = scheme {
                sendRatchet(message, to: recipient, plan, purpose: .first, riders: [])
            } else if case .staticKeys(let bundle) = scheme, let sealed = sealStatic(message, to: recipient, bundle) {
                originate(staticEnvelope(sealed, of: message, to: recipient))
                stores.messages.clearPendingKey(message.id)
                events.append(.sent(messageId: message.id))
            }
        }
    }

    /// `message` sealed v1 to `bundle`, the one the read that chose its scheme gave, under its own id and `sentAt`, or
    /// `nil` when v1 refuses the key, a low-order point.
    private func sealStatic(_ message: MessageRecord, to recipient: NodeId, _ bundle: PublicKeyBundle) -> EncEnvelope? {
        let header = MessageCrypto.header(id: message.id, senderId: nodeId.string, sentAt: message.sentAt, thread: recipient.string)
        return try? MessageCrypto.seal(Self.content(of: message).encoded, header: header, to: [recipient: bundle])
    }

    /// The DM frame around `sealed`, the v1 seal of `message`, under the message's own id and `sentAt`.
    private func staticEnvelope(_ sealed: EncEnvelope, of message: MessageRecord, to recipient: NodeId) -> RelayEnvelope {
        chatEnvelope(
            id: message.id, sentAt: message.sentAt, recipient: recipient, group: nil, content: Self.chat(sealed, carrying: message))
    }

    // MARK: The send unit

    /// Seals our DM `message` to `recipient` with `plan` in one store unit and sends it once the unit commits, as the type's
    /// doc says, with `riders`, room ticks taken out of their ride hold, inside the ratchet's plaintext. Answers whether it
    /// went: `false` leaves it as it was, waiting on a first seal. Either way the riders are settled before it answers.
    @discardableResult
    func sendRatchet(
        _ message: MessageRecord,
        to recipient: NodeId,
        _ plan: RatchetOutbound.Ratcheted,
        purpose: RatchetSendPurpose,
        riders: [String]
    ) -> Bool {
        let now = clock.wallMilliseconds()
        let aad = MessageCrypto.header(id: message.id, senderId: nodeId.string, sentAt: message.sentAt, thread: recipient.string)
        let sealing = riders.isEmpty ? plan : plan.carrying(riders, in: Self.content(of: message))
        let unit = stores.transactor.atomically { () -> RatchetSend? in
            guard let sealed = ratchetSeal(message, to: recipient, sealing, aad: aad, now: now) else {
                return nil
            }
            let content = Self.chat(sealed.envelope, carrying: message)
            let envelope = chatEnvelope(id: message.id, sentAt: message.sentAt, recipient: recipient, group: nil, content: content)
            // Signed once, here: a unit that fails takes these bytes with it, and they never left. A signature that
            // fails abandons the unit, the seal with it.
            return sign(envelope, relay: true).map { wire in
                if purpose == .first {
                    stores.messages.clearPendingKey(message.id)
                }
                // Custody keeps the first bytes it stored under an id, so a re-seal writes nothing over the original.
                let carried = custody.carryOwn(
                    CarriedFrame(envelope: envelope, sig: wire.sig, signed: wire.signed), in: stores.custody, now: now)
                return RatchetSend(frame: SignedFrame(wire: wire, envelope: envelope), sealed: sealed, carried: carried)
            }
        }
        switch unit {
        case .committed(let send):
            fly(send, to: recipient, purpose: purpose)
            // A v1 fallback carried none of them: a v1 reader never looks (`MeshManager.kt:1190-1202`).
            settleRiders(riders, toward: recipient, rode: send.sealed.form != .fallback)
            return true
        case .failed:
            log.log(.warning, "mesh DM \(message.id) to \(recipient) not sealed: a store failed, and nothing was sent")
            settleRiders(riders, toward: recipient, rode: false)
            return false
        case .abandoned, .joined:
            // Abandoned: neither the ratchet nor v1 would seal to this peer, or the signature failed. Joined cannot
            // happen, since nothing opens a unit around a send; were it to, its frame could not go before an outer commit
            // this never sees.
            settleRiders(riders, toward: recipient, rode: false)
            return false
        }
    }

    /// The room ticks a send carried inline, told to the ledger once its unit has answered: they rode, now that a ratchet
    /// seal of them committed, or go back to their ride hold with the stamps they had (`ackSync.rode` and
    /// `giveBackRiding`, `MeshManager.kt:1190-1202`).
    private func settleRiders(_ riders: [String], toward recipient: NodeId, rode: Bool) {
        guard !riders.isEmpty else {
            return
        }
        let now = clock.monotonicMilliseconds()
        if rode {
            ackSync.rode(riders, now: now)
        } else {
            ackSync.giveBackRiding(recipient, riders, now: now)
        }
    }

    /// `message` sealed toward `plan`'s peer inside the caller's unit: `plan`'s plaintext with the ratchet, joined to that
    /// unit, or the message's own content v1 when the facade cannot seal or X25519 refuses the peer's key
    /// (`MeshManager.kt:1293-1307`), so inline acks never ride the v1 wrap. `nil` when neither seals, or when a store failed,
    /// which fails the caller's unit with it.
    private func ratchetSeal(
        _ message: MessageRecord, to recipient: NodeId, _ plan: RatchetOutbound.Ratcheted, aad: [UInt8], now: Int64
    ) -> RatchetSealed? {
        let answer = ratchet.sealDm(
            to: plan.bundle, prekey: plan.prekey, plaintext: plan.bytes.plaintext, aad: aad, now: now, v3: plan.v3)
        switch answer {
        case .joined(.sealed(let envelope), let settlement):
            return RatchetSealed(envelope: envelope, form: .ratchet(v3: plan.v3), settlement: settlement)
        case .settled(.unavailable), .settled(.refusedKey), .joined(.unavailable, _), .joined(.refusedKey, _):
            // v1 refuses a low-order identity key as the ratchet does, and the DM then waits (Kotlin throws, `:1307`).
            guard let envelope = sealStatic(message, to: recipient, plan.bundle) else {
                return nil
            }
            return RatchetSealed(envelope: envelope, form: .fallback, settlement: nil)
        case .failed, .settled(.sealed):
            // A store failed, which fails the caller's unit with it. A seal settles by itself only as the outermost unit,
            // which inside ours it never is; were it to, this seal is dropped unsent, and the key it spent is never used
            // again.
            return nil
        }
    }

    /// After the unit committed: the floors the seal settles move, the frame goes on the air at once to every neighbour,
    /// marked seen so its echo is ignored, the count moves, and a first seal is announced as sent.
    private func fly(_ send: RatchetSend, to recipient: NodeId, purpose: RatchetSendPurpose) {
        if let settlement = send.sealed.settlement {
            ratchet.settle(settlement)
        }
        let id = send.frame.envelope.id
        router.markOwn(id, now: clock.monotonicMilliseconds())
        transport.send(send.frame.wire, to: nil)
        if send.carried {
            noteCustodyChanged()
        }
        switch send.sealed.form {
        case .ratchet(let v3):
            seals.dmSealedV2 += 1
            if v3 {
                seals.dmSealedV3 += 1
            }
        case .fallback:
            seals.dmSealedV1Fallback += 1
            log.log(.info, "mesh DM \(id) to \(recipient) went v1: the ratchet would not seal")
        }
        if purpose == .first {
            events.append(.sent(messageId: id))
        }
    }

    // MARK: The re-seal after a peer's reset

    /// Seals again, under the session now held, every DM of ours to `peer` from the last day that no receipt acknowledged
    /// (`resealRecentDmsTo`, `MeshManager.kt:3361-3371`): what the peer's reset asks of us, since it can no longer open what
    /// we sealed to the session it left, while custody still carries those frames for a day. Each keeps its id and its
    /// `sentAt`, so the AAD is the one it had, and its attachment's name and size, since it is sealed from its row
    /// (``content(of:)``, knit-next `0fa6c548`). A peer that already holds one acknowledges the copy at its exists-gate.
    ///
    /// It runs once a reset's first verdict has committed, however that open went: a root adopted, a race won or lost, or
    /// a marker under the session held (`InboundPipeline.kt:1137-1148`). A kept copy whose unit failed re-seals when the
    /// sweep's open of it commits, which is that reset's first committed verdict. Never for the start's replay
    /// (``RatchetInbound/Origin/startReplay``), which re-opens resets whose first verdict came before the restart and
    /// re-sealed then: signing the ids again would answer nothing that re-seal did not.
    func resealRecentDirectMessages(to peer: NodeId) {
        let unacked = unackedToReseal(peer)
        // Recorded before the first copy leaves, so whoever sees one sees the pass owed too. A DM that cannot seal now is
        // owed the second try with the rest: it is still unacked (`MeshManager.kt:3936-3943` at `4f3cd995`).
        resetReseal.record(unacked.map(\.id), for: peer, now: clock.monotonicMilliseconds())
        reseal(unacked, to: peer, pass: "after its reset")
    }

    /// The second pass of every reset re-seal now due (``ResetReseal``, `resealSecondPass`, knit-next `MeshManager.kt:3945-3973`
    /// at `4f3cd995`, ADR 2026-10.dmgw): the ids that pass recorded that are still unacked, so neither one acknowledged since
    /// nor a DM sent after the reset, which went under the new session. Once per reset: it records nothing, so it never
    /// re-arms. The 60-second re-offer runs it first, whoever is linked, so a pass due with nobody linked still goes, as
    /// Kotlin's tick runs it outside its link-set guards. Each costs one chain key per DM still unacked about eleven
    /// minutes after the reset.
    func resealSecondPass() {
        for (peer, ids) in resetReseal.takeDue(now: clock.monotonicMilliseconds()) {
            let owed = unackedToReseal(peer).filter { ids.contains(ExactKey($0.id)) }
            log.log(.info, "mesh reset re-seal second pass to \(peer): \(owed.count) of \(ids.count) still unacked")
            reseal(owed, to: peer, pass: "in the second pass after its reset")
        }
    }

    /// Our DMs to `peer` from the last day that no receipt acknowledged, none for a blocked peer (`unackedToReseal`,
    /// knit-next `MeshManager.kt:3974-3978` at `4f3cd995`).
    private func unackedToReseal(_ peer: NodeId) -> [MessageRecord] {
        guard !isBlocked(peer) else {
            return []
        }
        let since = clock.wallMilliseconds() &- RatchetOutbound.resealMilliseconds
        return stores.messages.messages(in: peer.string).filter { message in
            RatchetOutbound.isUnacknowledged(message, to: peer, from: nodeId, since: since)
        }
    }

    /// `messages` sealed again to `peer` under the session now held, each under its own id and `sentAt`, as one read of the
    /// peer's row decides (`reseal`, `MeshManager.kt:3980-3991`).
    private func reseal(_ messages: [MessageRecord], to peer: NodeId, pass: String) {
        guard !messages.isEmpty, let record = stores.peers.peer(peer) else {
            return
        }
        var resealed = 0
        for message in messages {
            switch directScheme(for: message, to: record) {
            case .ratchet(let plan):
                resealed += sendRatchet(message, to: peer, plan, purpose: .reseal, riders: []) ? 1 : 0
            case .staticKeys(let bundle):
                // A peer whose pinned profile lacks the bit sent the reset anyway: v1, as `sealEnvelopeFor` falls back.
                resealed += resealStatic(message, to: peer, bundle) ? 1 : 0
            case .waiting:
                continue
            }
        }
        log.log(.info, "mesh re-sealed \(resealed) of \(messages.count) unacked DMs to \(peer) \(pass)")
    }

    /// `message` sealed again v1 to `bundle` and flooded under its own id (`resealAndFlood` through `originateSigned`): signed
    /// a second time, and carried only where custody holds no bytes under its id.
    private func resealStatic(_ message: MessageRecord, to peer: NodeId, _ bundle: PublicKeyBundle) -> Bool {
        guard let sealed = sealStatic(message, to: peer, bundle) else {
            return false
        }
        originate(staticEnvelope(sealed, of: message, to: peer))
        return true
    }

    // MARK: The heal

    /// With the switch on, every DM of ours still waiting to a peer whose pinned profile carries `CAP_RATCHET` and a bundle,
    /// sealed and sent (phase P5b): the heal's retry of a send unit a store failed, of a send whose read of the peer's row
    /// failed, and of a DM held while we blocked the peer, which goes at the first heal after the unblock, the frame
    /// Android sends at that peer's next profile. The rows are the truth, so a restart loses nothing. A DM waiting for a
    /// key that has not pinned waits on, and goes when it pins, as before.
    func retryWaitingDirectMessages() {
        guard configuration.ratchet else {
            return
        }
        for peer in stores.peers.allPeers() where Capabilities(rawValue: peer.capabilities ?? 0).contains(.ratchet) {
            flushPendingDirect(to: peer.nodeId)
        }
    }
}

/// A DM sealed inside its send unit, and what its seal leaves for after the commit.
internal struct RatchetSealed {
    /// How it was sealed.
    enum Form: Equatable {
        /// With the ratchet, compact when `v3`.
        case ratchet(v3: Bool)
        /// v1, the ratchet's fallback.
        case fallback
    }

    /// The envelope.
    let envelope: EncEnvelope
    /// How it was sealed.
    let form: Form
    /// The floors a joined seal moves once the unit commits, or `nil` for none.
    let settlement: RatchetSessions.Settlement?
}

/// What a send unit leaves for after its commit: the frame, signed once, how it was sealed, and whether custody took it.
internal struct RatchetSend {
    /// The frame as signed.
    let frame: SignedFrame
    /// The seal inside it.
    let sealed: RatchetSealed
    /// Whether our custody stored it just now.
    let carried: Bool
}
