import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitCrypto

/// One transcript's run through the session layer (`Transcript.seal`, `.open` and `.reset` in knit-next's
/// `RatchetTranscript.kt:420-653`, whose parties each hold a real `RatchetSessions`): every party a real
/// ``RatchetSessions`` over a memory store, on the engine ``ReplayParty`` feeds its listed draws. Before each step the
/// party's floors held in memory must be the listed `floorsBefore`, and after it its rows must digest to the listed state,
/// read back through ``RatchetRecords``.
struct SessionReplay {
    /// A transcript party and the session layer it runs.
    final class Party {
        let replay: ReplayParty
        let store = MemoryRatchetStore()
        let sessions: RatchetSessions

        init(_ replay: ReplayParty) {
            self.replay = replay
            sessions = RatchetSessions(
                identity: replay.identity, store: store, transactor: MemoryTransactor(stores: [store]), engine: replay.engine)
        }

        /// What the party's store holds for `peer`, as the engine's rows.
        func rows(for peer: Party) -> RatchetRows {
            let records = store.records(of: peer.replay.nodeId)
            var rows = RatchetRows()
            rows.session = records.session.map(RatchetRecords.session)
            for epoch in records.localEpochs {
                rows.localEpochs[epoch.epoch] = RatchetRecords.localEpoch(epoch)
            }
            for chain in records.recvEpochs {
                rows.chains[RatchetRows.ChainKey(epoch: chain.epoch, rootTag: chain.rootTag)] = RatchetRecords.recvEpoch(chain)
            }
            for key in records.skippedKeys {
                rows.skippedKeys[RatchetRows.SkippedKeyId(epoch: key.epoch, index: key.index, rootTag: key.rootTag)] =
                    RatchetRecords.skippedKey(key)
            }
            return rows
        }

        /// The floors held for `peer`, as the vectors state them.
        func floors(for peer: Party) -> RatchetVectors.TranscriptFloors {
            let held = sessions.floors(for: peer.replay.nodeId)
            return RatchetVectors.TranscriptFloors(
                lastReplacementAt: held.lastReplacementAt,
                confirmedAt: held.confirmedAt,
                lastResetSentAtInMemory: held.lastResetSentAt,
                undecryptableIds: held.undecryptableIds
            )
        }
    }

    /// Each `decidedBy` the vectors write, and the rule of ``RatchetResetPolicy`` it names. A sync that adds another fails
    /// until someone decides which rule it is.
    static let decidedBy: [String: RatchetResetPolicy.Plan.Rule] = [
        "state.session is null: the restore emptied it": .noSession,
        "state.session: our own init pending (weAreInitiator, !confirmed, initPkid = the pinned prekey) and plain "
            + "(lastResetSentAt < establishedAt)": .plainInit,
        "state.session.lastResetSentAt (persisted): now - it < RESET_REPLACEMENT_MIN_INTERVAL_MS on a pending init": .resetInFlight,
        "floorsBefore.confirmedAt (cause UNREADABLE, our own init answered): declined while now - it < RESET_REPLACEMENT_MIN_INTERVAL_MS":
            .answeredInit,
        "state.session: confirmed, so no pending init; cause ON_DEMAND, so the answered-init floor does not apply": .noPendingInit,
        "state.session: Bob responded (weAreInitiator false), so no pending init and no answered-init floor": .noPendingInit,
    ]

    private let transcript: RatchetVectors.Transcript
    private let parties: [String: Party]
    private var sealed: [Int: RatchetSessions.Frame] = [:]

    init(_ transcript: RatchetVectors.Transcript, file: RatchetVectors.File) throws {
        self.transcript = transcript
        var built: [String: Party] = [:]
        for name in transcript.parties.keys {
            built[name] = Party(try ReplayParty(name, in: transcript, file: file))
        }
        parties = built
    }

