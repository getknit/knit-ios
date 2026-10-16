import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A9's `dm` transcripts through the engine's send path (ADR 2026-10.5sk9, phase P5b). Alice is the iPhone: every seal of
/// hers the pipeline makes by its own rules goes through her engine, from a waiting row, byte for byte as the file lists
/// it, and so does the re-seal her engine makes when she opens Bob's reset. The rest of her seals, which the pipeline does
/// not make here, her engine's own facade makes from her draws: the v2 opener toward a v3 reader (`dm`'s inbound form),
/// the ctl frames the file's Alice sends Bob, an unsigned frame, the `advance`'s discarded frames, and resets under the
/// file's ids.
///
/// The file lists no receiver's ack-back ("Neither layer lists the receiver's own ack-backs", `transcriptFormat`), where an
/// engine since P5d answers a plain DM with a sealed receipt that spends a key of its chain and, for a new epoch, a draw.
/// So while an engine opens a plain DM, or meets one at its exists-gate, the peer's pinned row reads as a build without the
/// ratchet, and the receipt goes in the clear, spending nothing the file does not list. Carol's replay checks the sealed
/// receipt itself, where the file does list it.
///
/// `resealNewFirst` and `resealOldFirst` also run with Bob as an engine, so his open of the engine's re-seal and the
/// exists-gate that meets the second copy run through his inbound path.
@Suite struct RatchetSendVectorTests {
    static let scenarios = RatchetVectorReplay.file.dm.map(\.name)

    @Test(arguments: scenarios)
    func alicesSealsGoThroughHerEngine(name: String) throws {
        let transcript = try #require(RatchetVectorReplay.file.dm.first { $0.name == name })
        let replay = try SendReplay(transcript, engines: ["alice"])
        for step in transcript.steps {
            try replay.run(step)
        }
        #expect(replay.spent, "\(name): Alice took every draw her plan lists")
        // Every signed plain DM Alice seals v3 to Bob's 0x159 is one the pipeline makes by its own rules, so each went
        // through her engine: none fell back to the facade unnoticed.
        let plainV3 = transcript.steps.filter { step in
            guard step.actor == "alice", step.op == "seal", step.signed != false, step.version == EncEnvelope.Version.compactRatchet,
                let content = step.plaintext.flatMap(Hex.decode).flatMap(MessageContentV2.decode)
            else {
                return false
            }
            return content.ctl == nil && content.ack == nil && content.acks == nil
        }
        #expect(replay.sentByTheEngine == plainV3.count, "\(name): \(replay.sentByTheEngine) of \(plainV3.count) through the engine")
        #expect(
            replay.sentByTheEngine + replay.sealedByTheFacade == transcript.steps.filter { $0.actor == "alice" && $0.op == "seal" }.count)
    }

    @Test(arguments: ["resealNewFirst", "resealOldFirst"])
    func theResealPairThroughBothEngines(name: String) throws {
        let transcript = try #require(RatchetVectorReplay.file.dm.first { $0.name == name })
        let replay = try SendReplay(transcript, engines: ["alice", "bob"])
        for step in transcript.steps {
            try replay.run(step)
        }
        #expect(replay.spent, "\(name): both took every draw their plans list")
        let bob = try #require(replay.engines["bob"])
        let skip = try #require(transcript.steps.last)
        #expect(skip.op == "skip" && bob.acknowledged.last == skip.frameId, "the second copy met the exists-gate, which acknowledged it")
    }
}

/// One `dm` transcript run through the engines of the parties `engines` names; the others' frames are the file's.
private final class SendReplay {
    private typealias Replay = RatchetVectorReplay
    typealias Step = RatchetVectors.TranscriptStep

    let transcript: RatchetVectors.Transcript
    private(set) var engines: [String: EngineFixture] = [:]
    private var draws: [String: VectorDraws] = [:]
    private var ids: [String: IdentityKeys] = [:]
    /// Each seal's frame as it travels: what an engine wrote, or the file's wire.
    private var frames: [Int: InboundFrame] = [:]
    /// The re-seals an engine made as it opened a reset, by id, and when.
    private var reseals: [String: (written: Written, at: Int64)] = [:]
    /// How many seals an engine's send path made, re-seals included, and how many its facade made for it.
    private(set) var sentByTheEngine = 0
    private(set) var sealedByTheFacade = 0

