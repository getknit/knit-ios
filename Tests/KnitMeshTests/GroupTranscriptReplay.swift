import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// One group transcript's run through both session layers (`GroupWorld` and `Transcript`, knit-next's `GroupTranscript.kt`
/// and `RatchetTranscript.kt` on the A9 branch): every DM step through the party's ``RatchetSessions``, as `SessionReplay`
/// runs the DM transcripts, every group step through its ``GroupRatchetSessions``. What the pipeline and `MeshManager` do
/// around the two, which phase P6a2 wires, is done here as A9's mirror does it: a seed DM's outbox stamp beside its seal,
/// in one unit; a group-key DM's seeds adopted, or its ack stamped, inside its open's unit, the adoption's floor settled
/// after; a key request's floor stamped once it is sealed; the key-request heuristic fed a group open's `NO_KEY` or
/// `AEAD_FAIL`; a departure's retirement; a restore. Every seal is checked byte for byte and every open's outcome and
/// plaintext, and after every step the actor's DM state for its peer and its group state as the file digests them.
///
/// Not compared: the roster a seed pins (phase P6a2's, `GroupStore`'s), and the spool's root, which this port keeps raw
/// in `gr` and never adopts or sends (ADR 2026-10.5sk9). Bob's onward root gossip in `groupRoot` is a DM the session layer
/// seals from the file's plaintext; this port's mesh never originates one.
struct GroupTranscriptReplay {
    let transcript: RatchetVectors.GroupTranscript
    let parties: [String: GroupTranscriptParty]
    let names: [NodeId: String]
    /// The DM frames sealed so far, by step, for the opens that name them.
    var directFrames: [Int: RatchetSessions.Frame] = [:]
    /// The group frames sealed so far, by step.
    var groupFrames: [Int: GroupRatchetSessions.Frame] = [:]

    init(_ transcript: RatchetVectors.GroupTranscript, kind: GroupSessionKind) throws {
        self.transcript = transcript
        var built: [String: GroupTranscriptParty] = [:]
        for name in transcript.parties.keys {
            built[name] = try GroupTranscriptParty(name, in: transcript, kind: kind)
        }
        parties = built
        names = Dictionary(uniqueKeysWithValues: built.values.map { ($0.nodeId, $0.name) })
    }

    mutating func run() throws {
        for step in transcript.steps {
            let actor = try #require(parties[step.actor])
            let label = "\(transcript.name) step \(step.step)"
            switch step.op {
            case "seal":
                try seal(try #require(step.dm), actor: actor, label: label)
            case "open":
                try open(try #require(step.dm), applies: step.applies, actor: actor, label: label)
            case "reset":
                try reset(try #require(step.dm), actor: actor, label: label)
            case "groupSeal":
                try groupSeal(step, actor: actor, label: label)
            case "groupOpen":
                try groupOpen(step, actor: actor, label: label)
            case "depart":
                try depart(step, actor: actor)
            case "restore":
                try actor.restore()
            default:
                Issue.record("\(label): \(step.op) is not a group transcript's")
            }
            #expect(step.groupState.of == actor.name)
            #expect(digest(actor.groupStore.holdings(of: transcript.groupId)) == digest(step.groupState), "\(label): the group state")
        }
        for party in parties.values {
            #expect(party.draws.spent, "\(transcript.name): \(party.name) took \(party.draws.count) of its planned draws")
        }
    }

    /// A DM through `RatchetSessions.sealDm` from the file's plaintext. A seed DM carries seeds the sender holds, and goes
    /// in one unit with its outbox stamp, as P6b's send will; a key request stamps its floor once sealed (`keyRequest`,
    /// `GroupTranscript.kt:256-267`). An ack passes no prekey: its session exists by construction.
    private mutating func seal(_ step: RatchetVectors.TranscriptStep, actor: GroupTranscriptParty, label: String) throws {
        let peer = try #require(parties[step.peer])
        expectFloors(step, actor: actor, peer: peer, label: label)
        let aad = try self.aad(step, from: actor, to: peer, label: label)
        let plaintext = try RatchetVectorReplay.bytes(try #require(step.plaintext))
        let content = try MessageContent(decoding: plaintext)
        let prekey = try step.peerPrekey.map { named in
            let pin = try #require(actor.pins[peer.name])
            #expect(pin.name == named, "\(label): the prekey sealed against")
            return pin.prekey
        }
        let drawn = actor.draws.count
        let envelope: EncEnvelope
        if content.ctl == MessageContent.Control.groupKey, let gk = content.gk, let epoch = gk.keys.first?.epoch {
            let held = actor.group.currentSeeds(of: gk.groupId).settledValue ?? []
            #expect(gk.keys.allSatisfy { held.contains($0) }, "\(label): the seeds the sender holds")
            let seedDM = SeedDM(plaintext: plaintext, aad: aad, epoch: epoch, group: gk.groupId, prekey: prekey, now: step.now)
            envelope = try seal(seedDM, from: actor, to: peer)
        } else {
            let answer = actor.dm.sealDm(to: peer.identity.bundle, prekey: prekey, plaintext: plaintext, aad: aad, now: step.now)
            guard case .settled(.sealed(let sealed)) = answer else {
                Issue.record("\(label): expected a sealed DM, got \(answer)")
                return
            }
            envelope = sealed
        }
        if content.ctl == MessageContent.Control.groupKeyRequest, let gk = content.gk {
            actor.group.markKeyRequested(in: gk.groupId, from: peer.nodeId, now: step.now)
        }
        #expect(Array(drawn..<actor.draws.count) == step.drawsUsed, "\(label): the draws it took")
        try check(envelope, against: step, label: label)
        directFrames[step.step] = RatchetSessions.Frame(
            header: try #require(envelope.ratchet), nonce: envelope.nonce, ct: envelope.ct, aad: aad)
        try expectState(step, actor: actor, peer: peer, label: label)
    }

    /// What a seed DM's seal is asked for.
    private struct SeedDM {
        let plaintext: [UInt8]
        let aad: [UInt8]
        /// The newest epoch it carries, the outbox's stamp.
        let epoch: Int
        let group: String
        let prekey: PeerPrekey?
        let now: Int64
    }

    /// A seed DM's seal and its outbox stamp in one unit, the outermost, the DM's settlement applied after it commits.
    private func seal(_ seed: SeedDM, from actor: GroupTranscriptParty, to peer: GroupTranscriptParty) throws -> EncEnvelope {
        let unit = actor.transactor.atomically { () -> (EncEnvelope, RatchetSessions.Settlement)? in
            guard case .joined(.some, _) = actor.group.markKeySent(seed.epoch, to: peer.nodeId, in: seed.group, now: seed.now),
                case .joined(.sealed(let envelope), let settlement) = actor.dm.sealDm(
                    to: peer.identity.bundle, prekey: seed.prekey, plaintext: seed.plaintext, aad: seed.aad, now: seed.now)
            else {
                return nil
            }
            return (envelope, settlement)
        }
        guard case .committed(let (envelope, settlement)) = unit else {
            Issue.record("a seed DM's unit commits: \(unit)")
            throw GroupRatchetSessionsTests.Unexpected()
        }
        actor.dm.settle(settlement)
        return envelope
    }
}