    mutating func run() throws {
        for step in transcript.steps {
            let actor = try #require(parties[step.actor])
            let peer = try #require(parties[step.peer])
            let label = "\(transcript.name) step \(step.step)"
            let floors = try #require(step.floorsBefore, "\(label) lists its floors")
            #expect(actor.floors(for: peer) == floors, "\(label): the floors before it")
            switch step.op {
            case "seal":
                try seal(step, actor: actor, peer: peer)
            case "open":
                try open(step, actor: actor, sender: peer)
            case "reset":
                try reset(step, actor: actor, peer: peer)
            default:
                Issue.record("\(label): \(step.op) is not the session layer's")
            }
            let stated = try #require(step.state, "\(label) lists a state")
            #expect(stated.of == actor.replay.name && stated.peer == peer.replay.name)
            #expect(RatchetStateDigest(actor.rows(for: peer)) == RatchetStateDigest(stated), "\(label): the state")
        }
        for party in parties.values {
            #expect(
                party.replay.draws.spent, "\(transcript.name): \(party.replay.name) took \(party.replay.draws.count) of its planned draws")
        }
    }

    /// A DM sealed through `RatchetSessions.sealDm`, against the prekey the party pins, byte for byte.
    private mutating func seal(_ step: RatchetVectors.TranscriptStep, actor: Party, peer: Party) throws {
        let label = "\(transcript.name) step \(step.step)"
        let pin = try #require(actor.replay.pins[peer.replay.name])
        #expect(pin.name == step.peerPrekey, "\(label): the prekey sealed against")
        let aad = try self.aad(step, actor: actor, peer: peer)
        let drawn = actor.replay.draws.count
        let v3 = step.version == EncEnvelope.Version.compactRatchet
        let plaintext = hexBytes(try #require(step.plaintext))
        let answer = actor.sessions.sealDm(
            to: peer.replay.identity.bundle, prekey: pin.prekey, plaintext: plaintext, aad: aad, now: step.now, v3: v3)
        guard case .settled(.sealed(let envelope)) = answer else {
            Issue.record("\(label): expected a sealed DM, got \(answer)")
            return
        }
        #expect(Array(drawn..<actor.replay.draws.count) == step.drawsUsed, "\(label): the draws it took")
        try check(envelope, against: step, label: label)
        sealed[step.step] = RatchetSessions.Frame(
            header: try #require(envelope.ratchet), nonce: v3 ? nil : envelope.nonce, ct: envelope.ct, aad: aad)
    }

    /// A DM opened through `RatchetSessions.open`, one phase, the replacement floor the facade holds included.
    private func open(_ step: RatchetVectors.TranscriptStep, actor: Party, sender: Party) throws {
        let label = "\(transcript.name) step \(step.step)"
        let v3 = step.version == EncEnvelope.Version.compactRatchet
        let frame = RatchetSessions.Frame(
            header: try #require(step.header).ratchetHeader,
            nonce: v3 ? nil : hexBytes(try #require(step.nonce)),
            ct: hexBytes(try #require(step.ct)),
            aad: hexBytes(try #require(step.aad))
        )
        if step.mutation == nil, let made = sealed[try #require(step.opens)] {
            #expect(made == frame, "\(label): the frame as sealed")
        }
        #expect(step.layer == "engine", "\(label): a session-layer open")
        let replay = actor.replay
        let answer = actor.sessions.open(
            frame, from: sender.replay.identity.bundle, now: step.now, prekeys: { replay.prekey(id: $0) }, alongside: { _ in () })
        switch answer {
        case .settled(.opened(let plaintext, _)):
            #expect(step.expect == "OPENED", "\(label): the outcome")
            #expect(hexString(plaintext) == step.plaintext, "\(label): the plaintext")
        case .settled(.refused(let failure)):
            #expect(RatchetEngine.OpenOutcome.failed(failure).vectorName == step.expect, "\(label): the outcome")
            #expect(step.plaintext == nil)
        default:
            Issue.record("\(label): expected an outcome the engine names, got \(answer)")
        }
    }

    /// A reset asked of `RatchetSessions.sealResetDm` with the step's cause: its plan, the rule that decided it, and
    /// what it sealed, always v2 and byte for byte.
    private mutating func reset(_ step: RatchetVectors.TranscriptStep, actor: Party, peer: Party) throws {
        let label = "\(transcript.name) step \(step.step)"
        let pin = try #require(actor.replay.pins[peer.replay.name])
        #expect(pin.name == step.peerPrekey, "\(label): the prekey reset against")
        if let plaintext = step.plaintext {
            #expect(hexBytes(plaintext) == RatchetSessions.resetPlaintext, "\(label): the marker is MessageContent(body = \"\", ctl = 1)")
        }
        let aad = step.frameId == nil ? [] : try self.aad(step, actor: actor, peer: peer)
        let rule = Self.decidedBy[try #require(step.decidedBy)]
        let cause = try Self.cause(step.cause)
        let drawn = actor.replay.draws.count
        let answer = actor.sessions.sealResetDm(
            to: peer.replay.identity.bundle,
            prekey: pin.prekey,
            plaintext: RatchetSessions.resetPlaintext,
            aad: aad,
            now: step.now,
            cause: cause
        )
        #expect(Array(drawn..<actor.replay.draws.count) == step.drawsUsed, "\(label): the draws it took")
        switch answer {
        case .settled(.sealed(let envelope, let plan)):
            #expect((plan.action == .reRoot ? "REROOT" : "MARK") == step.result, "\(label): the plan")
            #expect(plan.decidedBy == rule, "\(label): what decided it")
            #expect(envelope.version == EncEnvelope.Version.ratchet, "\(label): a reset seals v2, toward a v3 reader too")
            try check(envelope, against: step, label: label)
            sealed[step.step] = RatchetSessions.Frame(
                header: try #require(envelope.ratchet), nonce: envelope.nonce, ct: envelope.ct, aad: aad)
        case .settled(.declined(let reason, let plan)):
            #expect(step.result == "DECLINED" && reason == step.reason, "\(label): the decline")
            #expect(plan.decidedBy == rule, "\(label): what decided it")
        default:
            Issue.record("\(label): expected a sealed or declined reset, got \(answer)")
        }
    }

    /// The step's v1 header, the AAD, which the vectors list as bytes.
    private func aad(_ step: RatchetVectors.TranscriptStep, actor: Party, peer: Party) throws -> [UInt8] {
        let aad = MessageCrypto.header(
            id: try #require(step.frameId),
            senderId: actor.replay.nodeId.string,
            sentAt: try #require(step.sentAt),
            thread: peer.replay.nodeId.string
        )
        #expect(hexString(aad) == step.aad, "\(transcript.name) step \(step.step): the v1 header")
        return aad
    }

    /// A sealed envelope against what the step lists: the header, the nonce, the ciphertext and the envelope's CBOR.
    private func check(_ envelope: EncEnvelope, against step: RatchetVectors.TranscriptStep, label: String) throws {
        #expect(envelope.version == step.version, "\(label): the version")
        #expect(envelope.ratchet == (try #require(step.header).ratchetHeader), "\(label): the header")
        #expect(hexString(envelope.nonce) == step.nonce, "\(label): the nonce")
        #expect(hexString(envelope.ct) == step.ct, "\(label): the ciphertext")
        #expect(hexString(envelope.encoded) == step.encEnvelope, "\(label): the envelope")
    }

    private static func cause(_ name: String?) throws -> RatchetResetPolicy.Cause {
        let causes: [String: RatchetResetPolicy.Cause] = ["ON_DEMAND": .onDemand, "UNREADABLE": .unreadable, "AFTER_WIPE": .afterWipe]
        let named = try #require(name)
        return try #require(causes[named], "a cause the session layer knows: \(named)")
    }
}
