import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A group member whose identity key no one can wrap to (#172): knit-next's `MeshManagerTest` and `GroupMembershipLabTest`
/// cases of `458c2eee`, under their Kotlin names (at `4f3cd995`). A forged profile pairs a real Ed25519 key with a low-order
/// X25519 key and pins like any profile, since its signing half is valid. It used to strand the whole group: no seed could
/// seal to it, the v1 wrap then refused the whole message, and every post waited with nothing to retry it. The group now
/// goes v1 to everyone else, with the switch on as off.
@Suite struct MeshEngineLowOrderMemberTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let mallory = TestPeer(seed: 3)

    /// Mallory's signing key beside 32 zero bytes, pinned with the ratchet's bits and a prekey of hers, and a group of us,
    /// Alice and that phantom.
    private func phantomGroup(in fixture: EngineFixture) throws -> (group: GroupRecord, phantom: NodeId) {
        let forged = try #require(
            PublicKeyBundle(signingKey: mallory.keys.bundle.signingKey, agreementKey: [UInt8](repeating: 0, count: 32)))
        var row = PeerRecord(nodeId: forged.nodeId, name: "Phantom", status: "", publicKey: forged.encoded, updatedAt: 1)
        row.capabilities = AndroidPeer.capabilities
        row.prekey = try mallory.prekey(id: 1)
        fixture.stores.peers.upsert(row)
        let members = [me.nodeId, alice.nodeId, forged.nodeId].map { GroupMember(nodeId: $0.string) }
        let group = GroupRecord(id: GroupId.derive(members.map(\.nodeId)), createdBy: me.nodeId.string, createdAt: 1, roster: members)
        fixture.stores.groups.save(group)
        return (group, forged.nodeId)
    }

    /// The one group frame we sent, its envelope.
    private func sealed(_ fixture: EngineFixture, in group: GroupRecord) throws -> EncEnvelope {
        let frames = fixture.transport.written(.chat).filter { $0.envelope.group?.id == group.id }
        #expect(frames.count == 1)
        let frame = try #require(frames.first)
        return try #require(try ChatContent(decoding: frame.envelope.payload).enc)
    }

    /// `aGroupMemberWithALowOrderIdentityKeyIsSkippedAndTheRestGetThePost`, with the switch on: no seed minted for a
    /// distribution that cannot succeed, and the post wrapped to every member but the phantom.
    @Test func aGroupMemberWithALowOrderIdentityKeyIsSkippedAndTheRestGetThePost() throws {
        let fixture = try EngineFixture.ratcheting(me)
        try fixture.pin(try AndroidPeer(alice))
        let (group, phantom) = try phantomGroup(in: fixture)
        fixture.transport.clear()

        let message = try #require(fixture.engine.sendGroupMessage("still reaches alice", to: group.id))
        #expect(fixture.stores.messages.message(message.id)?.pendingKey == false)
        let envelope = try sealed(fixture, in: group)
        #expect(envelope.version == EncEnvelope.Version.staticKeys && envelope.keys.map(\.to) == [alice.nodeId.string])
        #expect(fixture.chats(to: alice).isEmpty && fixture.stores.groupRatchet.holdings(of: group.id) == .empty, "no seed minted")
        #expect(fixture.ratchetRecords(of: mallory).session == nil && fixture.stores.ratchet.session(phantom) == nil)
        let header = MessageCrypto.header(id: message.id, senderId: me.nodeId.string, sentAt: message.sentAt, thread: group.id)
        #expect(MessageCrypto.open(envelope, header: header, as: alice.keys)?.body == "still reaches alice")
    }

    /// The same with the switch off: the v1 seal skips the phantom as a member whose key we do not know, without a key
    /// request for a key we hold.
    @Test func withTheSwitchOffTheV1SealSkipsTheMemberAndTheRestGetThePost() throws {
        let fixture = EngineFixture(me)
        try fixture.pin(alice)
        let (group, _) = try phantomGroup(in: fixture)
        fixture.transport.clear()

        let message = try #require(fixture.engine.sendGroupMessage("still reaches alice", to: group.id))
        #expect(!message.pendingKey)
        let envelope = try sealed(fixture, in: group)
        #expect(envelope.keys.map(\.to) == [alice.nodeId.string])
        #expect(fixture.transport.written(.keyRequest).isEmpty, "the phantom's key is pinned: nothing to ask for")
    }

    /// `aDmToALowOrderIdentityKeyIsKeptPendingNotThrown`: every exchange against that key refuses, X3DH and the v1 wrap
    /// alike, so a DM to it waits as `pendingKey`, as for a peer whose key is unknown, rather than leaving at all.
    @Test(arguments: [true, false])
    func aDmToALowOrderIdentityKeyIsKeptPendingNotThrown(ratchet: Bool) throws {
        let fixture = ratchet ? try EngineFixture.ratcheting(me) : EngineFixture(me)
        let (_, phantom) = try phantomGroup(in: fixture)
        fixture.transport.clear()
        let message = try #require(fixture.engine.sendDirectMessage("hello", to: phantom))
        #expect(fixture.stores.messages.message(message.id)?.pendingKey == true)
        #expect(fixture.transport.written(.chat).isEmpty)
        #expect(fixture.stores.ratchet.session(phantom) == nil)
    }
}
