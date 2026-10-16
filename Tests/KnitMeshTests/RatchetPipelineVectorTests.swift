import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A9's pipeline-layer transcripts through the engine's inbound path (ADR 2026-10.5sk9, phase P5a): Bob's side of `dm`'s
/// `ctlPlane`, and the `negative` cases Kotlin refuses above its engine. Each open is delivered as it arrives off a link,
/// and checked as `InboundPipelineTest` checks it: the drop, what it applies, and the state it leaves. Bob's ticks back are
/// P5c's: only whether he acknowledges is read, off this build's cleartext receipt.
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
            try Replay.expectState(step, in: bob, for: alice, label)
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

/// A9's `carol` section through the iPhone's engine (ADR 2026-10.5sk9, phase P5a): every step where Carol, the iPhone,
/// opens what Android sends her, races and first contacts both ways, each against the state Android's own pipeline left.
/// Carol's own seals, her openers and her ticks, are P5b's and P5c's: here a second facade over her store seals them from
/// her draws, byte for byte as the file lists them, so the state her opens meet is the file's.
@Suite struct RatchetCarolVectorTests {
    private typealias Replay = RatchetVectorReplay

    static let scenarios = RatchetVectorReplay.file.carol.map(\.name)

    @Test(arguments: scenarios)
    func carolOpensWhatAndroidSendsHer(name: String) throws {
        let transcript = try #require(Replay.file.carol.first { $0.name == name })
        let peer = try #require(transcript.parties.keys.first { $0 != "carol" })
        let first = try #require(transcript.steps.first)
        let carol = try Replay.receiver(transcript, as: "carol", peer: peer, wall: first.now)
        let peerKeys = try Replay.identity(peer)
        let pinnedName = try #require(transcript.parties["carol"]?.pins[peer])
        let pinned = try Replay.prekey(pinnedName)
        let draws = VectorDraws(owner: "carol", plan: transcript.draws["carol"] ?? [])
        let seals = CarolSeals(
            sealer: RatchetSessions(
                identity: carol.engine.identity,
                store: carol.stores.ratchet,
                transactor: carol.stores.transactor,
                engine: draws.engine
            ),
            carol: carol,
            peer: peerKeys,
            prekey: try #require(PeerPrekey(verifying: pinned.info, signedBy: peerKeys.bundle))
        )
        let names = ["carol": carol.me.nodeId, peer: peerKeys.nodeId]

        for step in transcript.steps where step.actor == "carol" {
            let label = "\(name) step \(step.step)"
            Replay.move(carol, to: step.now)
            switch step.op {
            case "seal":
                try seals.seal(step, label)
            case "open":
                Replay.expectFloors(step, in: carol, for: peerKeys.nodeId, label)
                carol.transport.clear()
                let drops = carol.engine.dropped
                carol.engine.receive(try Replay.frame(of: step))
                #expect(step.expect == "OPENED" && carol.engine.dropped == drops, "\(label): opened")
                Replay.expectApplies(step, in: carol, names: names, label)
            default:
                Issue.record("\(label): \(step.op) is no step of Carol's")
            }
            try Replay.expectState(step, in: carol, for: peerKeys.nodeId, label)
        }
        #expect(draws.spent, "\(name): Carol took every draw her plan lists")
    }
}

/// Carol's own seals in a replay: a second facade over her engine's store, on her draws, which seals each as the file
/// lists its bytes. A DM she writes is stored as her send will store it (P5b), so the tick that later acknowledges it has
/// a row to flip.
private struct CarolSeals {
    let sealer: RatchetSessions
    let carol: EngineFixture
    let peer: IdentityKeys
    let prekey: PeerPrekey

    func seal(_ step: RatchetVectors.TranscriptStep, _ label: String) throws {
        let plaintext = try RatchetVectorReplay.bytes(try #require(step.plaintext))
        let v3 = step.version == EncEnvelope.Version.compactRatchet
        let answer = sealer.sealDm(
            to: peer.bundle,
            prekey: prekey,
            plaintext: plaintext,
            aad: try RatchetVectorReplay.bytes(try #require(step.aad)),
            now: step.now,
            v3: v3
        )
        guard case .settled(.sealed(let envelope)) = answer else {
            Issue.record("\(label): Carol's seal \(answer)")
            return
        }
        #expect(Hex.encode(envelope.encoded) == step.encEnvelope, "\(label): the envelope, byte for byte")
        let content = v3 ? MessageContentV2.decode(plaintext) : try MessageContent(decoding: plaintext)
        guard let content, content.ctl == nil, let id = step.frameId, let sentAt = step.sentAt else {
            return
        }
        let record = MessageRecord(
            id: id,
            senderId: carol.me.nodeId,
            recipientId: peer.nodeId,
            conversationId: peer.nodeId.string,
            body: content.body,
            sentAt: sentAt
        )
        carol.stores.messages.save(record)
    }
}
