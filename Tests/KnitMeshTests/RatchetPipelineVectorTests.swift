import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A9's pipeline-layer transcripts through the engine's inbound path (ADR 2026-10.5sk9, phase P5a): Bob's side of `dm`'s
/// `ctlPlane`, and the `negative` cases Kotlin refuses above its engine. Each open is delivered as it arrives off a link,
/// and checked as `InboundPipelineTest` checks it: the drop, what it applies, and the state it leaves. Since P5d Bob's
/// tick back is his engine's sealed receipt, one per plain DM and none for machinery, as Kotlin's `checkTickBack` reads it
/// (`InboundPipelineTest.kt:5784-5797` on the A9 branch). The file lists none of them, so the state compared is what his
/// opens leave; the receipts' contents are checked where the file lists them, in Carol's ticks.
@Suite struct RatchetPipelineVectorTests {
    private typealias Replay = RatchetVectorReplay

    @Test func bobOpensAlicesControlPlaneThroughTheEngine() throws {
        let transcript = try #require(Replay.file.dm.first { $0.name == "ctlPlane" })
        #expect(transcript.pipelineReplay == true)
        let start = try #require(transcript.steps.first).now
        let bob = try Replay.receiver(transcript, as: "bob", peer: "alice", wall: start)
        let alice = try Replay.identity("alice").nodeId
        let bobId = bob.me.nodeId
        for sent in try #require(transcript.fixtures?.bobSent) {
            let record = MessageRecord(
                id: sent.id, senderId: bobId, recipientId: alice, conversationId: alice.string, body: "", sentAt: start - 60_000)
            bob.stores.messages.save(record)
        }
        let names = ["alice": alice, "bob": bobId]
        var drops = bob.engine.dropped
        for step in transcript.steps where step.actor == "bob" && step.op == "open" {
            let label = "ctlPlane step \(step.step)"
            Replay.move(bob, to: step.now)
            Replay.expectFloors(step, in: bob, for: alice, label)
            bob.transport.clear()
            bob.engine.receive(try Replay.frame(of: step))
            if step.expect == "OPENED" {
                #expect(bob.engine.dropped == drops, "\(label): opened with no drop")
                Replay.expectApplies(step, in: bob, names: names, label)
            } else {
                let drop = try #require(step.drop)
                let reason = try #require(Replay.dropReason(drop))
                #expect(bob.engine.dropped[reason, default: 0] == drops[reason, default: 0] + 1, "\(label): \(reason)")
                #expect(bob.transport.written.isEmpty, "\(label): refused before anything committed, so nothing went out")
            }
            try Replay.expectState(step, in: bob, for: alice, label, receiveSide: true)
            drops = bob.engine.dropped
        }
        #expect(bob.engine.ratchet.floors(for: alice).undecryptableIds == 0, "nothing counted toward a reset")
    }

    @Test(arguments: ["initEphLowOrder", "v3NonEmptyNonce", "v2EmptyNonce", "v3ToGroup"])
    func bobRefusesThePipelinesNegativesWithNothingCommittedOrCounted(name: String) throws {
        let transcript = try #require(Replay.file.negative.first { $0.name == name })
        #expect(transcript.pipelineReplay == true)
        let step = try #require(transcript.steps.last)
        #expect(step.actor == "bob" && step.op == "open" && step.layer == "pipeline" && step.expect == "REFUSED")
        let bob = try Replay.receiver(transcript, as: "bob", peer: "alice", wall: step.now)
        let alice = try Replay.identity("alice").nodeId
        bob.transport.clear()
        bob.engine.receive(try Replay.frame(of: step))

        let drop = try #require(step.drop)
        let stated = try #require(Replay.dropReason(drop))
        if step.dropNormative == false {
            // Not normative: any refusal with nothing committed and no reset trigger, named BAD_HEADER or DECRYPT_FAILED.
            let named = bob.engine.dropped[.cannotOpen, default: 0] + bob.engine.dropped[.ratchetBadHeader, default: 0]
            #expect(named == 1, "\(name): \(bob.engine.dropped)")
        } else {
            #expect(bob.engine.dropped[stated] == 1, "\(name): \(bob.engine.dropped)")
        }
        #expect(step.resetTriggering == false)
        #expect(bob.engine.ratchet.floors(for: alice).undecryptableIds == 0, "\(name): counted toward nothing")
        #expect(bob.stores.ratchet.records(of: alice) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
        #expect(bob.transport.written(.chat).isEmpty && bob.transport.written(.receipt).isEmpty, "\(name): nothing sent")
        #expect(bob.stores.messages.message(step.frameId ?? "") == nil)
        try Replay.expectState(step, in: bob, for: alice, name)
    }
}

