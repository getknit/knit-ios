import KnitTestSupport
import KnitWire
import Testing

@testable import KnitCrypto

/// One transcript's run at the engine (`Transcript.seal`, `.open` and `.advance` in knit-next's
/// `RatchetTranscript.kt:420-745`).
struct TranscriptReplay {
    /// A DM frame as the engine reads it: what a seal step made, or what an open step lists.
    private struct Frame: Equatable {
        let header: RatchetHeader
        let nonce: [UInt8]?
        let ct: [UInt8]
        let aad: [UInt8]
    }

    private let transcript: RatchetVectors.Transcript
    private let parties: [String: ReplayParty]
    private let aboveTheEngine: [Int: RatchetTranscriptTests.AboveTheEngine]
    private var sealed: [Int: Frame] = [:]

    init(
        _ transcript: RatchetVectors.Transcript,
        file: RatchetVectors.File,
        aboveTheEngine: [Int: RatchetTranscriptTests.AboveTheEngine]
    ) throws {
        self.transcript = transcript
        var built: [String: ReplayParty] = [:]
        for name in transcript.parties.keys {
            built[name] = try ReplayParty(name, in: transcript, file: file)
        }
        parties = built
        self.aboveTheEngine = aboveTheEngine
    }

    mutating func run() throws {
        for step in transcript.steps {
            let actor = try #require(parties[step.actor])
            let peer = try #require(parties[step.peer])
            switch step.op {
            case "seal":
                try seal(step, actor: actor, peer: peer)
            case "open":
                try open(step, actor: actor, sender: peer)
            case "advance":
                try advance(step, actor: actor, peer: peer)
            default:
                Issue.record("\(transcript.name) step \(step.step): \(step.op) is not the engine's")
            }
            let stated = try #require(step.state, "\(transcript.name) step \(step.step) lists a state")
            #expect(stated.of == actor.name && stated.peer == peer.name)
            let held = RatchetStateDigest(actor.rows[peer.name] ?? RatchetRows())
            #expect(held == RatchetStateDigest(stated), "\(transcript.name) step \(step.step): the state")
        }
        for party in parties.values {
            #expect(party.draws.spent, "\(transcript.name): \(party.name) took \(party.draws.count) of its planned draws")
        }
    }

