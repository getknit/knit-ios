import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

extension GroupTranscriptReplay {
    /// What a group-key DM's open did inside its unit: the adoption and the floor it moves once the unit commits.
    struct Inside {
        var adoption: GroupRatchetSessions.Adoption?
        var settlement: GroupRatchetSessions.Settlement?
    }

    /// A DM through `RatchetSessions.open`, with what the pipeline does inside the open's unit with a group-key DM
    /// (`openCtl`, `GroupTranscript.kt:405-475`): a distribution's seeds adopted, each verdict the file's, the ack the
    /// file's; an ack stamped in the outbox. A request does nothing there: its answer is a seal after the commit. A root
    /// gossip's `gr` is kept raw, and the content re-encodes to its plaintext.
    mutating func open(
        _ step: RatchetVectors.TranscriptStep,
        applies: RatchetVectors.GroupApplies?,
        actor: GroupTranscriptParty,
        label: String
    ) throws {
        let sender = try #require(parties[step.peer])
        expectFloors(step, actor: actor, peer: sender, label: label)
        let frame = RatchetSessions.Frame(
            header: try #require(step.header).ratchetHeader,
            nonce: try RatchetVectorReplay.bytes(try #require(step.nonce)),
            ct: try RatchetVectorReplay.bytes(try #require(step.ct)),
            aad: try RatchetVectorReplay.bytes(try #require(step.aad))
        )
        if let made = directFrames[try #require(step.opens)] {
            #expect(made == frame, "\(label): the frame as sealed")
        }
        let group = actor.group
        let alongside: (RatchetEngine.OpenOutcome.Opened) -> Inside? = { opened in
            guard let content = try? MessageContent(decoding: opened.plaintext), let gk = content.gk else {
                return Inside()
            }
            switch content.ctl {
            case MessageContent.Control.groupKey where !gk.keys.isEmpty:
                guard
                    case .joined(let adoption, let settlement) = group.adoptSeeds(
                        gk.keys, in: gk.groupId, from: sender.nodeId, now: step.now)
                else {
                    return nil
                }
                return Inside(adoption: adoption, settlement: settlement)
            case MessageContent.Control.groupKeyAck:
                guard let epoch = gk.ackEpoch, case .joined = group.onKeyAck(epoch, from: sender.nodeId, in: gk.groupId, now: step.now)
                else {
                    return nil
                }
                return Inside()
            default:
                return Inside()
            }
        }
        let answer = actor.dm.open(frame, from: sender.identity.bundle, now: step.now, prekeys: { actor.holds[$0] }, alongside: alongside)
        guard case .settled(.opened(let plaintext, let inside)) = answer else {
            Issue.record("\(label): expected an open, got \(answer)")
            return
        }
        #expect(step.expect == "OPENED" && Hex.encode(plaintext) == step.plaintext, "\(label): the outcome and plaintext")
        if let settlement = inside.settlement {
            group.settle(settlement)
        }
        try expectGroupKey(plaintext, inside: inside, applies: applies, label: label)
        try expectState(step, actor: actor, peer: sender, label: label)
    }

    /// The seeds' verdicts and the ack the file states, and a group-key payload's bytes kept: `gr` raw.
    private func expectGroupKey(_ plaintext: [UInt8], inside: Inside, applies: RatchetVectors.GroupApplies?, label: String) throws {
        let verdicts: [GroupRatchetSessions.Adoption.Verdict: String] = [
            .adopted: "ADOPT", .alreadyKnown: "ALREADY_KNOWN", .stale: "STALE",
        ]
        let stated = applies?.seeds ?? []
        #expect(!stated.contains { $0.outcome == "NOT_GATED" }, "\(label): the roster gate is P6a2's, and these never meet it")
        #expect((inside.adoption?.verdicts ?? []).map { verdicts[$0] } == stated.map(\.outcome), "\(label): each seed's verdict")
        if !stated.isEmpty {
            #expect(inside.adoption?.ackEpoch == applies?.groupKeyAckBack, "\(label): the ack back")
        }
        let content = try MessageContent(decoding: plaintext)
        if content.gk?.gr != nil {
            #expect(content.encoded == plaintext, "\(label): the root kept raw, the payload byte for byte")
        }
    }

    /// A reset through `RatchetSessions.sealResetDm` with the file's cause: its plan, and what it sealed, v2 and byte for
    /// byte. The group transcripts reset only a restored party's peers, onto no session.
    mutating func reset(_ step: RatchetVectors.TranscriptStep, actor: GroupTranscriptParty, label: String) throws {
        let peer = try #require(parties[step.peer])
        expectFloors(step, actor: actor, peer: peer, label: label)
        #expect(
            step.cause == "AFTER_WIPE" && step.decidedBy == "state.session is null: the restore emptied it", "\(label): the restore's reset"
        )
        let pin = try #require(actor.pins[peer.name])
        let aad = try self.aad(step, from: actor, to: peer, label: label)
        let drawn = actor.draws.count
        let answer = actor.dm.sealResetDm(
            to: peer.identity.bundle,
            prekey: pin.prekey,
            plaintext: RatchetSessions.resetPlaintext,
            aad: aad,
            now: step.now,
            cause: .afterWipe
        )
        guard case .settled(.sealed(let envelope, let plan)) = answer else {
            Issue.record("\(label): expected a sealed reset, got \(answer)")
            return
        }
        #expect(step.result == "REROOT" && plan.action == .reRoot && plan.decidedBy == .noSession, "\(label): the plan")
        #expect(Array(drawn..<actor.draws.count) == step.drawsUsed, "\(label): the draws it took")
        try check(envelope, against: step, label: label)
        directFrames[step.step] = RatchetSessions.Frame(
            header: try #require(envelope.ratchet), nonce: envelope.nonce, ct: envelope.ct, aad: aad)
        try expectState(step, actor: actor, peer: peer, label: label)
    }

    /// A group frame through `GroupRatchetSessions.sealGroup`, byte for byte. The file's `minted` is always `null` (A9's
    /// `GroupTranscript.kt:205`), so a mint is read from the draws: a seal that drew a seed minted with it, at its `now`.
    mutating func groupSeal(_ step: RatchetVectors.GroupStep, actor: GroupTranscriptParty, label: String) throws {
        let aad = try RatchetVectorReplay.bytes(try #require(step.aad))
        let (id, sentAt) = (try #require(step.frameId), try #require(step.sentAt))
        #expect(
            aad == MessageCrypto.header(id: id, senderId: actor.nodeId.string, sentAt: sentAt, thread: transcript.groupId),
            "\(label): the AAD")
        let drawn = actor.draws.count
        let answer = actor.group.sealGroup(
            plaintext: try RatchetVectorReplay.bytes(try #require(step.plaintext)), aad: aad, in: transcript.groupId, now: step.now)
        guard case .settled(.sealed(let envelope, let minted)) = answer else {
            Issue.record("\(label): expected a sealed group frame, got \(answer)")
            return
        }
        let used = try #require(step.drawsUsed)
        #expect(Array(drawn..<actor.draws.count) == used, "\(label): the draws it took")
        let seedDraw = used.compactMap { transcript.draws[actor.name]?[$0] }.first { $0.kind == "groupSeed" }
        let header = try #require(step.groupHeader)
        #expect(minted.map { Hex.encode($0.seed) } == seedDraw?.groupSeed, "\(label): a mint, from the seed it drew")
        #expect(
            minted.map { [$0.epoch, Int($0.mintedAt - step.now)] } == seedDraw.map { _ in [header.se, 0] },
            "\(label): the mint's epoch and stamp")
        #expect(envelope.groupRatchet == GroupRatchetHeader(se: header.se, n: header.n), "\(label): the header")
        #expect(Hex.encode(envelope.nonce) == step.nonce && Hex.encode(envelope.ct) == step.ct, "\(label): the IV and the ciphertext")
        #expect(Hex.encode(envelope.encoded) == step.encEnvelope, "\(label): the envelope")
        let frame = try #require(GroupRatchetSessions.Frame(envelope: envelope, aad: aad))
        groupFrames[step.step] = frame
    }

    /// A group frame through `GroupRatchetSessions.open`, and a `NO_KEY` or `AEAD_FAIL` fed to the key-request heuristic
    /// (`groupOpen`, `GroupTranscript.kt:345-395`), whose verdict must be the file's `keyRequestDue`.
    func groupOpen(_ step: RatchetVectors.GroupStep, actor: GroupTranscriptParty, label: String) throws {
        let peer = try #require(step.peer)
        let sender = try #require(parties[peer])
        let stated = try #require(step.groupHeader)
        let frame = GroupRatchetSessions.Frame(
            header: GroupRatchetHeader(se: stated.se, n: stated.n),
            nonce: try RatchetVectorReplay.bytes(try #require(step.nonce)),
            ct: try RatchetVectorReplay.bytes(try #require(step.ct)),
            aad: try RatchetVectorReplay.bytes(try #require(step.aad))
        )
        if let made = groupFrames[try #require(step.opens)] {
            #expect(made == frame, "\(label): the frame as sealed")
        }
        let answer = actor.group.open(frame, in: transcript.groupId, from: sender.nodeId, now: step.now) { _ in () }
        switch answer {
        case .settled(.opened(let plaintext, _)):
            #expect(step.expect == "OPENED" && Hex.encode(plaintext) == step.plaintext, "\(label): the outcome and plaintext")
            if let message = step.applies?.message {
                #expect(try MessageContent(decoding: plaintext).body == message.body, "\(label): the row's body")
            }
            #expect(step.keyRequestDue == nil)
        case .settled(.refused(let failure)):
            #expect(Self.name(of: failure) == step.expect, "\(label): the outcome")
            guard failure == .noKey || failure == .aeadFail else {
                #expect(step.keyRequestDue == nil)
                return
            }
            let (id, sentAt) = (try #require(step.frameId), try #require(step.sentAt))
            let due = actor.group.noteUndecryptable(in: transcript.groupId, from: sender.nodeId, frameId: id, sentAt: sentAt, now: step.now)
            #expect(due == step.keyRequestDue, "\(label): whether a key request is due")
        default:
            Issue.record("\(label): expected an open of its own, got \(answer)")
        }
    }

    /// A departure as `GroupRepository.recordDeparture` records it in one unit (`depart`, `GroupTranscript.kt:283-313`): the
    /// send chain retired and the leaver's outbox row dropped. The roster's shrink is `GroupStore`'s.
    func depart(_ step: RatchetVectors.GroupStep, actor: GroupTranscriptParty) throws {
        let named = try #require(step.leaver)
        let leaver = try #require(parties[named])
        let unit = actor.transactor.atomically { () -> Int? in
            actor.groupStore.retireSendChains(transcript.groupId)
            actor.groupStore.deleteKeySend(transcript.groupId, member: leaver.nodeId)
            return 1
        }
        #expect(unit == .committed(1))
    }
}
