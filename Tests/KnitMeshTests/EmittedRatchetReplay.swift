import KnitCrypto
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// How a reader opens Carol's ratchet frames in `ios-emitted-v1.json` (phase P7b), and the entries the file holds for them.
/// Bob and Alice are this port's Android stand-ins: each a fresh ``RatchetSessions`` holding A9's prekey and a
/// ``GroupRatchetSessions`` beside it (``GroupFormReader``), as knit-next's `IosEmittedVectorTest` will hold Android's. A
/// reader opens each DM-form frame at its `sentAt` and commits it, adopts the seeds a `CTL_GROUP_KEY` carries, and opens
/// the group form: the session layers alone, with no tick, no init answer and no key ack sent back.
enum EmittedRatchetReplay {
    typealias Names = EmittedRatchetFrames.Name

    /// Each reader's steps, as the file lists them.
    static let steps: [String: [EmittedRatchet.Step]] = [
        "bob": [
            .init(op: "open", frame: Names.dm), .init(op: "open", frame: Names.inlineAcks), .init(op: "seal", frame: Names.bobReply),
            .init(op: "open", frame: Names.receipt), .init(op: "open", frame: Names.sealedProfile),
            .init(op: "open", frame: Names.reaction),
            .init(op: "open", frame: Names.retraction), .init(op: "open", frame: Names.seedToBob),
            .init(op: "openGroup", frame: Names.groupChat), .init(op: "openGroup", frame: Names.groupReaction),
        ],
        "alice": [
            .init(op: "open", frame: Names.seedToAlice), .init(op: "openGroup", frame: Names.groupChat),
            .init(op: "openGroup", frame: Names.groupReaction),
        ],
    ]

    static let about =
        "Carol's ratchet frames (A10): what the iOS port's mesh engine sends with the ratchet on, from fixed draws "
        + "(carolDraws; keyPair is an X25519 private key fixtureBytes(32, seed), iv fixtureBytes(12, seed), groupSeed "
        + "fixtureBytes(32, seed), groupIv fixtureBytes(12, seed)). "
        + "To check them, each reader in replay is a fresh RatchetSessions holding its prekey from "
        + "prekeys, beside a fresh GroupRatchetSessions, and takes its steps in order at each frame's sentAt: open is a "
        + "DM-form frame opened and committed through the session layer (peek, then commit), then for a CTL_GROUP_KEY its "
        + "seeds adopted from the sender; seal is the reader's own frame from seals, sealed at its sentAt on its draws, "
        + "whose signed bytes must come out as listed; openGroup is a group-form frame opened through GroupRatchetSessions. "
        + "Nothing is sent back: no tick, no init answer, no key ack. Each frame's sealed says what it must open to: "
        + "plaintext exactly, as plaintextSchema lays it out, with the fields in content."

    /// The readers' names for the parties' node ids.
    static func names(carol: IdentityKeys, alice: IdentityKeys, bob: IdentityKeys) -> [String: String] {
        [carol.nodeId.string: "carol", alice.nodeId.string: "alice", bob.nodeId.string: "bob"]
    }

    /// Bob: A9's bob identity and bobSpk1, his seals on his one draw.
    static func bob(_ keys: IdentityKeys) throws -> GroupFormReader {
        let pair = try RatchetCrypto.KeyPair(privateKey: fixtureBytes(32, seed: EmittedRatchetFrames.bobReplySeed))
        let drawn = Lock(false)
        let engine = RatchetEngine(
            keyPair: {
                if drawn.withLock({ $0 }) {
                    Issue.record("Bob drew a second key")
                }
                drawn.withLock { $0 = true }
                return pair
            },
            iv: {
                Issue.record("Bob's v3 reply draws no IV")
                return RatchetCrypto.randomNonce()
            })
        return GroupFormReader(AndroidPeer(TestPeer(keys: keys), prekey: try prekey("bobSpk1", of: keys), engine: engine))
    }

