import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The group form's seeds received in the mesh, with the switch on (ADR 2026-10.5sk9, phase P6a2): knit-next's
/// `InboundPipelineTest` cases for the custody replay after an adoption, the seed-before-roster race, a departed member's
/// rejoin and a seed that carries its roster, ported by name (`InboundPipelineTest.kt:6963-7471`, at `cbf2a487`).
///
/// Kotlin's rig records the custody replays as calls (`custodyReplays`, `seedCustodyReplays`); here the real replays run, so
/// each case reads what they did: the frame they delivered, or the chain index a nested pass would have spent.
@Suite struct MeshEngineGroupSeedTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let bob = TestPeer(seed: 3)

    private var now: Int64 { EngineFixture.start }

    /// The iPhone with the switch on, and Alice and Bob pinned as Android phones with the ratchet and a prekey.
    private func rig() throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me)
        let first = try AndroidPeer(alice)
        try fixture.pin(first)
        try fixture.pin(try AndroidPeer(bob))
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, first)
    }

    private func seed(
        _ fixture: EngineFixture, _ author: GroupFormAuthor, id: String, at offset: Int64 = 0, roster: GroupInfo? = nil, relay: Bool = true
    ) throws {
        let frame = try author.seedDm(to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: now + offset, roster: roster, relay: relay)
        fixture.deliver(frame, from: author.android)
    }

    private func acked(_ fixture: EngineFixture, by android: AndroidPeer) -> Bool {
        fixture.controls(to: android).contains { $0.ctl == MessageContent.Control.groupKeyAck }
    }

    @Test func aSeedAdoptionReplaysOurCustodyForThatGroupAndSender() throws {
        let (fixture, first) = try rig()
        let second = try AndroidPeer(bob)
        let group = fixture.holdGroup(with: [alice, bob])
        let author = GroupFormAuthor(first, in: group.id)
        let other = GroupFormAuthor(second, in: group.id)
        fixture.deliver(try author.frame(group, id: "gm-early", body: "too soon", sentAt: now), from: alice)
        fixture.deliver(try other.frame(group, id: "gm-bob", body: "not yet", sentAt: now), from: bob)
        #expect(fixture.engine.dropped[.groupRatchetNoKey] == 2)
        try seed(fixture, author, id: "seed1")
        #expect(fixture.stores.messages.message("gm-early")?.body == "too soon", "our custody's copy opened once the seed landed")
        #expect(fixture.stores.messages.message("gm-bob") == nil, "narrowed to the seed's sender")
        #expect(fixture.engine.dropped[.groupRatchetNoKey] == 2, "Bob's frame was not tried again")
    }

    @Test func aSeedThatOutransItsGroupsFirstFrameIsParkedAndAdoptedWhenTheRosterLands() throws {
        let (fixture, first) = try rig()
        let group = roster([me, alice], createdBy: alice)
        let author = GroupFormAuthor(first, in: group.id)
        try seed(fixture, author, id: "seed-early")
        #expect(fixture.recvChains(group.id, from: alice).isEmpty, "parked, not consumed")
        #expect(!acked(fixture, by: first) && fixture.stores.groups.group(group.id) == nil)
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsHeld: 1))
        #expect(fixture.engine.pendingGroupKeys.parked.count == 1)
        fixture.deliver(try author.frame(group, id: "g-first", body: "stock group", sentAt: now + 1), from: alice)
        #expect(fixture.stores.groups.group(group.id) != nil)
        #expect(fixture.engine.groupCounts.groupSeedsReplayed == 1 && fixture.engine.groupCounts.groupSeedsAdopted == 1)
        #expect(fixture.recvChains(group.id, from: alice).count == 1)
        #expect(fixture.stores.messages.message("g-first")?.body == "stock group")
        #expect(fixture.engine.dropped[.groupRatchetNoKey] == nil && fixture.engine.dropped[.ratchetDuplicate] == nil)
        #expect(acked(fixture, by: first), "the adoption's ack went as for any seed")
        #expect(
            fixture.stores.messages.message("seed-early") == nil && fixture.sealedReceipts(to: first).isEmpty, "the ctl kept its contract")
    }

    @Test func aParkedSeedLeavesTheChainWhereItWasSoItsReServeStillOpens() throws {
        let (fixture, first) = try rig()
        let group = roster([me, alice], createdBy: alice)
        let author = GroupFormAuthor(first, in: group.id)
        // Point to point, so our custody holds no copy for the first sight's replay to open: only a re-serve brings it.
        let seedFrame = try author.seedDm(to: me, prekey: try fixture.ourPrekey(), id: "seed-aged", sentAt: now, relay: false)
        fixture.deliver(seedFrame, from: alice)
        fixture.advance(2 * Self.hour)
        #expect(fixture.engine.pendingGroupKeys.parked.isEmpty, "the hold aged out")
        fixture.deliver(try author.frame(group, id: "g-first", body: "stock group", sentAt: now + 2 * Self.hour), from: alice)
        #expect(fixture.engine.dropped[.groupRatchetNoKey] == 1)
        #expect(fixture.stores.messages.message("g-first") == nil)
        fixture.deliver(seedFrame, from: alice)
        #expect(fixture.engine.dropped[.ratchetDuplicate] == nil, "the chain never moved past it")
        #expect(fixture.recvChains(group.id, from: alice).count == 1 && fixture.engine.groupCounts.groupSeedsAdopted == 1)
        #expect(fixture.stores.messages.message("g-first")?.body == "stock group", "the adoption's replay opened it")
    }

    @Test func aDepartedMemberRejoinsByItsOwnFrameAndItsEarlySeedIsReplayed() throws {
        let (fixture, first) = try rig()
        let group = fixture.holdGroup(with: [alice])
        try fixture.depart(alice, from: group, at: now + 10)
        let author = GroupFormAuthor(first, in: group.id)
        try seed(fixture, author, id: "seed-back", at: 15)
        #expect(fixture.engine.groupCounts.groupSeedsHeld == 1 && fixture.recvChains(group.id, from: alice).isEmpty)
        #expect(fixture.roster(of: group).departed == [alice.nodeId.string])
        fixture.deliver(try author.frame(group, id: "g-back", body: "back again", sentAt: now + 20), from: alice)
        #expect(fixture.roster(of: group).members == [me.nodeId.string, alice.nodeId.string] && fixture.roster(of: group).departed.isEmpty)
        #expect(fixture.engine.groupCounts.groupSeedsReplayed == 1 && fixture.recvChains(group.id, from: alice).count == 1)
        #expect(fixture.stores.messages.message("g-back")?.body == "back again")
        #expect(fixture.engine.dropped[.groupRatchetNoKey] == nil)
        // Kotlin's rejoin rekey and its hourly floor (`recordRejoin(rekey:)`) retire our send chain: phase P6b's
        // `GroupSendPairTests.aRejoinRekeysOncePerHourAndADepartureAlways()`.
    }

    @Test func anotherMembersFrameLeavesADepartedSendersSeedParkedUntilTheyRejoin() throws {
        let (fixture, first) = try rig()
        let group = fixture.holdGroup(with: [alice, bob])
        try fixture.depart(alice, from: group, at: now + 10)
        let author = GroupFormAuthor(first, in: group.id)
        try seed(fixture, author, id: "seed-parked", at: 15)
        #expect(fixture.engine.groupCounts.groupSeedsHeld == 1)
        for offset in Int64(20)...22 {
            fixture.deliver(try bob.groupUpdate(group, id: "bob-\(offset)", sentAt: now + offset), from: bob)
        }
        #expect(fixture.roster(of: group).departed == [alice.nodeId.string], "only her own signature lifts it")
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsHeld: 1), "Bob's frames leave her seed where it is")
        #expect(fixture.recvChains(group.id, from: alice).isEmpty)
        fixture.deliver(try author.frame(group, id: "g-back", body: "back again", sentAt: now + 30), from: alice)
        #expect(fixture.roster(of: group).departed.isEmpty)
        #expect(fixture.engine.groupCounts.groupSeedsHeld == 1 && fixture.engine.groupCounts.groupSeedsReplayed == 1)
        #expect(fixture.recvChains(group.id, from: alice).count == 1)
        #expect(fixture.stores.messages.message("g-back")?.body == "back again")
        #expect(fixture.engine.dropped[.groupRatchetNoKey] == nil)
    }

    @Test func aDepartedSendersParkedSeedAgesOutDespiteTheGroupsTraffic() throws {
        let (fixture, first) = try rig()
        let group = fixture.holdGroup(with: [alice, bob])
        try fixture.depart(alice, from: group, at: now + 10)
        let author = GroupFormAuthor(first, in: group.id)
        try seed(fixture, author, id: "seed-stale", at: 15)
        fixture.clock.advance(2 * Self.hour)
        fixture.deliver(try bob.groupUpdate(group, id: "bob-20", sentAt: now + 2 * Self.hour), from: bob)
        #expect(fixture.engine.pendingGroupKeys.sweep(now: fixture.clock.monotonicMilliseconds()) == 1, "parked at its first park")
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsHeld: 1))
    }

    @Test func aReServedPreLeaveFrameDoesNotRejoinADepartedMember() throws {
        let (fixture, _) = try rig()
        let group = fixture.holdGroup(with: [alice])
        try fixture.depart(alice, from: group, at: now + 10)
        fixture.deliver(try alice.groupUpdate(group, id: "pre-leave", sentAt: now + 5), from: alice)
        #expect(fixture.roster(of: group).members == [me.nodeId.string] && fixture.roster(of: group).departed == [alice.nodeId.string])
    }

    @Test func anotherMembersFrameCannotReAddADepartedMember() throws {
        let (fixture, _) = try rig()
        let group = fixture.holdGroup(with: [alice, bob])
        try fixture.depart(alice, from: group, at: now + 10)
        fixture.deliver(try bob.groupUpdate(group, id: "bob-20", sentAt: now + 20), from: bob)
        #expect(fixture.roster(of: group).members == [me.nodeId.string, bob.nodeId.string])
        #expect(fixture.roster(of: group).departed == [alice.nodeId.string])
    }

    @Test func aSeedForAGroupWeHoldTakesTheOrdinaryPathUntouched() throws {
        let (fixture, first) = try rig()
        let group = fixture.holdGroup(with: [alice])
        try seed(fixture, GroupFormAuthor(first, in: group.id), id: "seed-known")
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsAdopted: 1))
        #expect(fixture.engine.pendingGroupKeys.parked.isEmpty)
    }

    @Test func aSeedCarryingItsRosterPinsTheGroupAndAdoptsOnItsFirstPass() throws {
        let (fixture, first) = try rig()
        var group = roster([me, alice], createdBy: alice)
        group.name = "Team"
        let author = GroupFormAuthor(first, in: group.id)
        try seed(fixture, author, id: "seed-roster", at: 7, roster: group)
        let row = try #require(fixture.stores.groups.group(group.id), "pinned from the seed")
        #expect(Set(row.members) == Set(group.members) && row.createdBy == alice.nodeId.string)
        #expect(row.name == "Team" && row.createdAt == now + 7 && row.photoHash == nil)
        #expect(fixture.stores.messages.message("created:\(group.id)")?.kind == .groupCreated)
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsAdopted: 1), "adopted on this pass, nothing parked")
        #expect(fixture.recvChains(group.id, from: alice).count == 1 && acked(fixture, by: first))
        #expect(fixture.engine.dropped[.rosterRefused] == nil)
        // The first sight's replay skipped the seed itself: a nested pass would have spent its chain index under the pin, and
        // this pass's open would then have dropped as a duplicate.
        #expect(fixture.engine.dropped[.ratchetDuplicate] == nil)
        #expect(fixture.stores.messages.message("seed-roster") == nil && fixture.sealedReceipts(to: first).isEmpty)
        fixture.deliver(try author.frame(group, id: "g-first", body: "founded across the relay", sentAt: now + 8), from: alice)
        #expect(fixture.stores.messages.message("g-first")?.body == "founded across the relay")
        #expect(fixture.engine.dropped[.groupRatchetNoKey] == nil && fixture.engine.dropped[.ratchetDuplicate] == nil)
    }

    @Test func aSeedWhoseRosterDoesNotDeriveToItsIdIsParkedNotPinned() throws {
        let (fixture, first) = try rig()
        var forged = roster([me, alice], createdBy: alice)
        forged.id = "g-forged"
        try seed(fixture, GroupFormAuthor(first, in: forged.id), id: "seed-forged", roster: forged)
        #expect(fixture.stores.groups.group("g-forged") == nil)
        #expect(fixture.engine.dropped[.rosterRefused] == 1)
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsHeld: 1))
    }

    @Test func aSeedWhoseRosterOmitsUsIsParkedSilently() throws {
        let (fixture, first) = try rig()
        let theirs = roster([alice, bob], createdBy: alice)
        try seed(fixture, GroupFormAuthor(first, in: theirs.id), id: "seed-theirs", roster: theirs)
        #expect(fixture.stores.groups.group(theirs.id) == nil)
        #expect(fixture.engine.dropped[.rosterRefused] == nil)
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsHeld: 1))
    }

    @Test func aSeedWhoseRosterNamesAnotherGroupIsParkedWithTheRosterIgnored() throws {
        let (fixture, first) = try rig()
        let ours = roster([me, alice], createdBy: alice)
        let other = roster([me, alice, bob], createdBy: alice)
        try seed(fixture, GroupFormAuthor(first, in: ours.id), id: "seed-mismatch", roster: other)
        #expect(fixture.stores.groups.group(ours.id) == nil && fixture.stores.groups.group(other.id) == nil)
        #expect(fixture.engine.dropped[.rosterRefused] == nil)
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsHeld: 1))
    }

    @Test func aSeedWhoseRosterNamesABlockedCreatorIsParkedNotPinned() throws {
        let (fixture, _) = try rig()
        let second = try AndroidPeer(bob)
        fixture.stores.blocks.block(alice.nodeId, deviceTag: nil)
        let group = roster([me, alice, bob], createdBy: alice)
        try seed(fixture, GroupFormAuthor(second, in: group.id), id: "seed-blocked", roster: group)
        #expect(fixture.stores.groups.group(group.id) == nil, "a group a blocked user starts is never made here")
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsHeld: 1))
    }

    @Test func aDepartedSendersRosterCarryingSeedRejoinsThemAndAdopts() throws {
        let (fixture, first) = try rig()
        let group = fixture.holdGroup(with: [alice])
        try fixture.depart(alice, from: group, at: now + 10)
        let author = GroupFormAuthor(first, in: group.id)
        try seed(fixture, author, id: "seed-rejoin", at: 20, roster: group)
        #expect(fixture.roster(of: group).members == [me.nodeId.string, alice.nodeId.string] && fixture.roster(of: group).departed.isEmpty)
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsAdopted: 1))
        #expect(fixture.recvChains(group.id, from: alice).count == 1)
        fixture.deliver(try author.frame(group, id: "g-back", body: "back again", sentAt: now + 21), from: alice)
        #expect(fixture.stores.messages.message("g-back")?.body == "back again")
        #expect(fixture.engine.dropped[.groupRatchetNoKey] == nil)
    }

    @Test func aReServedPreLeaveRosterCarryingSeedStaysParked() throws {
        let (fixture, first) = try rig()
        let group = fixture.holdGroup(with: [alice])
        try fixture.depart(alice, from: group, at: now + 10)
        try seed(fixture, GroupFormAuthor(first, in: group.id), id: "seed-preleave", at: 5, roster: group)
        #expect(fixture.roster(of: group).members == [me.nodeId.string] && fixture.roster(of: group).departed == [alice.nodeId.string])
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsHeld: 1))
        #expect(fixture.recvChains(group.id, from: alice).isEmpty)
    }

    @Test func aRosterCarryingSeedForAGroupWeHoldTakesTheOrdinaryPathUntouched() throws {
        let (fixture, first) = try rig()
        let group = fixture.holdGroup(with: [alice])
        var renamed = group
        renamed.name = "Renamed"
        try seed(fixture, GroupFormAuthor(first, in: group.id), id: "seed-held", at: 99, roster: renamed)
        #expect(fixture.stores.groups.group(group.id)?.name.isEmpty == true, "the roster it carries is never reconciled")
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsAdopted: 1))
    }

    private static let hour: Int64 = 3_600_000
}