    /// A DM sealed as `RatchetSessions.sealDm` seals one: X3DH on the pinned prekey when no session is held, then the
    /// engine's seal against that prekey, committed before the frame leaves.
    private mutating func seal(_ step: RatchetVectors.TranscriptStep, actor: ReplayParty, peer: ReplayParty) throws {
        let label = "\(transcript.name) step \(step.step)"
        let pin = try #require(actor.pins[peer.name])
        #expect(pin.name == step.peerPrekey, "\(label): the prekey sealed against")
        let id = try #require(step.frameId)
        let aad = MessageCrypto.header(id: id, senderId: actor.nodeId.string, sentAt: try #require(step.sentAt), thread: peer.nodeId.string)
        #expect(hexString(aad) == step.aad, "\(label): the v1 header")
        var rows = actor.rows[peer.name] ?? RatchetRows()
        let drawn = actor.draws.count
        var initiation: RatchetEngine.Initiation?
        if rows.session == nil {
            initiation = try actor.engine.initiate(
                peerId: peer.nodeId,
                identity: actor.identity,
                peerIdentity: peer.identity.bundle,
                peerPrekey: pin.prekey,
                now: step.now
            )
        }
        let state = try #require(initiation?.session ?? rows.session)
        let sealing = try actor.engine.seal(
            state,
            plaintext: hexBytes(try #require(step.plaintext)),
            aad: aad,
            peerPrekey: pin.prekey,
            now: step.now,
            v3: step.version == EncEnvelope.Version.compactRatchet
        )
        let result = try #require(sealing)
        rows.commitSend(result.session, newLocalEpoch: initiation?.epoch ?? result.newLocalEpoch)
        actor.rows[peer.name] = rows

        #expect(Array(drawn..<actor.draws.count) == step.drawsUsed, "\(label): the draws it took")
        #expect(result.header == (try #require(step.header).ratchetHeader), "\(label): the header")
        #expect(hexString(result.nonce ?? []) == step.nonce, "\(label): the nonce")
        #expect(hexString(result.ct) == step.ct, "\(label): the ciphertext")
        let envelope = EncEnvelope(version: step.version ?? 0, nonce: result.nonce ?? [], ct: result.ct, keys: [], ratchet: result.header)
        #expect(hexString(envelope.encoded) == step.encEnvelope, "\(label): the envelope")
        sealed[step.step] = Frame(header: result.header, nonce: result.nonce, ct: result.ct, aad: aad)
    }

    /// A DM opened as `InboundPipeline.decryptAndDeliverV2` opens one through `RatchetSessions.contextFor` and
    /// `commitOpen`: the v1 header as AAD, the nonce dropped for v3, and the replacement floor the session layer keeps
    /// (`RatchetSessions.kt:143-160`: a minute for `FLAG_RESET`, else an hour), stamped when an open adopts a root.
    private mutating func open(_ step: RatchetVectors.TranscriptStep, actor: ReplayParty, sender: ReplayParty) throws {
        let label = "\(transcript.name) step \(step.step)"
        let frame = Frame(
            header: try #require(step.header).ratchetHeader,
            nonce: step.version == EncEnvelope.Version.compactRatchet ? nil : hexBytes(try #require(step.nonce)),
            ct: hexBytes(try #require(step.ct)),
            aad: hexBytes(try #require(step.aad))
        )
        if step.mutation == nil, let made = sealed[try #require(step.opens)] {
            #expect(made == frame, "\(label): the frame as sealed")
        }
        var rows = actor.rows[sender.name] ?? RatchetRows()
        let header = frame.header
        let resetRequested = header.flags & RatchetHeader.resetFlag != 0
        let floor: Int64 = resetRequested ? 60_000 : 3_600_000
        let context = RatchetEngine.OpenContext(
            selfNodeId: actor.nodeId,
            peerId: sender.nodeId,
            session: rows.session,
            recvEpochs: rows.chains(for: header),
            skippedKeys: rows.skippedKeys(for: header),
            ownBasePrivateKey: rows.ownBasePrivateKey(for: header),
            identity: actor.identity,
            peerIdentity: sender.identity.bundle,
            prekeyForInit: header.initial.flatMap { initial in actor.prekey(id: initial.pkid) },
            allowReplacement: step.now &- (actor.lastReplacementAt[sender.name] ?? 0) >= floor,
            resetRequested: resetRequested
        )
        if let refusal = aboveTheEngine[step.step] {
            try refuse(frame, as: refusal, at: actor, context: context, now: step.now)
            return
        }
        #expect(step.layer == "engine", "\(label): an engine-layer open")
        let outcome = try actor.engine.open(context, header: header, nonce: frame.nonce, ct: frame.ct, aad: frame.aad, now: step.now)
        #expect(outcome.vectorName == step.expect, "\(label): the outcome")
        #expect(outcome.opened.map { opened in hexString(opened.plaintext) } == step.plaintext, "\(label): the plaintext")
        if let opened = outcome.opened {
            rows.apply(opened.delta, se: header.se, n: header.n)
            if opened.delta.purgePeerRecvState {
                actor.lastReplacementAt[sender.name] = step.now
            }
            actor.rows[sender.name] = rows
        }
    }

    /// A pipeline-layer open: what the engine does with it, if this phase calls it at all. Nothing commits either way.
    private func refuse(
        _ frame: Frame,
        as refusal: RatchetTranscriptTests.AboveTheEngine,
        at actor: ReplayParty,
        context: RatchetEngine.OpenContext,
        now: Int64
    ) throws {
        switch refusal {
        case .notCalled:
            break
        case .throwsOut:
            #expect(throws: RatchetCryptoError.self, "\(transcript.name): out of the engine, never a typed AEAD_FAIL") {
                try actor.engine.open(context, header: frame.header, nonce: frame.nonce, ct: frame.ct, aad: frame.aad, now: now)
            }
        case .refuses(let failure, _):
            let outcome = try actor.engine.open(context, header: frame.header, nonce: frame.nonce, ct: frame.ct, aad: frame.aad, now: now)
            #expect(outcome.failure == failure, "\(transcript.name): the engine's refusal")
        }
    }

    /// `count` v3 seals of any content, discarded: the chain moves and nothing else (`advance`, `RatchetTranscript.kt:700-745`).
    private func advance(_ step: RatchetVectors.TranscriptStep, actor: ReplayParty, peer: ReplayParty) throws {
        let label = "\(transcript.name) step \(step.step)"
        var rows = try #require(actor.rows[peer.name])
        #expect(rows.session?.sendCount == step.fromN, "\(label): where the advance starts")
        let drawn = actor.draws.count
        let pin = try #require(actor.pins[peer.name])
        let aad = MessageCrypto.header(id: "filler", senderId: actor.nodeId.string, sentAt: step.now, thread: peer.nodeId.string)
        for _ in 0..<(try #require(step.count)) {
            let state = try #require(rows.session)
            let sealing = try actor.engine.seal(
                state, plaintext: Array("filler".utf8), aad: aad, peerPrekey: pin.prekey, now: step.now, v3: true)
            let result = try #require(sealing)
            rows.commitSend(result.session, newLocalEpoch: result.newLocalEpoch)
        }
        actor.rows[peer.name] = rows
        #expect(actor.draws.count == drawn, "\(label): an advance draws nothing")
    }
}

extension RatchetVectors.TranscriptHeader {
    /// The header as KnitWire's type.
    var ratchetHeader: RatchetHeader {
        RatchetHeader(
            se: se,
            ek: hexBytes(ek),
            pe: pe,
            n: n,
            initial: initial.map { initial in RatchetInit(eph: hexBytes(initial.eph), pkid: initial.pkid, at: initial.at) },
            flags: flags
        )
    }
}
