import KnitCrypto
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Carol's ratchet frames for `ios-emitted-v1.json` (ADR 2026-10.5sk9's P7b amendment, the iOS half of companion change
/// A10): what this port's mesh engine puts on the air for Bob and Alice with the switch on, made by Carol's own engine,
/// never by hand. Its keys, seeds and IVs come from fixed draws through the engines' injected sources, its frame ids from
/// a seeded generator and its clocks from a manual one, so every frame but its signature comes out the same on every run.
/// knit-next's `IosEmittedVectorTest` opens them as Bob and as Alice, through its session layers, in the order
/// ``EmittedRatchet/replay`` gives (``EmittedRatchetReplay``).
///
/// The run: Carol pins Alice and Bob from profiles carrying the ratchet's bits and A9's prekeys, and opens a session to
/// Bob with a v3 DM (the init). Bob posts in the room while away, so her next DM carries the post's tick inline. Bob reads
/// both and replies under the session, which confirms it, and Carol's sealed receipt for the reply carries a second
/// post's tick beside it. Carol edits her profile, which seals it to Bob, reacts to his reply and takes the reaction back.
/// Then she makes a group of Alice, Bob and herself, whose first message seeds both and goes in the group form, and reacts
/// to it in the group form.
enum EmittedRatchetFrames {
    /// The run's first clock, after every v1 frame in the file.
    static let start: Int64 = 1_756_200_010_000
    /// The seed of the engine's injected generator, which draws its frame ids. It draws no key.
    static let engineSeed: UInt64 = 0xA10
    /// The ratchet profile's stamp and version: after the v1 profile's, on both.
    static let profilePublishedAt: Int64 = 1_756_200_006_000
    static let profileVersion: Int64 = 2
    /// The flip's bits, a literal: everything through `CAP_CRYPTO_V3` (`0x15F`), never `Capabilities.local`.
    static let ratchetCapabilities: Int64 = 0x15F

    /// Carol's draws, by kind, in the order her engines take them (unused by every vector file before this one).
    static let keyPairSeeds = [184, 185, 186, 187, 188]
    static let ivSeeds = [189, 190]
    static let groupSeedSeeds = [191]
    static let groupIvSeeds = [192, 193]
    /// Bob's one draw: his first epoch's key, for his reply.
    static let bobReplySeed = 194
    /// When Bob replies, after the run's first clock.
    static let replyOffset: Int64 = 5000

    /// Bob's room posts and his reply, under fixed ids.
    static let bobPostIds = [fixtureFrameId(36), fixtureFrameId(37)]
    static let bobReplyId = fixtureFrameId(38)

    static let dmBody = "Hi Bob, sealed from Swift"
    static let inlineBody = "Your post rides along"
    static let postBodies = ["Bob in the room", "Bob again"]
    static let replyBody = "Hi Carol, from Bob"
    static let profileName = "Carol"
    static let profileStatus = "Sealed from Swift"
    static let reaction = "👍"
    static let groupBody = "Hi both, sealed from Swift"
    static let groupReaction = "🎉"

    /// The entries this run adds, by name.
    enum Name {
        static let profile = "carolRatchetProfile"
        static let dm = "carolRatchetDmToBob"
        static let inlineAcks = "carolInlineAcksToBob"
        static let receipt = "carolSealedReceiptToBob"
        static let sealedProfile = "carolSealedProfileToBob"
        static let reaction = "carolSealedReactionToBob"
        static let retraction = "carolSealedRetractionToBob"
        static let seedToAlice = "carolGroupSeedToAlice"
        static let seedToBob = "carolGroupSeedToBob"
        static let groupChat = "carolGroupFormChat"
        static let groupReaction = "carolGroupFormReaction"
        static let bobReply = "bobRatchetReplyToCarol"

        /// Every frame Carol's engine makes, in the order it makes them.
        static let engineFrames = [
            dm, inlineAcks, receipt, sealedProfile, reaction, retraction, seedToAlice, seedToBob, groupChat, groupReaction,
        ]
    }

    /// What one run of Carol's engine sent, by entry name, Bob's reply, and the draws her engines took.
    struct Made {
        var frames: [String: Written] = [:]
        var bobReply: TestFrame
        var draws: [EmittedRatchet.Draw]
        var groupMessageId: String
    }