/// This port's own cases of the seed park (ADR 2026-10.5sk9, phase P6a2): what the start's replay does with a seed for a
/// group we lack, a parked seed served again, and a full park.
@Suite struct MeshEngineGroupSeedParkTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)

    private var now: Int64 { EngineFixture.start }

    private func rig() throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me)
        let first = try AndroidPeer(alice)
        try fixture.pin(first)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, first)
    }

    private func seed(_ fixture: EngineFixture, _ author: GroupFormAuthor, id: String) throws {
        fixture.deliver(try author.seedDm(to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: now), from: author.android)
    }

    /// This port's own: a seed out of our own custody at start, for a group we do not hold, is left unopened rather than
    /// parked or consumed, since the first sight's replay opens it from custody once the roster lands.
    @Test func aSeedTheStartsReplayMeetsForAGroupWeLackStaysInCustodyUnopened() throws {
        let stores = MeshStores.inMemory()
        let keychain = KeptSecretStore(me.keys.storedForm)
        let fixture = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let first = try AndroidPeer(alice)
        try fixture.pin(first)
        let group = roster([me, alice], createdBy: alice)
        let author = GroupFormAuthor(first, in: group.id)
        try seed(fixture, author, id: "seed-parked")
        #expect(fixture.engine.pendingGroupKeys.parked.count == 1)
        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 60_000, seed: 8)
        #expect(restarted.engine.pendingGroupKeys.parked.isEmpty, "the park died with the process")
        #expect(restarted.log.all.contains { $0.contains("mesh group seed seed-parked from \(alice.nodeId) left in custody") })
        #expect(restarted.ratchetRecords(of: alice).session == nil, "nothing committed: the init it carries waits too")
        #expect(stores.custody.contains("seed-parked"))
    }

    /// A parked seed served again is swallowed the same way, uncounted (`hold`, `PendingGroupKeys.kt:58-60`).
    @Test func aParkedSeedServedAgainIsSwallowedAndCountedOnce() throws {
        let (fixture, first) = try rig()
        let group = roster([me, alice], createdBy: alice)
        let frame = try GroupFormAuthor(first, in: group.id).seedDm(to: me, prekey: try fixture.ourPrekey(), id: "seed-1", sentAt: now)
        fixture.deliver(frame, from: alice)
        fixture.advance(SeenSet.defaultWindowMilliseconds + 1)
        fixture.deliver(frame, from: alice)
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsHeld: 1) && fixture.engine.pendingGroupKeys.parked.count == 1)
    }

    /// A group whose park is full lets the next seed take the ordinary path (`holdGroupKeyForUnknownGroup`, `:1473`): it
    /// commits, with nothing adopted, as Kotlin's does.
    @Test func aSeedForAGroupWhoseParkIsFullTakesTheOrdinaryPath() throws {
        let (fixture, first) = try rig()
        let group = roster([me, alice], createdBy: alice)
        let author = GroupFormAuthor(first, in: group.id)
        let prekey = try fixture.ourPrekey()
        for index in 0...PendingGroupKeys.defaultPerGroup {
            fixture.deliver(try author.seedDm(to: me, prekey: prekey, id: "seed-\(index)", sentAt: now + Int64(index)), from: alice)
        }
        #expect(fixture.engine.pendingGroupKeys.parked.count == PendingGroupKeys.defaultPerGroup)
        #expect(fixture.engine.groupCounts == RatchetGroupCounts(groupSeedsHeld: PendingGroupKeys.defaultPerGroup))
        #expect(fixture.ratchetRecords(of: alice).session != nil, "the last one committed")
        #expect(fixture.recvChains(group.id, from: alice).isEmpty, "with nothing adopted")
    }
}