    init(_ transcript: RatchetVectors.Transcript, engines names: Set<String>) throws {
        self.transcript = transcript
        let start = try #require(transcript.steps.first).now
        for (name, party) in transcript.parties {
            ids[name] = try Replay.identity(party.identity)
        }
        for name in names {
            let plan = VectorDraws(owner: name, plan: transcript.draws[name] ?? [])
            draws[name] = plan
            engines[name] = try Replay.receiver(transcript, as: name, peer: other(name), wall: start, draws: plan)
        }
    }

    var spent: Bool { draws.values.allSatisfy(\.spent) }

    private func other(_ name: String) -> String {
        name == "alice" ? "bob" : "alice"
    }

    func run(_ step: Step) throws {
        guard let actor = engines[step.actor] else {
            if step.op == "seal" || step.op == "reset" {
                frames[step.step] = try Replay.frame(of: step)
            }
            return
        }
        let label = "\(transcript.name) step \(step.step)"
        let peer = try #require(ids[other(step.actor)])
        Replay.move(actor, to: step.now)
        Replay.expectFloors(step, in: actor, for: peer.nodeId, label)
        switch step.op {
        case "seal":
            try seal(step, by: actor, to: peer, label)
        case "reset":
            try reset(step, by: actor, to: peer, label)
        case "advance":
            try advance(step, by: actor, to: peer, label)
        case "open", "skip":
            try open(step, by: actor, from: peer, label)
        default:
            Issue.record("\(label): \(step.op) is no step this replay knows")
        }
    }

    // MARK: Seals

    private func seal(_ step: Step, by actor: EngineFixture, to peer: IdentityKeys, _ label: String) throws {
        if step.resealOf != nil {
            let id = try #require(step.frameId)
            let made = try #require(reseals[id], "\(label): the engine sealed it again as it opened the reset")
            try check(made.written, against: step, by: actor, label)
            sentByTheEngine += 1
            frames[step.step] = inbound(made.written, from: actor)
            try expectState(step, in: actor, for: peer, resealedAt: made.at, label)
            return
        }
        let hex = try #require(step.plaintext)
        let plaintext = try Replay.bytes(hex)
        let v3 = step.version == EncEnvelope.Version.compactRatchet
        let row = try sentRow(step, plaintext, by: actor, to: peer)
        if let row, step.signed != false, sealsByItsRules(row, plaintext: plaintext, v3: v3) {
            var waiting = row
            waiting.pendingKey = true
            actor.stores.messages.save(waiting)
            let before = actor.transport.written.count
            actor.engine.flushPendingDirect(to: peer.nodeId)
            let sent = actor.transport.written.dropFirst(before).last { $0.envelope.id == row.id }
            let written = try #require(sent, "\(label): sent")
            try check(written, against: step, by: actor, label)
            sentByTheEngine += 1
            frames[step.step] = inbound(written, from: actor)
        } else {
            sealedByTheFacade += 1
            let aad = try Replay.bytes(step.aad ?? "")
            let answer = actor.engine.ratchet.sealDm(
                to: peer.bundle, prekey: try pinned(by: actor, peer), plaintext: plaintext, aad: aad, now: step.now, v3: v3)
            guard case .settled(.sealed(let envelope)) = answer else {
                Issue.record("\(label): the facade's seal \(answer)")
                return
            }
            #expect(Hex.encode(envelope.encoded) == step.encEnvelope, "\(label): the facade's envelope, byte for byte")
            if let row {
                actor.stores.messages.save(row)
            }
            frames[step.step] = try Replay.frame(of: step)
        }
        try Replay.expectState(step, in: actor, for: peer.nodeId, label)
    }

    /// The row our send leaves for a plain DM the step seals, or `nil` for machinery.
    private func sentRow(_ step: Step, _ plaintext: [UInt8], by actor: EngineFixture, to peer: IdentityKeys) throws -> MessageRecord? {
        let v3 = step.version == EncEnvelope.Version.compactRatchet
        let content = v3 ? MessageContentV2.decode(plaintext) : try? MessageContent(decoding: plaintext)
        guard let content, content.ctl == nil else {
            return nil
        }
        return MessageRecord(
            id: try #require(step.frameId),
            senderId: actor.me.nodeId,
            recipientId: peer.nodeId,
            conversationId: peer.nodeId.string,
            body: content.body,
            sentAt: try #require(step.sentAt)
        )
    }

