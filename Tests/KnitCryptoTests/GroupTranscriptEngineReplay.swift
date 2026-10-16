import KnitTestSupport
import KnitWire
import Testing

@testable import KnitCrypto

/// One group transcript's run at the group engine alone (`GroupWorld`, knit-next's `GroupTranscript.kt` on the A9 branch,
/// with the store's rows as `MemoryGroupRatchetStore` keeps them): each party's send chains by epoch, receive chains by
/// sender, epoch and mint, and skipped keys by sender, epoch, mint and index. A group seal mints and seals through the
/// engine, byte for byte; a group open reads the party's rows and applies the delta; a group-key DM's open adopts the
/// seeds its plaintext carries; a departure retires and a restore wipes. The DM steps are the session layer's, which
/// `RatchetGroupVectorTests` replays whole: here a DM seal or reset only passes its draws, the plaintext a DM open lists
/// is what the engine adopts from, and the outbox, the roster and the spool's root are not compared.
struct GroupTranscriptEngineReplay {
    /// A party's group rows and its engine on the party's draws.
    final class Party {
        struct ChainId: Hashable {
            let sender: NodeId
            let epoch: Int
            let mintedAt: Int64
        }

        struct KeyId: Hashable {
            let sender: NodeId
            let epoch: Int
            let mintedAt: Int64
            let index: Int
        }

        let name: String
        let nodeId: NodeId
        let draws: DrawPlan
        let engine: GroupRatchetEngine
        var sendChains: [Int: GroupRatchetEngine.SendChain] = [:]
        var recvChains: [ChainId: GroupRatchetEngine.RecvChain] = [:]
        var skippedKeys: [KeyId: GroupRatchetEngine.SkippedKey] = [:]

        init(_ name: String, in transcript: RatchetVectors.GroupTranscript) throws {
            self.name = name
            let party = try #require(transcript.parties[name])
            nodeId = try #require(NodeId(party.nodeId))
            let plan = DrawPlan(owner: name, plan: transcript.draws[name] ?? [])
            draws = plan
            engine = GroupRatchetEngine(seed: { plan.groupSeed() }, iv: { plan.iv() })
        }

        var newestSendChain: GroupRatchetEngine.SendChain? {
            sendChains.values.max { $0.epoch < $1.epoch }
        }
    }

    private let transcript: RatchetVectors.GroupTranscript
    private let parties: [String: Party]
    private let names: [NodeId: String]
    /// Each group frame sealed so far, by the index of the step that sealed it.
    private var sealed: [Int: Sealed] = [:]

    private struct Sealed {
        let header: GroupRatchetHeader
        let nonce: [UInt8]
        let ct: [UInt8]
    }

    init(_ transcript: RatchetVectors.GroupTranscript) throws {
        self.transcript = transcript
        var built: [String: Party] = [:]
        for name in transcript.parties.keys {
            built[name] = try Party(name, in: transcript)
        }
        parties = built
        names = Dictionary(uniqueKeysWithValues: built.values.map { ($0.nodeId, $0.name) })
    }

