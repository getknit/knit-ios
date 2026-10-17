import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Our group seeds sent again, with the switch on (ADR 2026-10.5sk9, phase P6b): knit-next's `MeshManagerTest` re-send and
/// key-request cases by name (`MeshManagerTest.kt:2335-2440`), `InboundPipelineTest.aSessionResetAlsoReSendsGroupSeeds`
/// (`:6943`), at `cbf2a487`, and this port's own: each trigger, the floor, and what is never re-sent.
@Suite struct MeshEngineGroupSeedSendTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let bob = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }
    private static let floor = GroupRatchetOutbound.seedResendMilliseconds

    /// The iPhone with the switch on, Alice an Android member who opened our first seed, and the group, its epoch 1 minted
    /// by our first message.
    private func minted() throws -> Minted {
        let fixture = try EngineFixture.ratcheting(me)
        let reader = GroupFormReader(try AndroidPeer(alice))
        try fixture.pin(reader.android)
        try fixture.pin(try AndroidPeer(bob))
        let group = fixture.holdGroup(with: [alice])
        _ = try #require(fixture.engine.sendGroupMessage("mint it", to: group.id))
        try reader.receive(try #require(fixture.chats(to: alice).first), from: me)
        return Minted(fixture: fixture, reader: reader, group: group)
    }

    /// What ``minted()`` sets up.
    private struct Minted {
        let fixture: EngineFixture
        let reader: GroupFormReader
        let group: GroupInfo
    }

    private func seedsTo(_ peer: TestPeer, in fixture: EngineFixture) -> Int {
        fixture.chats(to: peer).count
    }

    /// A key request for `groupId` from `android`, under the session it holds with us, or its first.
    private func request(_ groupId: String, from android: AndroidPeer, id: String, to fixture: EngineFixture) throws {
        let content = MessageContent(body: "", ctl: MessageContent.Control.groupKeyRequest, gk: GroupKeyPayload(groupId: groupId))
        fixture.deliver(
            try android.dm(content, to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: fixture.clock.wallMilliseconds()),
            from: android)
    }

    @Test func aKeyRequestReSendsCurrentSeedsOncePerFloor() throws {
        let rig = try minted()
        let fixture = rig.fixture
        let reader = rig.reader
        let group = rig.group
        let afterMint = seedsTo(alice, in: fixture)
        try request(group.id, from: reader.android, id: "req-1", to: fixture)
        #expect(seedsTo(alice, in: fixture) == afterMint + 1, "a member's request re-seals our current seeds")
        let resent = try #require(fixture.chats(to: alice).last)
        let answer = try #require(try reader.receive(resent, from: me))
        #expect(answer.gk?.keys.map(\.epoch) == [1] && answer.gk?.group?.id == group.id, "never advancing the epoch")
        try request(group.id, from: reader.android, id: "req-2", to: fixture)
        #expect(seedsTo(alice, in: fixture) == afterMint + 1, "once per floor")
        let outsider = try AndroidPeer(bob)
        try request(group.id, from: outsider, id: "req-bob", to: fixture)
        #expect(fixture.seeds(to: outsider).isEmpty, "a non-member's request re-seals nothing")
        #expect(fixture.engine.groupCounts.groupSeedsSent == 2 && fixture.stores.groupRatchet.sendChains(group.id).count == 1)
    }

    /// The P6b half of Kotlin's `aKeyRequestCtlInvokesTheRedistributionLambda` (`InboundPipelineTest.kt:6926`): a request for
    /// a group we hold is answered once its unit commits, and is never a row. One from a departed member, or for a group we
    /// left, is not.
    @Test func aKeyRequestIsAnsweredOnlyForAMemberOfAGroupWeHoldAndHaveNotLeft() throws {
        let rig = try minted()
        let fixture = rig.fixture
        let reader = rig.reader
        let group = rig.group
        try fixture.depart(alice, from: group, at: now + 1)
        try request(group.id, from: reader.android, id: "req-gone", to: fixture)
        #expect(seedsTo(alice, in: fixture) == 1 && fixture.stores.messages.message("req-gone") == nil, "departed: nothing")
        let other = roster([me, alice, bob], createdBy: me)
        try request(other.id, from: reader.android, id: "req-unknown", to: fixture)
        #expect(seedsTo(alice, in: fixture) == 1, "a group we do not hold: nothing")
    }

    @Test func aForcedFlushBypassesTheStaleAckGuardAfterAPeerWipe() throws {
        let rig = try minted()
        let fixture = rig.fixture
        let group = rig.group
        fixture.stores.groupRatchet.markKeyAcked(group.id, by: alice.nodeId, epoch: 1, at: now)
        let before = seedsTo(alice, in: fixture)
        fixture.engine.flushPendingGroupKeys(for: alice.nodeId, force: false)
        #expect(seedsTo(alice, in: fixture) == before, "the routine path stops at the ack")
        fixture.engine.flushPendingGroupKeys(for: alice.nodeId, force: true)
        #expect(seedsTo(alice, in: fixture) == before + 1, "the reset's path goes past it")
        #expect(fixture.engine.groupCounts.groupSeedsSent == 2)
    }

    @Test func aSeedSentUnderARootTheMemberHasLeftDoesNotHoldBackTheNextOne() throws {
        let rig = try minted()
        let fixture = rig.fixture
        fixture.engine.flushPendingGroupKeys(for: alice.nodeId, force: false)
        let floored = seedsTo(alice, in: fixture)
        #expect(floored == 2, "unacknowledged: one re-send, which stamps the floor")
        fixture.engine.flushPendingGroupKeys(for: alice.nodeId, force: true)
        #expect(seedsTo(alice, in: fixture) == floored, "the same root: the floor holds, forced or not")
        // Alice's replacement landed: the session we hold with her has another root now.
        var session = try #require(fixture.stores.ratchet.session(alice.nodeId))
        session.root = Array(repeating: 9, count: 32)
        fixture.stores.ratchet.upsertSession(session)
        fixture.engine.flushPendingGroupKeys(for: alice.nodeId, force: true)
        #expect(seedsTo(alice, in: fixture) == floored + 1, "the seed under the left root no longer counts")
        fixture.engine.flushPendingGroupKeys(for: alice.nodeId, force: true)
        #expect(seedsTo(alice, in: fixture) == floored + 1, "and the new root has a floor of its own")
        fixture.advance(Self.floor)
        fixture.engine.flushPendingGroupKeys(for: alice.nodeId, force: false)
        #expect(seedsTo(alice, in: fixture) >= floored + 2, "past the floor it goes again while unacknowledged")
    }

    /// Kotlin's `aSessionResetAlsoReSendsGroupSeeds` (`InboundPipelineTest.kt:6943`): a ctl is never a row, so the re-seal of
    /// our DMs cannot bring back a seed the wiped peer lost; its reset forces the flush past its stale ack.
    @Test func aSessionResetAlsoReSendsGroupSeeds() throws {
        let rig = try minted()
        let fixture = rig.fixture
        let reader = rig.reader
        let group = rig.group
        fixture.stores.groupRatchet.markKeyAcked(group.id, by: alice.nodeId, epoch: 1, at: now)
        fixture.advance(60_000)
        let before = seedsTo(alice, in: fixture)
        let wiped = try AndroidPeer(alice)
        fixture.deliver(
            try wiped.resetDm(to: me, prekey: try fixture.ourPrekey(), id: "rst", at: fixture.clock.wallMilliseconds()), from: wiped)
        let sent = fixture.chats(to: alice).dropFirst(before).compactMap { wiped.peek($0, from: me) }
        let seeds = sent.filter { $0.ctl == MessageContent.Control.groupKey }
        #expect(seeds.count == 1, "forced past the ack the wipe made stale: \(sent.map(\.ctl))")
        #expect(seeds.first?.gk?.keys.map(\.epoch) == [1] && reader.nodeId == wiped.nodeId)
    }

    @Test func aMembersProfileALinkUpAndTheReOfferEachFlushWhatItNeverAcknowledged() throws {
        let rig = try minted()
        let fixture = rig.fixture
        let reader = rig.reader
        fixture.advance(1)
        try fixture.pin(reader.android)
        #expect(seedsTo(alice, in: fixture) == 2, "its profile: re-sent, the floor stamped")
        fixture.link(alice)
        fixture.advance(MeshConfiguration().reofferMilliseconds)
        #expect(seedsTo(alice, in: fixture) == 2, "the link-up and the re-offer meet the floor")
        fixture.advance(Self.floor)
        #expect(seedsTo(alice, in: fixture) == 3, "a re-offer past the floor sends it again")
    }

    @Test func anAcknowledgedSeedAGroupWeLeftAndOurselvesAreNeverFlushed() throws {
        let rig = try minted()
        let fixture = rig.fixture
        let reader = rig.reader
        let group = rig.group
        let ack = MessageContent(body: "", ctl: MessageContent.Control.groupKeyAck, gk: GroupKeyPayload(groupId: group.id, ackEpoch: 1))
        fixture.deliver(
            try reader.android.dm(ack, to: me, prekey: try fixture.ourPrekey(), id: "ack-1", sentAt: now + 1), from: reader.android)
        #expect(fixture.stores.groupRatchet.keySend(group.id, member: alice.nodeId)?.ackedEpoch == 1)
        fixture.engine.flushPendingGroupKeys(for: alice.nodeId, force: false)
        fixture.engine.flushPendingGroupKeys(for: me.nodeId, force: true)
        #expect(seedsTo(alice, in: fixture) == 1 && fixture.chats(to: me).isEmpty)
        #expect(fixture.engine.leaveGroup(group.id))
        fixture.engine.flushPendingGroupKeys(for: alice.nodeId, force: true)
        #expect(seedsTo(alice, in: fixture) == 1, "we left: nothing")
    }

    @Test func aReSendWhoseUnitFailsSendsNothingAndStampsNoFloor() throws {
        let directory = scratchDirectory("seed-resend-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try StoreKind.sql.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        try fixture.pin(try AndroidPeer(alice))
        let group = fixture.holdGroup(with: [alice])
        _ = try #require(fixture.engine.sendGroupMessage("mint it", to: group.id))
        refusing.refusesWrites = true
        fixture.engine.flushPendingGroupKeys(for: alice.nodeId, force: false)
        refusing.refusesWrites = false
        #expect(seedsTo(alice, in: fixture) == 1 && fixture.engine.groupFloors.seeds.isEmpty, "nothing on the air, no floor")
        #expect(fixture.stores.groupRatchet.keySend(group.id, member: alice.nodeId)?.sentEpoch == 1)
        fixture.engine.flushPendingGroupKeys(for: alice.nodeId, force: false)
        #expect(seedsTo(alice, in: fixture) == 2, "the next trigger sends it")
    }
}