    /// Whether the pipeline seals `row` as the step did: the same plaintext, in the scheme the peer's pinned bits choose.
    private func sealsByItsRules(_ row: MessageRecord, plaintext: [UInt8], v3: Bool) -> Bool {
        let bytes = MeshEngine.content(of: row).sealBytes(v3: CryptoScheme.readsCryptoV3(Replay.file.profiles.capabilities))
        return bytes.plaintext == plaintext && (bytes.scheme == EncEnvelope.Version.compactRatchet) == v3
    }

    private func check(_ written: Written, against step: Step, by actor: EngineFixture, _ label: String) throws {
        let enc = try #require(try ChatContent(decoding: written.envelope.payload).enc)
        #expect(Hex.encode(enc.encoded) == step.encEnvelope, "\(label): the envelope, byte for byte")
        let hex = try #require(step.wire)
        let wire = try WireEnvelope(decoding: try Replay.bytes(hex))
        #expect(written.wire.signed == wire.signed, "\(label): the signed bytes")
        #expect(actor.me.keys.bundle.isValidSignature(written.wire.sig, for: written.wire.signed), "\(label): signed once, and it verifies")
    }

    private func inbound(_ written: Written, from actor: EngineFixture) -> InboundFrame {
        InboundFrame(wire: written.wire, envelope: written.envelope, from: actor.me.nodeId)
    }

    private func pinned(by actor: EngineFixture, _ peer: IdentityKeys) throws -> PeerPrekey {
        let info = try #require(actor.stores.peers.peer(peer.nodeId)?.prekey)
        return try #require(PeerPrekey(verifying: info, signedBy: peer.bundle))
    }

    private func reset(_ step: Step, by actor: EngineFixture, to peer: IdentityKeys, _ label: String) throws {
        let causes: [String: RatchetResetPolicy.Cause] = ["ON_DEMAND": .onDemand, "UNREADABLE": .unreadable, "AFTER_WIPE": .afterWipe]
        let named = try #require(step.cause)
        let cause = try #require(causes[named])
        let aad = try step.aad.map(Replay.bytes) ?? []
        let answer = actor.engine.ratchet.sealResetDm(
            to: peer.bundle,
            prekey: try pinned(by: actor, peer),
            plaintext: RatchetSessions.resetPlaintext,
            aad: aad,
            now: step.now,
            cause: cause
        )
        switch answer {
        case .settled(.sealed(let envelope, let plan)):
            #expect((plan.action == .reRoot ? "REROOT" : "MARK") == step.result, "\(label): the plan")
            #expect(Hex.encode(envelope.encoded) == step.encEnvelope, "\(label): the reset, byte for byte")
            frames[step.step] = try Replay.frame(of: step)
        case .settled(.declined(let reason, _)):
            #expect(step.result == "DECLINED" && reason == step.reason, "\(label): the decline")
        default:
            Issue.record("\(label): expected a sealed or declined reset, got \(answer)")
        }
        try Replay.expectState(step, in: actor, for: peer.nodeId, label)
    }

    /// `count` v3 frames sealed and discarded: only the chain moves.
    private func advance(_ step: Step, by actor: EngineFixture, to peer: IdentityKeys, _ label: String) throws {
        let prekey = try pinned(by: actor, peer)
        for _ in 0..<(step.count ?? 0) {
            let answer = actor.engine.ratchet.sealDm(to: peer.bundle, prekey: prekey, plaintext: [0xA0], aad: [], now: step.now, v3: true)
            guard case .settled(.sealed) = answer else {
                Issue.record("\(label): an advance's seal \(answer)")
                return
            }
        }
        try Replay.expectState(step, in: actor, for: peer.nodeId, label)
    }

    // MARK: Opens

