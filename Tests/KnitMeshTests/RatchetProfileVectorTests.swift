import KnitCrypto
import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// knit-next's ratchet profiles (`ratchet-v1.json`, section `profiles`, companion change A9's second stage): Alice's,
/// Bob's and Carol's signed profiles with their prekeys, and the pin Android's own pipeline left after each, delivered
/// in the file's order (`InboundPipelineTest.theRatchetVectorProfilesPinAsTheFileSays`). The file is Android's answer,
/// so a mismatch is this port's bug, never the file's.
@Suite struct RatchetProfileVectorTests {
    private let file = RatchetVectors.file
    private var profiles: RatchetVectors.Profiles { file.profiles }

    private func bytes(_ hex: String) throws -> [UInt8] {
        try #require(Hex.decode(hex), "\(hex) is hex")
    }

    private func identity(_ name: String) throws -> IdentityKeys {
        let entry = try #require(file.identities[name])
        return try #require(IdentityKeys(signingSeed: bytes(entry.signingSeed), agreementScalar: bytes(entry.agreementScalar)))
    }

    /// A frame's wire and the envelope it signs.
    private func decode(_ frame: RatchetVectors.ProfileFrame) throws -> (wire: WireEnvelope, envelope: RelayEnvelope) {
        let wire = try WireEnvelope(decoding: bytes(frame.wire))
        return (wire, try RelayEnvelope(decoding: wire.signed))
    }

    @Test func everyProfileClaimsTheRatchetsBits() {
        #expect(profiles.capabilities == 0x159)
        #expect(Capabilities(rawValue: profiles.capabilities) == [.endToEnd, .storeForward, .ratchet, .inlineAck, .cryptoV3])
    }

    @Test func eachPrekeyDerivesFromItsPrivateKeyAndItsOwnerSignedIt() throws {
        #expect(profiles.prekeys.map(\.name) == ["aliceSpk1", "aliceSpk2", "bobSpk1", "carolSpk1"])
        for prekey in profiles.prekeys {
            let privateKey = try bytes(prekey.priv)
            let publicKey = try bytes(prekey.pub)
            #expect(privateKey == fixtureBytes(32, seed: prekey.seed), "\(prekey.name)")
            #expect(try RatchetCrypto.KeyPair(privateKey: privateKey).publicKey == publicKey, "\(prekey.name)")
            let info = PrekeyInfo(id: prekey.id, pub: publicKey, sig: try bytes(prekey.sig))
            let owner = try identity(prekey.owner)
            #expect(PeerPrekey(verifying: info, signedBy: owner.bundle) != nil, "\(prekey.name)")
        }
    }

    @Test func eachFrameIsSignedAndCarriesItsPrekeyAndOnlyTheBadOneFailsToVerify() throws {
        #expect(profiles.frames.count == 6)
        for (name, frame) in profiles.frames {
            let (wire, envelope) = try decode(frame)
            let sender = try identity(frame.sender)
            #expect(sender.bundle.isValidSignature(wire.sig, for: wire.signed), "\(name)")
            #expect(envelope.type == .profile)
            #expect(envelope.senderId == sender.nodeId.string)
            #expect(envelope.sentAt == frame.publishedAt)
            let content = try ProfileContent(decoding: envelope.payload)
            #expect(content.encoded == envelope.payload, "\(name) re-encodes exactly")
            #expect(content.pubKey == sender.bundle.encoded)
            #expect(content.version == frame.version)
            #expect(content.capabilities == profiles.capabilities)
            guard let named = frame.prekey else {
                #expect(content.prekey == nil, "\(name)")
                continue
            }
            let carried = try #require(content.prekey, "\(name)")
            let listed = try #require(profiles.prekeys.first { $0.name == named })
            let listedKey = try bytes(listed.pub)
            #expect(carried.id == listed.id && carried.pub == listedKey, "\(name)")
            #expect((PeerPrekey(verifying: carried, signedBy: sender.bundle) != nil) == frame.prekeySigValid, "\(name)")
        }
        #expect(profiles.frames.values.filter { $0.prekey != nil && !$0.prekeySigValid }.count == 1, "aliceV4BadPrekeySig alone")
    }

    @Test func oneEngineFedTheSequencePinsWhatAndroidPinned() throws {
        let fixture = EngineFixture(TestPeer(seed: 60))
        let newest = try #require(profiles.frames.values.map(\.publishedAt).max())
        #expect(fixture.clock.wallMilliseconds() >= newest, "no stamp is clamped")
        let carrier = TestPeer(seed: 61)
        #expect(profiles.sequence.map(\.deliver) == ["aliceV1", "aliceV2NoPrekey", "aliceV3", "aliceV4BadPrekeySig", "bobV1", "carolV1"])
        for step in profiles.sequence {
            let frame = try #require(profiles.frames[step.deliver])
            let (wire, envelope) = try decode(frame)
            fixture.engine.receive(InboundFrame(wire: wire, envelope: envelope, from: carrier.nodeId))
            let sender = try identity(frame.sender).nodeId
            let peer = try #require(fixture.stores.peers.peer(sender), "\(step.deliver)")
            #expect(peer.prekey?.id == step.expect.prekeyId, "\(step.deliver)")
            #expect(peer.prekey.map { Hex.encode($0.pub) } == step.expect.prekeyPub, "\(step.deliver)")
            #expect(peer.prekeyProfileAt == step.expect.prekeyProfileAt, "\(step.deliver)")
            #expect(peer.capabilities == profiles.capabilities, "\(step.deliver)")
        }
    }
}
