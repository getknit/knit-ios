import KnitCrypto
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A9's transcripts (`ratchet-v1.json`) replayed through a whole engine's inbound path, as knit-next's
/// `InboundPipelineTest` replays them through its pipeline: the receiver is a ``MeshEngine`` with the switch on, holding the
/// prekey the file gives it and pinning its peer's, on a clock moved to each step's `now`.
enum RatchetVectorReplay {
    static let file = RatchetVectors.file

    /// The fixed identity `name` names in the file.
    static func identity(_ name: String) throws -> IdentityKeys {
        let entry = try #require(file.identities[name])
        return try #require(IdentityKeys(signingSeed: try bytes(entry.signingSeed), agreementScalar: try bytes(entry.agreementScalar)))
    }

    /// The prekey `name` names: its pair from the listed private key, and the info its owner publishes, signature and all.
    static func prekey(_ name: String) throws -> (pair: RatchetCrypto.KeyPair, info: PrekeyInfo) {
        let vector = try #require(file.profiles.prekeys.first { $0.name == name })
        let pair = try RatchetCrypto.KeyPair(privateKey: try bytes(vector.priv))
        #expect(Hex.encode(pair.publicKey) == vector.pub)
        return (pair, PrekeyInfo(id: vector.id, pub: pair.publicKey, sig: try bytes(vector.sig)))
    }

    static func bytes(_ hex: String) throws -> [UInt8] {
        try #require(Hex.decode(hex), "\(hex.prefix(16)) is hex")
    }