    /// Runs Carol's engine through the scenario, its clock starting at `wall`: ``start`` for the file, and anything else
    /// for a stale copy.
    static func make(carol: IdentityKeys, alice: IdentityKeys, bob: IdentityKeys, wall: Int64 = start) throws -> Made {
        let draws = FixedDraws()
        let me = TestPeer(keys: carol)
        let fixture = try engine(of: carol, draws: draws, wall: wall)
        let bobSide = try EmittedRatchetReplay.bob(bob)
        let aliceSide = AndroidPeer(TestPeer(keys: alice), prekey: try EmittedRatchetReplay.prekey("aliceSpk1", of: alice))
        fixture.deliver(try aliceSide.profile(publishedAt: wall, name: "Alice"), from: aliceSide)
        fixture.deliver(try bobSide.android.profile(publishedAt: wall, name: "Bob"), from: bobSide.android)

        var frames: [String: Written] = [:]
        frames[Name.dm] = try one(sent(fixture, at: wall + 1000) { _ = fixture.engine.sendDirectMessage(dmBody, to: bob.nodeId) })
        try expectNothing(sent(fixture, at: wall + 2000) { try post(0, by: bobSide.android.peer, to: fixture, at: wall + 2000) })
        frames[Name.inlineAcks] = try one(
            sent(fixture, at: wall + 3000) { _ = fixture.engine.sendDirectMessage(inlineBody, to: bob.nodeId) })
        try expectNothing(sent(fixture, at: wall + 4000) { try post(1, by: bobSide.android.peer, to: fixture, at: wall + 4000) })

        // Bob reads both, as his reply needs a session, and replies under it.
        for name in [Name.dm, Name.inlineAcks] {
            let frame = try #require(frames[name])
            #expect(plaintext(try bobSide.android.open(frame, from: me, now: frame.envelope.sentAt)) != nil, "Bob reads \(name)")
        }
        let reply = try bobReply(by: bobSide.android, to: carol, at: wall + replyOffset)
        frames[Name.receipt] = try one(sent(fixture, at: wall + replyOffset) { fixture.deliver(reply, from: bobSide.android) })
        frames[Name.sealedProfile] = try one(
            sent(fixture, at: wall + 6000) { fixture.engine.updateProfile(name: profileName, status: profileStatus, openToChat: true) })
        frames[Name.reaction] = try one(sent(fixture, at: wall + 7000) { _ = fixture.engine.react(to: bobReplyId, with: reaction) })
        frames[Name.retraction] = try one(sent(fixture, at: wall + 8000) { _ = fixture.engine.react(to: bobReplyId, with: reaction) })

        var messageId = ""
        let group = try sent(fixture, at: wall + 9000) {
            let made = try #require(fixture.engine.createGroup(with: [alice.nodeId, bob.nodeId]))
            messageId = try #require(fixture.engine.sendGroupMessage(groupBody, to: made.id)).id
        }
        #expect(group.count == 3, "a seed to each member, then the frame")
        let seedToAlice: Written = try #require(group.first { $0.envelope.recipientId == alice.nodeId.string })
        let seedToBob: Written = try #require(group.first { $0.envelope.recipientId == bob.nodeId.string })
        let groupChat: Written = try #require(group.first { $0.envelope.group != nil })
        frames[Name.seedToAlice] = seedToAlice
        frames[Name.seedToBob] = seedToBob
        frames[Name.groupChat] = groupChat
        frames[Name.groupReaction] = try one(
            sent(fixture, at: wall + 10_000) { _ = fixture.engine.react(to: messageId, with: groupReaction) })
        #expect(draws.spent, "Carol's engines took every draw the file lists")
        return Made(frames: frames, bobReply: reply, draws: draws.taken, groupMessageId: messageId)
    }