    /// Alice: A9's alice identity and aliceSpk1.
    static func alice(_ keys: IdentityKeys) throws -> GroupFormReader {
        GroupFormReader(AndroidPeer(TestPeer(keys: keys), prekey: try prekey("aliceSpk1", of: keys)))
    }

    /// A9's prekey `name`, as `owner` holds it: its listed pair, signed by this port.
    static func prekey(_ name: String, of owner: IdentityKeys) throws -> SignedPrekey {
        let vector = try RatchetVectorReplay.prekey(name)
        return try SignedPrekey.mint(id: vector.info.id, signedBy: owner, createdAt: 0) { vector.pair }
    }

    /// The prekeys section: A9's three, as its `profiles.prekeys` lists them.
    static func prekeys() throws -> [String: EmittedRatchet.Prekey] {
        var held: [String: EmittedRatchet.Prekey] = [:]
        for name in ["aliceSpk1", "bobSpk1", "carolSpk1"] {
            let vector = try #require(RatchetVectors.file.profiles.prekeys.first { $0.name == name })
            #expect(Hex.encode(fixtureBytes(32, seed: vector.seed)) == vector.priv, "\(name)'s private key is its seed's")
            held[name] = EmittedRatchet.Prekey(owner: vector.owner, id: vector.id, seed: vector.seed, priv: vector.priv, pub: vector.pub)
        }
        return held
    }

    /// What each frame opened to, and the frames the readers sealed, after every reader's steps over `frames`.
    struct Opened {
        var plaintexts: [String: [UInt8]] = [:]
        var sealed: [String: TestFrame] = [:]
    }