    /// `name`'s engine in `transcript`: the switch on, its clock at `wall`, the prekey the file says it holds minted at
    /// start from the listed private key, and `peer` pinned with the prekey `name` pins for it and the file's capabilities.
    /// Its ratchet draws `draws` when given, so what it seals is the file's byte for byte, and the system's otherwise.
    static func receiver(
        _ transcript: RatchetVectors.Transcript, as name: String, peer: String, wall: Int64, draws: VectorDraws? = nil
    ) throws -> EngineFixture {
        let party = try #require(transcript.parties[name])
        let keys = try identity(party.identity)
        let held = try prekey(try #require(party.holdsPrekeys.first))
        let pair = held.pair
        let ring = try PrekeyRing.load(for: keys, from: KeptSecretStore(keys.storedForm)) { pair }
        // A seed of the party's own, so two engines in one replay never draw the same frame ids.
        let seed = UInt64(truncatingIfNeeded: keys.nodeId.string.utf8.reduce(7) { $0 &* 31 &+ Int($1) })
        let fixture = EngineFixture(
            TestPeer(keys: keys),
            configuration: MeshConfiguration(ratchet: true),
            prekeys: ring,
            wall: wall,
            seed: seed,
            ratchetEngine: draws?.engine ?? RatchetEngine()
        )
        #expect(fixture.engine.prekeyRing?.newest?.id == held.info.id, "the start minted the file's prekey")
        let other = try #require(transcript.parties[peer])
        let otherKeys = try identity(other.identity)
        let pinned = try prekey(try #require(party.pins[peer]))
        fixture.stores.peers.upsert(
            PeerRecord(
                nodeId: otherKeys.nodeId,
                name: peer,
                status: "",
                publicKey: otherKeys.bundle.encoded,
                capabilities: file.profiles.capabilities,
                updatedAt: 1,
                prekey: pinned.info,
                prekeyProfileAt: 1
            )
        )
        return fixture
    }

    /// The frame an open step lists, as it arrives off a link: its wire and the envelope it carries.
    static func frame(of step: RatchetVectors.TranscriptStep) throws -> InboundFrame {
        let wire = try WireEnvelope(decoding: try bytes(try #require(step.wire)))
        let envelope = try RelayEnvelope(decoding: wire.signed)
        #expect(envelope.id == step.frameId && envelope.sentAt == step.sentAt)
        #expect(wire.sig.isEmpty == (step.signed == false))
        return InboundFrame(wire: wire, envelope: envelope, from: try #require(NodeId(envelope.senderId)))
    }

    /// Moves `fixture`'s clock on to `now`, never back.
    static func move(_ fixture: EngineFixture, to now: Int64) {
        let current = fixture.clock.wallMilliseconds()
        #expect(now >= current, "the file's clock never runs back for one receiver")
        fixture.clock.advance(max(0, now - current))
    }

    /// Our drop for the pipeline's `DropReason`. Kotlin's `DECRYPT_FAILED` is this port's `cannotOpen`.
    static func dropReason(_ name: String) -> DropReason? {
        let names: [String: DropReason] = [
            "RATCHET_NO_SESSION": .ratchetNoSession, "RATCHET_EPOCH_GONE": .ratchetEpochGone, "RATCHET_DUPLICATE": .ratchetDuplicate,
            "RATCHET_BAD_HEADER": .ratchetBadHeader, "RATCHET_AEAD_FAIL": .ratchetAeadFail, "UNSIGNED_REFUSED": .unsigned,
            "DECRYPT_FAILED": .cannotOpen,
        ]
        return names[name]
    }

    /// The floors the file says the actor held as a step began, against the ones `fixture`'s facade holds for `peer`.
    static func expectFloors(_ step: RatchetVectors.TranscriptStep, in fixture: EngineFixture, for peer: NodeId, _ label: String) {
        guard let stated = step.floorsBefore else {
            return
        }
        let held = fixture.engine.ratchet.floors(for: peer)
        let read = RatchetVectors.TranscriptFloors(
            lastReplacementAt: held.lastReplacementAt,
            confirmedAt: held.confirmedAt,
            lastResetSentAtInMemory: held.lastResetSentAt,
            undecryptableIds: held.undecryptableIds
        )
        #expect(read == stated, "\(label): the floors before it")
    }

    /// What an open the file says succeeded applied: the row, the receipts, the reaction and the profile, and whether it
    /// was acknowledged. Since P5d the acknowledgement to a reader of sealed receipts is sealed, `acksBack`'s "a sealed
    /// `CTL_RECEIPT`": one DM-form chat to the sender that is no message of ours, and nothing in the clear. What it says
    /// is the caller's to check where the file lists it (Carol's ticks).
    static func expectApplies(_ step: RatchetVectors.TranscriptStep, in fixture: EngineFixture, names: [String: NodeId], _ label: String) {
        guard let applies = step.applies else {
            return
        }
        if let message = applies.message {
            #expect(fixture.stores.messages.message(message.id)?.body == message.body, "\(label): the row")
        }
        for receipt in applies.receipts ?? [] {
            #expect(fixture.stores.messages.message(receipt.id)?.delivered == true, "\(label): the receipt for \(receipt.id)")
        }
        if let reaction = applies.reaction, let reactor = names[reaction.reactor] {
            let held = fixture.stores.messages.reaction(on: reaction.messageId, by: reactor)
            #expect(held?.emoji == reaction.emoji && held?.updatedAt == reaction.at, "\(label): the reaction")
        }
        if let profile = applies.profile, let of = names[profile.of] {
            let held = fixture.stores.peers.peer(of)
            #expect(held?.name == profile.name && held?.status == profile.status, "\(label): the profile")
            #expect(held?.updatedAt == profile.version && held?.openToChat == profile.openToChat, "\(label): its watermark")
            #expect(held?.advertisedAvatarHash?.string == profile.avatarHash, "\(label): its photo")
        }
        #expect(fixture.acknowledged.isEmpty, "\(label): nothing acknowledged in the clear")
        let backs = names[step.peer].map { ackBacks(in: fixture, to: $0) } ?? []
        #expect(backs.count == (applies.acksBack ? 1 : 0), "\(label): acknowledged back \(backs.count) times")
    }

    /// The sealed receipts `fixture` wrote to `peer` since its transport was cleared: DM-form chats of its own that are no
    /// message of its own, which a re-seal of a DM would be.
    static func ackBacks(in fixture: EngineFixture, to peer: NodeId) -> [Written] {
        let me = ExactKey(fixture.me.nodeId.string)
        return EngineFixture.once(fixture.transport.written(.chat)).filter { written in
            ExactKey(written.envelope.senderId) == me && written.envelope.recipientId.map(ExactKey.init) == ExactKey(peer.string)
                && fixture.stores.messages.message(written.envelope.id) == nil
        }
    }

    /// The actor's ratchet state for `peer` as the file states it and as `fixture`'s store holds it, digested alike: all
    /// of it, or with `receiveSide` only what the actor's opens move, for an actor whose sealed receipts, which the file
    /// lists nowhere, moved its send chain (`dm`'s `ctlPlane`, "Bob's own receipts for her plain DMs ... are not listed").
    static func expectState(
        _ step: RatchetVectors.TranscriptStep, in fixture: EngineFixture, for peer: NodeId, _ label: String, receiveSide: Bool = false
    ) throws {
        let stated = StoredStateDigest(try #require(step.state, "\(label) lists a state"))
        let held = StoredStateDigest(fixture.stores.ratchet.records(of: peer))
        if receiveSide {
            #expect(held.receiveSide == stated.receiveSide, "\(label): the state its opens leave")
        } else {
            #expect(held == stated, "\(label): the state")
        }
    }
}

/// A generator whose first draws are the 16 bytes of `id`, a canonical frame id, so the next ``FrameId`` the engine mints is
/// that id (``FrameId/generate(using:)`` reads two words, low byte first), and the rest come from `then`: how a replay
/// hands an engine the frame id Kotlin's pipeline minted for a seal the file lists.
struct ScriptedFrameIds: RandomNumberGenerator {
    private var words: [UInt64]
    private var then: SeededGenerator

    init(_ id: String, then: SeededGenerator) throws {
        let bytes = try #require(FrameId.bytes(of: id), "\(id) is a canonical frame id")
        words = [bytes[0..<8], bytes[8..<16]].map { half in
            half.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) }
        }
        self.then = then
    }

    mutating func next() -> UInt64 {
        words.isEmpty ? then.next() : words.removeFirst()
    }
}

/// One party's injected values, popped in the order its seals take them, and checked: a draw of the wrong kind or past
/// the plan is a failed expectation (`DrawSource`, knit-next's `RatchetTranscript.kt:66-106` on the A9 branch).
final class VectorDraws: Sendable {
    private let owner: String
    private let plan: [RatchetVectors.TranscriptDraw]
    private let taken = Lock(0)

    init(owner: String, plan: [RatchetVectors.TranscriptDraw]) {
        self.owner = owner
        self.plan = plan
    }

    /// Whether every draw was taken.
    var spent: Bool { taken.withLock { $0 } == plan.count }

    /// An engine on this plan.
    var engine: RatchetEngine {
        RatchetEngine(keyPair: { self.keyPair() }, iv: { self.iv() })
    }

    private func keyPair() -> RatchetCrypto.KeyPair {
        guard let draw = next("keyPair"), let priv = draw.priv, let bytes = Hex.decode(priv),
            let pair = try? RatchetCrypto.KeyPair(privateKey: bytes)
        else {
            return RatchetCrypto.generateKeyPair()
        }
        return pair
    }

    private func iv() -> [UInt8] {
        guard let draw = next("iv"), let iv = draw.iv, let bytes = Hex.decode(iv) else {
            return RatchetCrypto.randomNonce()
        }
        return bytes
    }

    private func next(_ kind: String) -> RatchetVectors.TranscriptDraw? {
        let index = taken.withLock { taken in
            defer { taken += 1 }
            return taken
        }
        guard index < plan.count, plan[index].kind == kind else {
            Issue.record("\(owner) drew a \(kind) its plan does not list at \(index)")
            return nil
        }
        return plan[index]
    }
}

/// A party's ratchet state for one peer, digested as the file states it (`TranscriptJson.state`, knit-next's
/// `TranscriptJson.kt:40-130` on the A9 branch): secrets as SHA-256 hex, root tags as 16 hex digits, chains by epoch then
/// tag, skipped keys as contiguous runs, and our epochs the most recently minted first. Kotlin's `sendEpochExportSha256`
/// is not compared: this port keeps no export half.
struct StoredStateDigest: Equatable {
    var session: [String]?
    var chains: [String]
    var skippedKeyCount: Int
    var skippedRuns: [String]
    var localEpochs: [String]

    init(_ records: RatchetPeerRecords) {
        session = records.session.map { held in
            [
                Self.sha(held.root), "\(held.confirmed)", "\(held.weAreInitiator)", "\(held.establishedAt)", Self.hex(held.initEphPub),
                "\(held.initPkid)", Self.hex(held.peerInitEphPub), Self.hex(held.peerBasePub), "\(held.peerBaseEpoch)", "\(held.sendEpoch)",
                Self.hex(held.sendEpochPub), held.sendChainKey.map(Self.sha) ?? "-", "\(held.sendCount)", "\(held.sendEpochStartedAt)",
                "\(held.sendEpochBaseEpoch)", "\(held.highestPeAcked)", held.prevRoot.map(Self.sha) ?? "-",
                "\(held.prevRootWeAreInitiator)",
                "\(held.prevRootExpiresAt)", "\(held.lastResetSentAt)",
            ]
        }
        chains = records.recvEpochs
            .sorted { ($0.epoch, $0.rootTag) < ($1.epoch, $1.rootTag) }
            .map { "\($0.epoch)/\(Self.tag($0.rootTag))/\($0.next)/\(Self.sha($0.chainKey))/\($0.lastUsedAt)" }
        let keys = records.skippedKeys.sorted { ($0.epoch, $0.rootTag, $0.index) < ($1.epoch, $1.rootTag, $1.index) }
        skippedKeyCount = keys.count
        var runs: [Run] = []
        for key in keys {
            if let last = runs.last, last.epoch == key.epoch, last.tag == key.rootTag, last.last + 1 == key.index {
                runs[runs.count - 1].last = key.index
            } else {
                runs.append(Run(epoch: key.epoch, tag: key.rootTag, first: key.index, last: key.index))
            }
        }
        skippedRuns = runs.map { "\($0.epoch)/\(Self.tag($0.tag))/\($0.first)-\($0.last)" }
        localEpochs = records.localEpochs
            .sorted { ($0.createdAt, $0.epoch) > ($1.createdAt, $1.epoch) }
            .map { "\($0.epoch)/\($0.createdAt)/\(Hex.encode($0.publicKey))" }
    }

    init(_ state: RatchetVectors.TranscriptState) {
        session = state.session.map { stated in
            [
                stated.rootSha256, "\(stated.confirmed)", "\(stated.weAreInitiator)", "\(stated.establishedAt)", stated.initEphPub ?? "-",
                "\(stated.initPkid)", stated.peerInitEphPub ?? "-", stated.peerBasePub ?? "-", "\(stated.peerBaseEpoch)",
                "\(stated.sendEpoch)",
                stated.sendEpochPub ?? "-", stated.sendChainKeySha256 ?? "-", "\(stated.sendCount)", "\(stated.sendEpochStartedAt)",
                "\(stated.sendEpochBaseEpoch)", "\(stated.highestPeAcked)", stated.prevRootSha256 ?? "-",
                "\(stated.prevRootWeAreInitiator)",
                "\(stated.prevRootExpiresAt)", "\(stated.lastResetSentAt)",
            ]
        }
        chains = state.recvEpochs.map { "\($0.epoch)/\($0.rootTag)/\($0.next)/\($0.chainKeySha256)/\($0.lastUsedAt)" }
        skippedKeyCount = state.skippedKeyCount
        skippedRuns = state.skippedKeys.map { "\($0.epoch)/\($0.rootTag)/\($0.fromIdx)-\($0.toIdx)" }
        localEpochs = state.localEpochs.map { "\($0.epoch)/\($0.createdAt)/\($0.pub)" }
    }

    /// The digest less what a seal of the actor's own moves, the send chain's six fields and the actor's own epochs: what
    /// its opens leave, for a replay whose actor sealed what the file does not list.
    var receiveSide: Self {
        var digest = self
        if var held = digest.session {
            for index in 9...14 {
                held[index] = "-"
            }
            digest.session = held
        }
        digest.localEpochs = []
        return digest
    }

    /// Skipped keys of one epoch and root, at contiguous indices.
    private struct Run {
        let epoch: Int
        let tag: Int64
        let first: Int
        var last: Int
    }

    private static func sha(_ bytes: [UInt8]) -> String {
        BlobHash(of: bytes).string
    }

    private static func hex(_ bytes: [UInt8]?) -> String {
        bytes.map(Hex.encode) ?? "-"
    }

    /// A root tag as the file writes it, Kotlin's `"%016x".format(tag)`.
    private static func tag(_ tag: Int64) -> String {
        let digits = String(UInt64(bitPattern: tag), radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }
}
