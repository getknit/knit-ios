import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The group form sent in the mesh, with the switch on (ADR 2026-10.5sk9, phase P6b): knit-next's `MeshManagerTest` group-send
/// cases by name (`MeshManagerTest.kt:2128-2485`, at `cbf2a487`), each frame read by an Android member's own session layers
/// (``GroupFormReader``). The seed re-sends and the key request's answer are `MeshEngineGroupSeedSendTests`'.
@Suite struct MeshEngineGroupSendTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private var now: Int64 { EngineFixture.start }

    /// The iPhone with the switch on and Alice an Android phone pinned with the ratchet's bits and a prekey.
    private func rig() throws -> (EngineFixture, GroupFormReader) {
        let fixture = try EngineFixture.ratcheting(me)
        let reader = GroupFormReader(try AndroidPeer(alice))
        try fixture.pin(reader.android)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, reader)
    }

    /// Kotlin's name is stale: its body asserts v2, the group form's one version.
    @Test func aGroupWithAllCapableMembersSealsV3AndDistributesTheSeed() throws {
        let (fixture, reader) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let message = try #require(fixture.engine.sendGroupMessage("group fs", to: group.id))
        let frame = try #require(fixture.groupFrames(in: group.id).first)
        let enc = try EngineFixture.sealed(frame)
        #expect(fixture.groupFrames(in: group.id).count == 1)
        #expect(enc.version == EncEnvelope.Version.ratchet && enc.keys.isEmpty && enc.ratchet == nil, "derived key, no wraps")
        #expect(enc.groupRatchet == GroupRatchetHeader(se: 1, n: 0))
        let seed = try #require(fixture.chats(to: alice).first)
        let seedEnc = try EngineFixture.sealed(seed)
        #expect(fixture.chats(to: alice).count == 1 && seedEnc.version == EncEnvelope.Version.ratchet)
        let order = fixture.transport.written.map(\.envelope.id)
        #expect(order.firstIndex(of: seed.envelope.id) ?? .max < order.firstIndex(of: frame.envelope.id) ?? .min, "the seed floods first")
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSealedRatchet: 1, groupSeedsSent: 1))
        #expect(!message.pendingKey && fixture.stores.messages.message(message.id)?.pendingKey == false, "never left waiting")
        #expect(fixture.stores.custody.contains(frame.envelope.id) && fixture.stores.custody.contains(seed.envelope.id), "both carried")
        #expect(fixture.stores.messages.message(seed.envelope.id) == nil, "a seed is never a row")
        #expect(fixture.stores.groupRatchet.keySend(group.id, member: alice.nodeId)?.sentEpoch == 1, "the outbox holds the send")
        try reader.receive(seed, from: me)
        #expect(reader.body(of: frame, from: me) == "group fs", "Android opens it once the seed is in")
    }

    @Test func theSeedDmCarriesTheGroupsFoundingRosterWhenTheRowIsHeld() throws {
        let (fixture, reader) = try rig()
        let info = roster([me, alice], name: "Team", createdBy: me)
        let members = info.members.map { GroupMember(nodeId: $0) }
        fixture.stores.groups.save(
            GroupRecord(
                id: info.id, name: "Team", createdBy: me.nodeId.string, createdAt: 1, photoHash: "ph1", photoUpdatedAt: 42, roster: members)
        )
        _ = try #require(fixture.engine.sendGroupMessage("mint", to: info.id))
        let payload = try #require(fixture.seeds(to: reader.android).first)
        #expect(
            payload.group == GroupInfo(id: info.id, name: "Team", members: info.members, createdBy: me.nodeId.string), "never the photo")
        #expect(payload.gr == nil && payload.keys.map(\.epoch) == [1] && payload.ackEpoch == nil)
    }

    @Test func aSecondGroupSendReusesTheChainWithoutRedistributing() throws {
        let (fixture, reader) = try rig()
        let group = fixture.holdGroup(with: [alice])
        _ = try #require(fixture.engine.sendGroupMessage("one", to: group.id))
        _ = try #require(fixture.engine.sendGroupMessage("two", to: group.id))
        #expect(fixture.chats(to: alice).count == 1, "one seed DM in all: the chain is reused")
        let frames = fixture.groupFrames(in: group.id)
        #expect(
            frames.map { try? EngineFixture.sealed($0).groupRatchet } == [GroupRatchetHeader(se: 1, n: 0), GroupRatchetHeader(se: 1, n: 1)])
        #expect(fixture.engine.groupCounts.groupSealedRatchet == 2)
        try reader.receive(try #require(fixture.chats(to: alice).first), from: me)
        #expect(frames.map { reader.body(of: $0, from: me) } == ["one", "two"])
    }

    @Test func aGroupWithAnIncapableMemberFallsBackToV1Entirely() throws {
        let (fixture, _) = try rig()
        // A pre-ratchet build's bits, everything but `CAP_RATCHET`, with a prekey all the same.
        fixture.deliver(try carol.profile(publishedAt: now, capabilities: 0xF, prekey: try carol.prekey(id: 1)), from: carol)
        let group = fixture.holdGroup(with: [alice, carol])
        fixture.transport.clear()
        _ = try #require(fixture.engine.sendGroupMessage("mixed", to: group.id))
        let frames = fixture.transport.written(.chat)
        let enc = try EngineFixture.sealed(try #require(frames.first))
        #expect(frames.count == 1 && enc.version == EncEnvelope.Version.staticKeys && enc.groupRatchet == nil && enc.keys.count == 2)
        // Never eligible, so not a fallback either: the DM's sense of the count.
        #expect(fixture.engine.groupCounts == RatchetGroupCounts())
        #expect(fixture.stores.groupRatchet.holdings(of: group.id) == .empty)
    }

    @Test func anUnpinnedMemberKeepsTheGroupV1AndIsSkippedFromTheWraps() throws {
        let (fixture, _) = try rig()
        let group = fixture.holdGroup(with: [alice, dave])
        _ = try #require(fixture.engine.sendGroupMessage("who's there", to: group.id))
        let enc = try EngineFixture.sealed(try #require(fixture.transport.written(.chat).first))
        #expect(enc.version == EncEnvelope.Version.staticKeys && enc.keys.map(\.to) == [alice.nodeId.string])
        #expect(fixture.engine.footprint.missingKeys == 1, "the unkeyed member's key is asked for")
    }

    @Test func seedsAreStillDistributedToBlockedMembers() throws {
        let (fixture, _) = try rig()
        let group = fixture.holdGroup(with: [alice])
        fixture.engine.block(alice.nodeId)
        fixture.transport.clear()
        _ = try #require(fixture.engine.sendGroupMessage("still sealed", to: group.id))
        #expect(fixture.chats(to: alice).count == 1, "withholding the seed would show the block")
        let frame = try #require(fixture.groupFrames(in: group.id).first)
        let enc = try EngineFixture.sealed(frame)
        #expect(enc.version == EncEnvelope.Version.ratchet)
    }

    @Test func aGroupReactionWithEveryMemberEligibleRidesTheGroupFormAndDistributesItsSeed() throws {
        let (fixture, reader) = try rig()
        let group = fixture.holdGroup(with: [alice])
        fixture.deliver(try alice.groupMessage("first", in: group, to: [me], id: "gm1", sentAt: now), from: alice)
        fixture.transport.clear()
        _ = try #require(fixture.engine.react(to: "gm1", with: "\u{1F525}"))
        #expect(fixture.transport.written(.reaction).isEmpty, "no cleartext reaction names the target or the emoji")
        let frame = try #require(fixture.groupFrames(in: group.id).first)
        let enc = try EngineFixture.sealed(frame)
        #expect(enc.groupRatchet != nil, "the group form's header")
        #expect(fixture.chats(to: alice).count == 1, "the first reaction mints, and its seed goes ahead")
        #expect(fixture.engine.seals == RatchetSealCounts(reactionsSealed: 1))
        let held = try #require(fixture.stores.messages.reaction(on: "gm1", by: me.nodeId))
        #expect(frame.envelope.sentAt == held.updatedAt, "dated by the row's own clock")
        try reader.receive(try #require(fixture.chats(to: alice).first), from: me)
        let opened = try reader.open(frame, from: me).get()
        #expect(opened.ctl == MessageContent.Control.reaction && opened.rp == ReactionContent(messageId: "gm1", emoji: "\u{1F525}"))
    }

    /// The fallback Kotlin counts (`onGroupSealedV1Fallback`, `MeshManager.kt:1330-1340`): every member eligible, but a
    /// seed that will not seal to one of them. Here the mint, the group chain's advance and the seeds already sealed are all
    /// undone with the attempt, and the message goes v1 to the bundles the same read gave, where Kotlin keeps the mint.
    @Test func aSeedThatWillNotSealSendsTheWholeMessageV1AndKeepsNoMint() throws {
        let (fixture, _) = try rig()
        // Carol claims the bit with a prekey X25519 refuses, the all-zero point her own key signed.
        let lowOrder = [UInt8](repeating: 0, count: RatchetCrypto.keyByteCount)
        let refused = PrekeyInfo(
            id: 1, pub: lowOrder, sig: try carol.keys.signature(for: RatchetCrypto.spkSigningBytes(id: 1, pub: lowOrder)))
        fixture.deliver(try carol.profile(publishedAt: now, capabilities: 0x15F, prekey: refused), from: carol)
        #expect(fixture.stores.peers.peer(carol.nodeId)?.prekey != nil, "pinned, since its signature verifies")
        let group = fixture.holdGroup(with: [alice, carol])
        fixture.transport.clear()
        _ = try #require(fixture.engine.sendGroupMessage("not for everyone yet", to: group.id))
        let frames = fixture.transport.written(.chat)
        let enc = try EngineFixture.sealed(try #require(frames.first))
        #expect(frames.count == 1 && enc.version == EncEnvelope.Version.staticKeys && enc.keys.count == 2, "v1, and no seed DM at all")
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSealedV1Fallback: 1))
        #expect(fixture.stores.groupRatchet.holdings(of: group.id) == .empty, "no mint and no outbox row kept")
        #expect(fixture.ratchetRecords(of: alice).session == nil, "Alice's seed's session undone with it")
    }
}