    mutating func run() throws {
        for step in transcript.steps {
            let actor = try #require(parties[step.actor])
            let label = "\(transcript.name) step \(step.step)"
            switch step.op {
            case "groupSeal":
                try groupSeal(step, actor: actor, label: label)
            case "groupOpen":
                try groupOpen(step, actor: actor, label: label)
            case "seal", "reset":
                actor.draws.skip(try #require(step.dm?.drawsUsed, "\(label) lists its draws"))
            case "open":
                try adoptSeeds(step, actor: actor, label: label)
            case "depart":
                actor.sendChains = actor.newestSendChain.map { [$0.epoch: $0.retired()] } ?? [:]
            case "restore":
                actor.sendChains = [:]
                actor.recvChains = [:]
                actor.skippedKeys = [:]
            default:
                Issue.record("\(label): \(step.op) is not a group transcript's")
            }
            #expect(step.groupState.of == actor.name)
            #expect(digest(of: actor) == digest(of: step.groupState), "\(label): the group state")
        }
        for party in parties.values {
            #expect(party.draws.spent, "\(transcript.name): \(party.name) took \(party.draws.count) of its planned draws")
        }
    }

    /// A group frame sealed as `GroupRatchetSessions.sealGroup` seals one: a mint when the advance rules say, then the seal,
    /// whose header, IV, ciphertext and envelope must be the file's. The file's `minted` is always `null` (A9's
    /// `GroupTranscript.kt:205` writes the seed and then overwrites it, since `JsonObjectBuilder.put` answers the previous
    /// value, `null`), so the mint is read from the draws instead: a step that drew a seed minted with it.
    private mutating func groupSeal(_ step: RatchetVectors.GroupStep, actor: Party, label: String) throws {
        let drawn = actor.draws.count
        let held = actor.newestSendChain
        let minted =
            GroupRatchetEngine.needsNewEpoch(held, now: step.now)
            ? actor.engine.mint(groupId: transcript.groupId, selfId: actor.nodeId, previousEpoch: held?.epoch ?? 0, now: step.now) : nil
        let chain = try #require(minted ?? held)
        let aad = hexBytes(try #require(step.aad))
        let (id, sentAt) = (try #require(step.frameId), try #require(step.sentAt))
        #expect(
            aad == MessageCrypto.header(id: id, senderId: actor.nodeId.string, sentAt: sentAt, thread: transcript.groupId),
            "\(label): the AAD")
        let sealing = try actor.engine.seal(chain, plaintext: hexBytes(try #require(step.plaintext)), aad: aad)
        let result = try #require(sealing)
        actor.sendChains[result.chain.epoch] = result.chain

        let used = try #require(step.drawsUsed)
        #expect(Array(drawn..<actor.draws.count) == used, "\(label): the draws it took")
        let seedDraws = used.compactMap { index in transcript.draws[actor.name]?[index] }.filter { $0.kind == "groupSeed" }
        #expect(minted.map { hexString($0.seed) } == seedDraws.first?.groupSeed, "\(label): a mint, from the seed it drew")
        let header = try #require(step.groupHeader)
        #expect(result.header == GroupRatchetHeader(se: header.se, n: header.n), "\(label): the header")
        #expect(hexString(result.nonce) == step.nonce, "\(label): the IV")
        #expect(hexString(result.ct) == step.ct, "\(label): the ciphertext")
        let envelope = EncEnvelope(
            version: EncEnvelope.Version.ratchet, nonce: result.nonce, ct: result.ct, keys: [], groupRatchet: result.header)
        #expect(hexString(envelope.encoded) == step.encEnvelope, "\(label): the envelope")
        sealed[step.step] = Sealed(header: result.header, nonce: result.nonce, ct: result.ct)
    }

    /// A group frame opened as `GroupRatchetSessions.open` opens one, against the actor's rows for its sender and epoch.
    private func groupOpen(_ step: RatchetVectors.GroupStep, actor: Party, label: String) throws {
        let peer = try #require(step.peer)
        let sender = try #require(parties[peer])
        let stated = try #require(step.groupHeader)
        let header = GroupRatchetHeader(se: stated.se, n: stated.n)
        let (nonce, ct) = (hexBytes(try #require(step.nonce)), hexBytes(try #require(step.ct)))
        let opens = try #require(step.opens)
        if let made = sealed[opens] {
            #expect(made.header == header && made.nonce == nonce && made.ct == ct, "\(label): the frame as sealed")
        }
        let context = GroupRatchetEngine.OpenContext(
            chains: actor.recvChains.filter { $0.key.sender == sender.nodeId && $0.key.epoch == header.se }.map(\.value),
            skippedKeys: actor.skippedKeys.filter { id, _ in id.sender == sender.nodeId && id.epoch == header.se && id.index == header.n }
                .map(\.value)
        )
        let outcome = actor.engine.open(context, header: header, nonce: nonce, ct: ct, aad: hexBytes(try #require(step.aad)), now: step.now)
        switch outcome {
        case .opened(let opened):
            #expect(step.expect == "OPENED", "\(label): the outcome")
            #expect(hexString(opened.plaintext) == step.plaintext, "\(label): the plaintext")
            apply(opened.delta, from: sender.nodeId, header: header, to: actor)
        case .failed(let failure):
            #expect(Self.name(of: failure) == step.expect, "\(label): the outcome")
            #expect(step.plaintext == nil)
        }
    }

    /// The seeds a group-key DM carried, adopted at the engine against the newest mint held for each epoch, with the
    /// verdicts the file states. The adoption floor and the roster gate are the session layer's and the pipeline's.
    private func adoptSeeds(_ step: RatchetVectors.GroupStep, actor: Party, label: String) throws {
        let dm = try #require(step.dm)
        guard dm.expect == "OPENED", let plaintext = dm.plaintext, let content = try? MessageContent(decoding: hexBytes(plaintext)),
            content.ctl == MessageContent.Control.groupKey, let keys = content.gk?.keys, !keys.isEmpty
        else {
            #expect(step.applies?.seeds?.isEmpty ?? true, "\(label): no seed to adopt")
            return
        }
        let sender = try #require(parties[dm.peer])
        var verdicts: [String] = []
        for seed in keys {
            let newest = actor.recvChains.filter { $0.key.sender == sender.nodeId && $0.key.epoch == seed.epoch }.max { lhs, rhs in
                lhs.key.mintedAt < rhs.key.mintedAt
            }
            let outcome = actor.engine.adoptSeed(
                existing: newest?.value,
                groupId: transcript.groupId,
                senderId: sender.nodeId,
                epoch: seed.epoch,
                seed: seed.seed,
                mintedAt: seed.mintedAt,
                now: step.now
            )
            switch outcome {
            case .adopt(let chain):
                actor.recvChains[Party.ChainId(sender: sender.nodeId, epoch: seed.epoch, mintedAt: seed.mintedAt)] = chain
                verdicts.append("ADOPT")
            case .alreadyKnown:
                verdicts.append("ALREADY_KNOWN")
            case .stale:
                verdicts.append("STALE")
            }
        }
        #expect(verdicts == step.applies?.seeds?.map(\.outcome), "\(label): the verdicts")
    }

    private func apply(_ delta: GroupRatchetEngine.OpenDelta, from sender: NodeId, header: GroupRatchetHeader, to actor: Party) {
        if let chain = delta.recvChain {
            actor.recvChains[Party.ChainId(sender: sender, epoch: chain.epoch, mintedAt: chain.mintedAt)] = chain
        }
        for key in delta.skippedInserts {
            let id = Party.KeyId(sender: sender, epoch: key.epoch, mintedAt: key.mintedAt, index: key.index)
            actor.skippedKeys[id] = actor.skippedKeys[id] ?? key
        }
        if let mintedAt = delta.consumedSkippedMintedAt {
            actor.skippedKeys[Party.KeyId(sender: sender, epoch: header.se, mintedAt: mintedAt, index: header.n)] = nil
        }
    }

    /// A party's rows as the file states them: send chains newest first, receive chains and skipped keys by sender, then
    /// epoch, mint and index, secrets as SHA-256.
    private func digest(of actor: Party) -> [[String]] {
        let send = actor.sendChains.values.sorted { $0.epoch > $1.epoch }.map { chain in
            "\(chain.epoch)/\(chain.mintedAt)/\(chain.count)/\(chain.isRetired)/\(sha(chain.seed))/\(sha(chain.chainKey))"
        }
        let recv = actor.recvChains.sorted { lhs, rhs in
            (lhs.key.sender, lhs.key.epoch, lhs.key.mintedAt) < (rhs.key.sender, rhs.key.epoch, rhs.key.mintedAt)
        }
        .map { id, chain in
            "\(names[id.sender] ?? "?")/\(id.epoch)/\(id.mintedAt)/\(chain.next)/\(sha256Hex(chain.chainKey))/\(chain.lastUsedAt)"
        }
        let keys = actor.skippedKeys.keys.sorted { lhs, rhs in
            (lhs.sender, lhs.epoch, lhs.mintedAt, lhs.index) < (rhs.sender, rhs.epoch, rhs.mintedAt, rhs.index)
        }
        .map { "\(names[$0.sender] ?? "?")/\($0.epoch)/\($0.mintedAt)/\($0.index)" }
        return [send, recv, keys]
    }

    private func digest(of state: RatchetVectors.GroupState) -> [[String]] {
        [
            state.sendChains.map { chain in
                "\(chain.epoch)/\(chain.mintedAt)/\(chain.count)/\(chain.retired)/\(chain.seedSha256 ?? "-")/\(chain.chainKeySha256 ?? "-")"
            },
            state.recvChains.map { "\($0.sender)/\($0.epoch)/\($0.mintedAt)/\($0.next)/\($0.chainKeySha256)/\($0.lastUsedAt)" },
            state.skippedKeys.map { "\($0.sender)/\($0.epoch)/\($0.mintedAt)/\($0.idx)" },
        ]
    }

    /// SHA-256 of a key, or `-` for the empty key a retired chain holds.
    private func sha(_ bytes: [UInt8]) -> String {
        bytes.isEmpty ? "-" : sha256Hex(bytes)
    }

    /// `GroupRatchetEngine.OpenOutcome.Failed`'s Kotlin name.
    static func name(of failure: GroupRatchetEngine.OpenOutcome.Failed) -> String {
        switch failure {
        case .noKey:
            "NO_KEY"
        case .duplicate:
            "DUPLICATE"
        case .badHeader:
            "BAD_HEADER"
        case .aeadFail:
            "AEAD_FAIL"
        }
    }
}