    private func open(_ step: Step, by actor: EngineFixture, from peer: IdentityKeys, _ label: String) throws {
        let index = try #require(step.opens)
        let frame = try #require(frames[index], "\(label): the frame it opens")
        let opensAReset = transcript.steps.first { $0.step == step.opens }?.op == "reset"
        if opensAReset {
            acknowledgeAllButTheResealed(by: actor, to: peer)
        }
        let before = actor.transport.written.count
        let drops = actor.engine.dropped
        let held = actor.stores.messages.contains(frame.envelope.id)
        if acknowledgesBack(index) {
            unlisted(ackBackOf: frame, by: actor, from: peer)
        } else {
            actor.engine.receive(frame)
        }
        if step.expect == "OPENED" {
            #expect(actor.engine.dropped == drops, "\(label): opened with no drop")
            #expect(actor.stores.messages.contains(frame.envelope.id) || opensAReset || held, "\(label): delivered")
        } else if step.op == "skip" || held {
            // A copy of an id whose row exists meets the exists-gate, or the router inside its window: never decrypted.
            #expect(actor.engine.dropped == drops, "\(label): nothing opened, nothing dropped")
        } else {
            let reason = try #require(step.expect.flatMap { Replay.dropReason("RATCHET_" + $0) })
            #expect(actor.engine.dropped[reason, default: 0] == drops[reason, default: 0] + 1, "\(label): \(reason)")
        }
        let resealed = actor.transport.written.dropFirst(before).filter { written in
            written.envelope.type == .chat && written.envelope.recipientId == peer.nodeId.string
        }
        for written in resealed {
            reseals[written.envelope.id] = (written, step.now)
        }
        // The open's own state is the file's unless the engine went straight on to seal again: the next step checks that.
        if resealed.isEmpty {
            try Replay.expectState(step, in: actor, for: peer.nodeId, label)
        }
    }

    /// Whether the frame step `index` sealed is a plain DM, which its receiver acknowledges: anything but machinery.
    private func acknowledgesBack(_ index: Int) -> Bool {
        guard let source = transcript.steps.first(where: { $0.step == index }), source.op == "seal",
            let bytes = source.plaintext.flatMap(Hex.decode)
        else {
            return false
        }
        let compact = source.version == EncEnvelope.Version.compactRatchet
        let content = compact ? MessageContentV2.decode(bytes) : try? MessageContent(decoding: bytes)
        return content != nil && content?.ctl == nil
    }

    /// `actor` takes in `frame`, a plain DM from `peer`, with its pinned row for `peer` reading as a build without the
    /// ratchet, so the receipt it answers with goes in the clear: the file lists no ack-back, and a sealed one would spend a
    /// key and a draw it does not list. The open itself reads only the row's bundle, and the row is put back as it was.
    private func unlisted(ackBackOf frame: InboundFrame, by actor: EngineFixture, from peer: IdentityKeys) {
        guard let pinned = actor.stores.peers.peer(peer.nodeId) else {
            actor.engine.receive(frame)
            return
        }
        var plain = pinned
        plain.capabilities = Capabilities(rawValue: pinned.capabilities ?? 0).subtracting(.ratchet).rawValue
        actor.stores.peers.upsert(plain)
        actor.engine.receive(frame)
        actor.stores.peers.upsert(pinned)
    }

    /// Bob's receipts for every DM of Alice's he opened before his reset, so only the one the file seals again is unacked:
    /// the file models no tick, and seals again only what `resealOf` names.
    private func acknowledgeAllButTheResealed(by actor: EngineFixture, to peer: IdentityKeys) {
        let resealed = Set(
            transcript.steps.compactMap { step in step.resealOf.flatMap { index in transcript.steps.first { $0.step == index }?.frameId } })
        for message in actor.stores.messages.messages(in: peer.nodeId.string)
        where message.senderId == actor.me.nodeId && !resealed.contains(message.id) {
            actor.stores.messages.markDelivered(message.id)
        }
    }

    /// The state the file lists after a re-seal, with the new epoch's two stamps at `resealedAt`: the engine seals again as
    /// the reset commits, where the file seals a second later.
    private func expectState(_ step: Step, in actor: EngineFixture, for peer: IdentityKeys, resealedAt: Int64, _ label: String) throws {
        var stated = StoredStateDigest(try #require(step.state))
        if var session = stated.session, session[13] == "\(step.now)" {
            session[13] = "\(resealedAt)"
            stated.session = session
        }
        stated.localEpochs = stated.localEpochs.map { $0.replacingOccurrences(of: "/\(step.now)/", with: "/\(resealedAt)/") }
        #expect(StoredStateDigest(actor.stores.ratchet.records(of: peer.nodeId)) == stated, "\(label): the state")
    }
}