    /// Carol's engine with the switch on, holding carolSpk1, on `draws`, its clock at `wall`.
    private static func engine(of carol: IdentityKeys, draws: FixedDraws, wall: Int64) throws -> EngineFixture {
        let carolPrekey = try prekeyPair("carolSpk1")
        let ring = try PrekeyRing.load(for: carol, from: KeptSecretStore(carol.storedForm)) { carolPrekey }
        let fixture = EngineFixture(
            TestPeer(keys: carol),
            configuration: MeshConfiguration(ratchet: true),
            prekeys: ring,
            wall: wall,
            seed: engineSeed,
            ratchetEngine: draws.engine,
            groupRatchetEngine: draws.groupEngine
        )
        let held = try #require(fixture.engine.prekeyRing?.newest, "the start minted carolSpk1")
        #expect(held.id == 1 && held.publicKey == carolPrekey.publicKey)
        return fixture
    }

    /// Bob's reply to Carol under the session he holds, sealed v3 on his one draw.
    static func bobReply(by bob: AndroidPeer, to carol: IdentityKeys, at sentAt: Int64) throws -> TestFrame {
        let held = try #require(PeerPrekey(verifying: try carolPrekeyInfo(of: carol), signedBy: carol.bundle))
        return try bob.dm(
            MessageContent(body: replyBody), to: TestPeer(keys: carol), prekey: held, id: bobReplyId, sentAt: sentAt, v3: true)
    }

    /// Carol's ratchet profile (`carolRatchetProfile`): the v1 profile's identity and device tag, the status her edit
    /// gives, the flip's bits and carolSpk1, whose signature is `prekeySig` when a committed copy carries one, else signed
    /// now (CryptoKit randomizes it).
    static func profileFrame(of carol: IdentityKeys, prekeySig: [UInt8]? = nil) throws -> RelayEnvelope {
        var prekey = try carolPrekeyInfo(of: carol)
        if let prekeySig {
            prekey = PrekeyInfo(id: prekey.id, pub: prekey.pub, sig: prekeySig)
        }
        let profile = ProfileContent(
            name: profileName,
            status: profileStatus,
            pubKey: carol.bundle.encoded,
            deviceTag: DeviceTag.derive("vector-device-carol"),
            protoVersion: WireProtocol.version,
            capabilities: ratchetCapabilities,
            prekey: prekey,
            version: profileVersion
        )
        return RelayEnvelope(
            type: .profile,
            id: "profile-\(carol.nodeId)-\(profilePublishedAt)",
            senderId: carol.nodeId.string,
            sentAt: profilePublishedAt,
            payload: profile.encoded
        )
    }

    /// Whether a committed ratchet profile is still what Carol would sign: its prekey's signature verifies under her
    /// bundle, and with that signature the frame is ``profileFrame(of:prekeySig:)`` exactly, at both layers.
    static func isCurrentProfile(_ hex: String, of carol: IdentityKeys) -> Bool {
        guard let bytes = Hex.decode(hex), let wire = try? WireEnvelope(decoding: bytes),
            let relay = try? RelayEnvelope(decoding: wire.signed), let profile = try? ProfileContent(decoding: relay.payload),
            let prekey = profile.prekey, PeerPrekey(verifying: prekey, signedBy: carol.bundle) != nil,
            let expected = try? profileFrame(of: carol, prekeySig: prekey.sig)
        else {
            return false
        }
        return profile.encoded == relay.payload && isCurrent(hex, signed: expected.encoded, by: carol.bundle)
    }

    /// Whether a committed frame is still current: both layers, and a chat's payload, re-encode to their own bytes, its
    /// signed bytes are `expected` exactly, and its signature verifies under `signer`. Never compares a signature, which
    /// CryptoKit randomizes.
    static func isCurrent(_ hex: String, signed expected: [UInt8], by signer: PublicKeyBundle) -> Bool {
        guard let bytes = Hex.decode(hex), let wire = try? WireEnvelope(decoding: bytes),
            let relay = try? RelayEnvelope(decoding: wire.signed)
        else {
            return false
        }
        let payloadReencodes = relay.type != .chat || (try? ChatContent(decoding: relay.payload))?.encoded == relay.payload
        return wire.encoded == bytes && relay.encoded == wire.signed && payloadReencodes && wire.signed == expected
            && signer.isValidSignature(wire.sig, for: wire.signed)
    }