/// A9's `carol` section through the iPhone's engine (ADR 2026-10.5sk9, phases P5a, P5b and P5d): every step where Carol, the
/// iPhone, opens what Android sends her, races and first contacts both ways, each against the state Android's own pipeline
/// left, every DM she writes, sent through her engine from a waiting row, and every tick her pipeline seals back for a
/// plain DM she opened (`sealDmReceipt`), each byte for byte as the file lists it. The file's tick carries the frame id
/// Kotlin's pipeline minted, so the replay hands her engine that id for the receipt it mints; its `sentAt` is the open's
/// clock, as Kotlin's is. The state an open that ticks back leaves is checked after its tick, as `InboundPipelineTest`
/// checks it.
@Suite struct RatchetCarolVectorTests {
    private typealias Replay = RatchetVectorReplay

    static let scenarios = RatchetVectorReplay.file.carol.map(\.name)

    @Test(arguments: scenarios)
    func carolOpensWhatAndroidSendsHer(name: String) throws {
        let transcript = try #require(Replay.file.carol.first { $0.name == name })
        let peer = try #require(transcript.parties.keys.first { $0 != "carol" })
        let first = try #require(transcript.steps.first)
        let draws = VectorDraws(owner: "carol", plan: transcript.draws["carol"] ?? [])
        let carol = try Replay.receiver(transcript, as: "carol", peer: peer, wall: first.now, draws: draws)
        let peerKeys = try Replay.identity(peer)
        let seals = CarolSeals(carol: carol, peer: peerKeys)
        let names = ["carol": carol.me.nodeId, peer: peerKeys.nodeId]

        for step in transcript.steps where step.actor == "carol" {
            let label = "\(name) step \(step.step)"
            Replay.move(carol, to: step.now)
            switch step.op {
            case "seal" where step.sealedByPipeline == true:
                Replay.expectFloors(step, in: carol, for: peerKeys.nodeId, label)
                try seals.checkTick(step, label)
            case "seal":
                try seals.seal(step, label)
            case "open":
                Replay.expectFloors(step, in: carol, for: peerKeys.nodeId, label)
                carol.transport.clear()
                let drops = carol.engine.dropped
                let tick = step.applies?.tickStep.flatMap { index in transcript.steps.first { $0.step == index } }
                if let id = tick?.frameId {
                    carol.engine.random = try ScriptedFrameIds(id, then: SeededGenerator(seed: UInt64(step.step) &+ 1000))
                }
                carol.engine.receive(try Replay.frame(of: step))
                #expect(step.expect == "OPENED" && carol.engine.dropped == drops, "\(label): opened")
                Replay.expectApplies(step, in: carol, names: names, label)
                seals.heard(Replay.ackBacks(in: carol, to: peerKeys.nodeId))
                if tick != nil {
                    // The tick went in the same delivery: the state it leaves is the tick step's to check.
                    continue
                }
            default:
                Issue.record("\(label): \(step.op) is no step of Carol's")
            }
            try Replay.expectState(step, in: carol, for: peerKeys.nodeId, label)
        }
        #expect(draws.spent, "\(name): Carol took every draw her plan lists")
        let sealSteps = transcript.steps.filter { $0.actor == "carol" && $0.op == "seal" }.count
        #expect(!seals.sent.isEmpty && seals.sent.count + seals.ticks == sealSteps, "\(name): every seal of hers through her engine")
    }
}

