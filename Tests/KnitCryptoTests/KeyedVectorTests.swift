import KnitCrypto
import KnitTestSupport
import KnitWire
import Testing

/// knit-next's keyed vectors (`keyed-v1.json`): identities from fixed keys, the frames Alice signed with Tink, the
/// v1 DM she sealed to Bob, and their safety number.
///
/// Every frame must decode, re-encode to the exact bytes it was signed as, and verify. Alice's profile is the
/// shape this port publishes too, so it also proves our encoder writes what kotlinx writes.
@Suite struct KeyedVectorTests {
    private let file = KeyedVectors.file

    private func identity(_ name: String) throws -> IdentityKeys {
        let entry = try #require(file.identities[name])
        return try #require(IdentityKeys(signingSeed: hexBytes(entry.signingSeed), agreementScalar: hexBytes(entry.agreementScalar)))
    }

    private func frame(_ name: String) throws -> VectorFrame {
        try #require(file.frames[name])
    }

    /// The frame's relay envelope, after checking that the wire and the envelope re-encode to themselves and that
    /// the sender's signature verifies.
    private func relay(of frame: VectorFrame, from sender: IdentityKeys) throws -> RelayEnvelope {
        let bytes = hexBytes(frame.wire)
        let wire = try WireEnvelope(decoding: bytes)
        #expect(wire.encoded == bytes)
        #expect(sender.bundle.isValidSignature(wire.sig, for: wire.signed))
        let relay = try RelayEnvelope(decoding: wire.signed)
        #expect(relay.encoded == wire.signed)
        #expect(relay.senderId == sender.nodeId.string)
        return relay
    }

    @Test(arguments: ["alice", "bob"])
    func identitiesDeriveKnitNextsBundlesAndNodeIds(name: String) throws {
        let entry = try #require(file.identities[name])
        let keys = try identity(name)
        #expect(keys.bundle.encoded == entry.bundle)
        #expect(keys.nodeId.string == entry.nodeId)
    }

    @Test func theSafetyNumberMatchesKnitNext() throws {
        let between = try file.safetyNumber.between.map(identity)
        let number = SafetyNumber.compute(mine: try #require(between.first).bundle, theirs: try #require(between.last).bundle)
        #expect(number == file.safetyNumber.number)
    }

    @Test func alicesProfilePinsHerKeyAndReencodesExactly() throws {
        let alice = try identity("alice")
        let relay = try relay(of: frame("aliceProfile"), from: alice)
        #expect(relay.type == .profile)
        #expect(relay.id == "profile-\(alice.nodeId)-\(relay.sentAt)")
        let profile = try ProfileContent(decoding: relay.payload)
        #expect(profile.encoded == relay.payload)
        #expect(profile.pubKey == alice.bundle.encoded)
        #expect(profile.deviceTag == DeviceTag.derive("vector-device-alice"))
        // The vector's own capabilities, from before groups (`KeyedVectorTest.CAPABILITIES`, ADR 2026-09.n393).
        #expect(profile.capabilities == 0x9)
    }

    @Test func alicesRoomPostCarriesItsBody() throws {
        let alice = try identity("alice")
        let frame = try frame("aliceRoomPost")
        let relay = try relay(of: frame, from: alice)
        #expect(relay.recipientId == nil)
        #expect(try ChatContent(decoding: relay.payload).body == frame.body)
    }

    @Test func bobOpensAlicesDMAndAliceCannot() throws {
        let alice = try identity("alice")
        let bob = try identity("bob")
        let frame = try frame("aliceDmToBob")
        let relay = try relay(of: frame, from: alice)
        #expect(relay.recipientId == bob.nodeId.string)
        let chat = try ChatContent(decoding: relay.payload)
        #expect(chat.body.isEmpty, "a DM carries no cleartext body")
        let envelope = try #require(chat.enc)
        let header = MessageCrypto.header(id: relay.id, senderId: relay.senderId, sentAt: relay.sentAt, thread: bob.nodeId.string)
        #expect(MessageCrypto.open(envelope, header: header, as: bob)?.body == frame.body)
        #expect(MessageCrypto.open(envelope, header: header, as: alice) == nil)
    }
}