    /// Takes every reader's `steps` over `frames`, Carol's frames by name: what each opened to, or `nil` where a step
    /// failed, with a failed expectation.
    static func replay(
        _ frames: [String: Written], steps: [String: [EmittedRatchet.Step]] = steps, carol: IdentityKeys, alice: IdentityKeys,
        bob: IdentityKeys, wall: Int64 = EmittedRatchetFrames.start
    ) throws -> Opened {
        var opened = Opened()
        let readers = ["bob": try Self.bob(bob), "alice": try Self.alice(alice)]
        let sender = TestPeer(keys: carol)
        for (name, reader) in readers.sorted(by: { $0.key < $1.key }) {
            for step in steps[name] ?? [] {
                switch step.op {
                case "open":
                    let frame = try #require(frames[step.frame], "\(step.frame) is in the file")
                    let bytes = try #require(
                        plaintext(try reader.android.open(frame, from: sender, now: frame.envelope.sentAt)), "\(name) opens \(step.frame)")
                    try adoptSeeds(in: bytes, of: frame, by: reader, from: sender)
                    opened.plaintexts[step.frame] = bytes
                case "openGroup":
                    let frame = try #require(frames[step.frame], "\(step.frame) is in the file")
                    let bytes = try openGroup(frame, by: reader, from: sender)
                    #expect(opened.plaintexts[step.frame].map { $0 == bytes } ?? true, "every member opens \(step.frame) alike")
                    opened.plaintexts[step.frame] = bytes
                case "seal":
                    let at = wall + EmittedRatchetFrames.replyOffset
                    opened.sealed[step.frame] = try EmittedRatchetFrames.bobReply(by: reader.android, to: carol, at: at)
                default:
                    Issue.record("no step \(step.op)")
                }
            }
        }
        return opened
    }

    /// The seeds a `CTL_GROUP_KEY` in `bytes` carries, adopted from `sender` as Android adopts them after the DM's commit.
    private static func adoptSeeds(in bytes: [UInt8], of frame: Written, by reader: GroupFormReader, from sender: TestPeer) throws {
        let enc = try EngineFixture.sealed(frame)
        guard enc.version == EncEnvelope.Version.ratchet, let content = try? MessageContent(decoding: bytes),
            content.ctl == MessageContent.Control.groupKey, let seeds = content.gk
        else {
            return
        }
        let adopted = reader.sessions.adoptSeeds(seeds.keys, in: seeds.groupId, from: sender.nodeId, now: frame.envelope.sentAt)
        guard case .settled = adopted else {
            Issue.record("the reader's own unit cannot fail")
            return
        }
    }

    /// A group-form frame's plaintext, opened and committed by `reader`.
    private static func openGroup(_ frame: Written, by reader: GroupFormReader, from sender: TestPeer) throws -> [UInt8] {
        let envelope = frame.envelope
        let group = try #require(envelope.group?.id)
        let enc = try EngineFixture.sealed(frame)
        let aad = MessageCrypto.header(id: envelope.id, senderId: envelope.senderId, sentAt: envelope.sentAt, thread: group)
        let opening = try #require(GroupRatchetSessions.Frame(envelope: enc, aad: aad))
        let opened = reader.sessions.open(opening, in: group, from: sender.nodeId, now: envelope.sentAt) { _ in () }
        guard case .settled(.opened(let bytes, _)) = opened else {
            Issue.record("\(reader.android.peer.nodeId) could not open \(envelope.id): \(opened)")
            throw AndroidPeer.Refused()
        }
        return bytes
    }

    /// A committed frame as it arrives off a link.
    static func written(_ hex: String) throws -> Written {
        let wire = try WireEnvelope(decoding: try RatchetVectorReplay.bytes(hex))
        return Written(wire: wire, envelope: try RelayEnvelope(decoding: wire.signed), to: nil)
    }

    /// The entry for Carol's frame `frame`, which its reader opened to `bytes`.
    static func entry(_ frame: Written, opened bytes: [UInt8], names: [String: String]) throws -> VectorFrame {
        let enc = try EngineFixture.sealed(frame)
        let compact = enc.version == EncEnvelope.Version.compactRatchet
        let content = try #require(compact ? MessageContentV2.decode(bytes) : try MessageContent(decoding: bytes))
        let header = enc.ratchet
        let recipient = frame.envelope.recipientId.flatMap { names[$0] }
        let initPrekey = header?.initial.map { "\(recipient ?? "?")Spk\($0.pkid)" }
        let sealed = VectorSealed(
            version: enc.version,
            form: enc.groupRatchet == nil ? "dm" : "group",
            se: header?.se ?? enc.groupRatchet?.se ?? 0,
            n: header?.n ?? enc.groupRatchet?.n ?? 0,
            pe: header?.pe,
            initPrekey: initPrekey,
            plaintextSchema: compact ? "MessageContentV2" : "MessageContent",
            plaintext: Hex.encode(bytes),
            content: Self.content(content, names: names)
        )
        let group = frame.envelope.group
        return VectorFrame(
            sender: "carol",
            recipient: recipient,
            groupId: group?.id,
            members: group?.members.compactMap { names[$0] },
            body: content.ctl == nil ? content.body : nil,
            sealed: sealed,
            wire: Hex.encode(frame.wire.encoded)
        )
    }

    /// The fields of `content` a reader checks, the parties by name.
    static func content(_ content: MessageContent, names: [String: String]) -> VectorContent {
        VectorContent(
            body: content.body,
            ctl: content.ctl,
            ack: content.ack,
            acks: content.acks,
            rp: content.rp.map { VectorContent.Reaction(messageId: $0.messageId, emoji: $0.emoji) },
            pr: content.pr.map { VectorContent.Profile(name: $0.name, status: $0.status, version: $0.version, openToChat: $0.openToChat) },
            gk: content.gk.map { payload in
                VectorContent.GroupKey(
                    groupId: payload.groupId,
                    keys: payload.keys.map { VectorContent.Seed(epoch: $0.epoch, seed: Hex.encode($0.seed), mintedAt: $0.mintedAt) },
                    group: payload.group.map { info in
                        VectorContent.Roster(
                            id: info.id, members: info.members.map { names[$0] ?? $0 }, createdBy: names[info.createdBy] ?? info.createdBy)
                    }
                )
            }
        )
    }
}