/// Carol's own seals in a replay, on her draws, each checked against the bytes the file lists. A DM she writes goes
/// through her engine's send path from a waiting row (P5b), which leaves the row a later tick flips; a tick is the sealed
/// receipt her engine sent as it delivered the DM before it (P5d), originated: signed, flooded and carried.
private final class CarolSeals {
    let carol: EngineFixture
    let peer: IdentityKeys
    /// The DMs her engine sent, by id.
    private(set) var sent: [String] = []
    /// How many of her ticks matched the file.
    private(set) var ticks = 0
    /// The sealed receipt her last open sent back, if one did.
    private var lastTick: Written?

    init(carol: EngineFixture, peer: IdentityKeys) {
        self.carol = carol
        self.peer = peer
    }

    /// What Carol's open just sent back: at most one sealed receipt.
    func heard(_ ackBacks: [Written]) {
        lastTick = ackBacks.last
    }

    /// A tick her pipeline sealed back (`sealedByPipeline`), against the receipt her engine sent at the open before it.
    func checkTick(_ step: RatchetVectors.TranscriptStep, _ label: String) throws {
        let written = try #require(lastTick, "\(label): her engine sealed a receipt back")
        lastTick = nil
        let enc = try #require(try ChatContent(decoding: written.envelope.payload).enc)
        #expect(written.envelope.id == step.frameId && written.envelope.sentAt == step.sentAt, "\(label): the file's id and clock")
        #expect(Hex.encode(enc.encoded) == step.encEnvelope, "\(label): the tick her engine sealed, byte for byte")
        let wire = try WireEnvelope(decoding: try RatchetVectorReplay.bytes(try #require(step.wire)))
        #expect(written.wire.signed == wire.signed, "\(label): the signed bytes")
        #expect(written.wire.relay && written.to == nil, "\(label): originated, flooded")
        #expect(carol.me.keys.bundle.isValidSignature(written.wire.sig, for: written.wire.signed), "\(label): signed once, and it verifies")
        #expect(carol.stores.custody.contains(written.envelope.id), "\(label): and carried")
        ticks += 1
    }

    func seal(_ step: RatchetVectors.TranscriptStep, _ label: String) throws {
        let hex = try #require(step.plaintext)
        let plaintext = try RatchetVectorReplay.bytes(hex)
        let v3 = step.version == EncEnvelope.Version.compactRatchet
        let content = v3 ? MessageContentV2.decode(plaintext) : try MessageContent(decoding: plaintext)
        if let content, content.ctl == nil, let id = step.frameId, let sentAt = step.sentAt {
            let row = MessageRecord(
                id: id,
                senderId: carol.me.nodeId,
                recipientId: peer.nodeId,
                conversationId: peer.nodeId.string,
                body: content.body,
                sentAt: sentAt,
                pendingKey: true
            )
            #expect(MeshEngine.content(of: row).sealBytes(v3: true).plaintext == plaintext, "\(label): the row seals the file's plaintext")
            carol.stores.messages.save(row)
            let before = carol.transport.written.count
            carol.engine.flushPendingDirect(to: peer.nodeId)
            let written = carol.transport.written.dropFirst(before).last { $0.envelope.id == id }
            let enc = try #require(written.flatMap { try? ChatContent(decoding: $0.envelope.payload).enc }, "\(label): sent")
            #expect(Hex.encode(enc.encoded) == step.encEnvelope, "\(label): the envelope her engine sent, byte for byte")
            sent.append(id)
            return
        }
        Issue.record("\(label): every seal of Carol's is a DM she writes or a tick her pipeline seals back")
    }
}