    /// carolSpk1 as Carol publishes it, signed now.
    static func carolPrekeyInfo(of carol: IdentityKeys) throws -> PrekeyInfo {
        let pair = try prekeyPair("carolSpk1")
        return try SignedPrekey.mint(id: 1, signedBy: carol, createdAt: 0) { pair }.info
    }

    /// The pair of A9's prekey `name`, from its listed private key.
    static func prekeyPair(_ name: String) throws -> RatchetCrypto.KeyPair {
        try RatchetVectorReplay.prekey(name).pair
    }

    /// The DM-form and group-form chats `fixture` wrote at `time`, each once.
    private static func sent(_ fixture: EngineFixture, at time: Int64, _ action: () throws -> Void) throws -> [Written] {
        RatchetVectorReplay.move(fixture, to: time)
        fixture.transport.clear()
        try action()
        return EngineFixture.once(fixture.transport.written(.chat))
    }

    /// The one chat a step wrote.
    private static func one(_ written: [Written], sourceLocation: SourceLocation = #_sourceLocation) throws -> Written {
        #expect(written.count == 1, "one frame, not \(written.count)", sourceLocation: sourceLocation)
        return try #require(written.first, sourceLocation: sourceLocation)
    }

    private static func expectNothing(_ written: [Written], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(written.isEmpty, "a room post's tick waits for a ride", sourceLocation: sourceLocation)
    }

    /// Bob's room post `index`, which reaches Carol while he is away, so its tick waits for a ride toward him.
    private static func post(_ index: Int, by bob: TestPeer, to fixture: EngineFixture, at sentAt: Int64) throws {
        fixture.deliver(try bob.roomPost(postBodies[index], id: bobPostIds[index], sentAt: sentAt), from: bob)
    }
}

/// Fixed draws for Carol's two engines, popped in the order they take them and logged, with a failed expectation for a
/// draw past the plan: the DM engine's keys and v2 IVs, and the group engine's seeds and IVs (`fixtureBytes`).
final class FixedDraws: Sendable {
    private struct State {
        var next: [String: Int] = [:]
        var taken: [EmittedRatchet.Draw] = []
    }

    private let state = Lock(State())
    private let plan: [String: [Int]] = [
        "keyPair": EmittedRatchetFrames.keyPairSeeds, "iv": EmittedRatchetFrames.ivSeeds, "groupSeed": EmittedRatchetFrames.groupSeedSeeds,
        "groupIv": EmittedRatchetFrames.groupIvSeeds,
    ]

    /// The DM engine on this plan.
    var engine: RatchetEngine {
        RatchetEngine(keyPair: { self.keyPair() }, iv: { self.bytes("iv", 12) ?? RatchetCrypto.randomNonce() })
    }

    /// The group engine on this plan.
    var groupEngine: GroupRatchetEngine {
        GroupRatchetEngine(
            seed: { self.bytes("groupSeed", 32) ?? GroupRatchetCrypto.newSeed() },
            iv: { self.bytes("groupIv", 12) ?? RatchetCrypto.randomNonce() })
    }

    /// Every draw, in the order taken.
    var taken: [EmittedRatchet.Draw] { state.withLock { $0.taken } }

    /// Whether every planned draw was taken.
    var spent: Bool { state.withLock { $0.taken.count } == plan.values.map(\.count).reduce(0, +) }

    private func keyPair() -> RatchetCrypto.KeyPair {
        guard let bytes = bytes("keyPair", 32), let pair = try? RatchetCrypto.KeyPair(privateKey: bytes) else {
            return RatchetCrypto.generateKeyPair()
        }
        return pair
    }

    /// The next `kind` draw's bytes, or `nil` past the plan.
    private func bytes(_ kind: String, _ count: Int) -> [UInt8]? {
        let seed = state.withLock { state -> Int? in
            let index = state.next[kind, default: 0]
            guard let seeds = plan[kind], index < seeds.count else {
                return nil
            }
            state.next[kind] = index + 1
            state.taken.append(EmittedRatchet.Draw(kind: kind, seed: seeds[index]))
            return seeds[index]
        }
        guard let seed else {
            Issue.record("Carol's engines drew a \(kind) the plan does not list")
            return nil
        }
        return fixtureBytes(count, seed: seed)
    }
}
