import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Our custodied `groupleave` and `groupupdate` frames replayed (ADR 2026-10.5sk9, phase P7a): the start's replay, and with
/// the switch on the hourly one, take them from others beside the group chats, where Kotlin's replay reads group chat alone
/// (`replayCustodiedGroupFrames`, `MeshManager.kt:1739-1764` at knit-next `cbf2a487`) and loses a roster frame whose unit
/// failed. A replay is idempotent and never undoes a later state: a departure already recorded writes nothing, an old leave
/// changes nothing after its sender's rejoin or a newer frame of theirs, a blocked sender's leave counts once, and a frame
/// that changes nothing counts no drop at any start.
@Suite struct MeshEngineGroupRosterReplayTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private var now: Int64 { EngineFixture.start }
    private static let hour: Int64 = 3_600_000

    /// The iPhone over `stores`, with the switch as `ratchet` says, in a group with Alice and Carol, both pinned.
    private func member(of stores: MeshStores, ratchet: Bool) throws -> (EngineFixture, GroupInfo) {
        let fixture = EngineFixture(me, stores: stores, configuration: MeshConfiguration(ratchet: ratchet))
        try fixture.pin(alice)
        try fixture.pin(carol)
        return (fixture, fixture.holdGroup(with: [alice, carol]))
    }

    /// The same iPhone launched again over `stores` at `wall`, with the switch as `ratchet` says.
    private func relaunched(_ stores: MeshStores, ratchet: Bool, wall: Int64) -> EngineFixture {
        EngineFixture(
            me, stores: stores, configuration: MeshConfiguration(ratchet: ratchet), wall: wall, seed: UInt64(truncatingIfNeeded: wall))
    }

    private func leftNotices(_ fixture: EngineFixture, _ group: GroupInfo) -> Int {
        fixture.stores.messages.messages(in: group.id).count { $0.kind == .memberLeft }
    }

    @Test func anOldLeaveReplayedAfterItsSendersRejoinLeavesThemOnTheRoster() throws {
        let stores = MeshStores.inMemory()
        let (fixture, group) = try member(of: stores, ratchet: true)
        fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
        // Her rejoin reaches us point to point, so no custody holds it: only the rejoin's own clock stands against the leave.
        let back = RelayEnvelope(
            type: .groupUpdate, id: "carol-back", senderId: carol.nodeId.string, sentAt: now + 2, group: group, payload: [])
        fixture.deliver(try carol.signed(back, relay: false), from: carol)
        #expect(fixture.roster(of: group).departed.isEmpty && !stores.custody.contains("carol-back"))
        let restarted = relaunched(stores, ratchet: true, wall: now + 60_000)
        #expect(restarted.roster(of: group).departed.isEmpty, "the leave is no newer than her rejoin")
        #expect(leftNotices(restarted, group) == 1 && restarted.engine.dropped.isEmpty)
        #expect(restarted.engine.drainEvents().allSatisfy { $0 != .groupChanged(group.id) })
    }

    /// The departure's unit fails, then Carol's newer chat arrives and is delivered, which would have brought her back had
    /// the leave stood. The leave replayed after it must not take her off: her own newer frame outlives it.
    @Test(arguments: StoreKind.allCases)
    func aLostLeaveOutlivedByItsSendersNewerFrameIsNotReplayed(kind: StoreKind) throws {
        let directory = scratchDirectory("leave-outlived")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingGroupWrites(blobs: directory, failures: ReportedFailures().record)
        let (fixture, group) = try member(of: stores, ratchet: true)
        refusing.refusesWrites = true
        fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
        refusing.refusesWrites = false
        fixture.deliver(try carol.groupMessage("still here", in: group, to: [me, alice], id: "carol-chat", sentAt: now + 2), from: carol)
        #expect(stores.messages.message("carol-chat") != nil && stores.custody.contains("carol-chat"))
        let restarted = relaunched(stores, ratchet: true, wall: now + 60_000)
        #expect(restarted.roster(of: group).departed.isEmpty)
        #expect(leftNotices(restarted, group) == 0)
    }

    @Test func aReplayedDepartureAlreadyRecordedWritesNothingAddsNoNoticeAndCountsNoDrop() throws {
        let stores = MeshStores.inMemory()
        let (fixture, group) = try member(of: stores, ratchet: true)
        fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
        let recorded = try #require(stores.groups.group(group.id))
        let restarted = relaunched(stores, ratchet: true, wall: now + 60_000)
        #expect(stores.groups.group(group.id) == recorded)
        #expect(leftNotices(restarted, group) == 1 && restarted.engine.dropped.isEmpty)
        #expect(restarted.engine.drainEvents().allSatisfy { $0 != .groupChanged(group.id) })
        #expect(!restarted.log.all.contains { $0.contains("carol-leaves") && !$0.hasPrefix("debug ") }, "nothing above debug")
    }

    /// A roster frame whose verdict was a refusal meets it again at every start, and counts it only at its first.
    @Test func aReplayedRefusalCountsOnlyAtItsFirstVerdict() throws {
        let stores = MeshStores.inMemory()
        let (fixture, group) = try member(of: stores, ratchet: true)
        // A roster smuggling Dave in under the group's id: refused, since the id is not its hash.
        let smuggled = GroupInfo(
            id: group.id, members: group.members + [dave.nodeId.string], createdBy: group.createdBy, departed: nil)
        fixture.deliver(try carol.groupUpdate(smuggled, id: "smuggled", sentAt: now + 1), from: carol)
        fixture.deliver(
            try carol.signed(
                RelayEnvelope(type: .groupLeave, id: "garbled", senderId: carol.nodeId.string, sentAt: now + 2, payload: [0xFF])),
            from: carol)
        #expect(fixture.engine.dropped[.rosterRefused] == 1 && fixture.engine.dropped[.undecodable] == 1)
        #expect(stores.custody.contains("smuggled") && stores.custody.contains("garbled"))
        let restarted = relaunched(stores, ratchet: true, wall: now + 60_000)
        #expect(restarted.engine.dropped.isEmpty)
        #expect(restarted.roster(of: group).members == Set(group.members))
    }

    /// A blocked sender's leave counts `.blocked` at its first verdict alone; once unblocked, the next start applies it, as
    /// it delivers a group message from the block (ADR 2026-10.5wgg), where Android keeps the member on its roster.
    @Test func aBlockedSendersLeaveCountsOnceAndAppliesAtTheStartAfterTheUnblock() throws {
        let stores = MeshStores.inMemory()
        let (fixture, group) = try member(of: stores, ratchet: false)
        fixture.engine.block(carol.nodeId)
        fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
        #expect(fixture.engine.dropped[.blocked] == 1 && fixture.roster(of: group).departed.isEmpty)
        let blocked = relaunched(stores, ratchet: false, wall: now + 60_000)
        #expect(blocked.engine.dropped.isEmpty, "a start while blocked meets the gate and counts nothing")
        #expect(blocked.roster(of: group).departed.isEmpty)
        blocked.engine.unblock(carol.nodeId)
        let unblocked = relaunched(stores, ratchet: false, wall: now + 120_000)
        #expect(unblocked.roster(of: group).departed == [carol.nodeId.string])
    }

    @Test(arguments: StoreKind.allCases)
    func aRenameLostToAFailedUnitAppliesAtTheNextStart(kind: StoreKind) throws {
        let directory = scratchDirectory("rename-lost")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let (fixture, group) = try member(of: stores, ratchet: false)
        refusing.refusesSaves = true
        fixture.deliver(
            try carol.groupUpdate(roster([me, alice, carol], name: "Hike", createdBy: alice), id: "rename", sentAt: now + 1), from: carol)
        refusing.refusesSaves = false
        #expect(stores.groups.group(group.id)?.name.isEmpty == true && fixture.engine.dropped[.storeRefused] == 1)
        let restarted = relaunched(stores, ratchet: false, wall: now + 60_000)
        #expect(stores.groups.group(group.id)?.name == "Hike")
        #expect(stores.messages.messages(in: group.id).count { $0.kind == .groupRenamed } == 1)
        #expect(restarted.engine.drainEvents().contains(.groupChanged(group.id)))
        let again = relaunched(stores, ratchet: false, wall: now + 120_000)
        #expect(stores.messages.messages(in: group.id).count { $0.kind == .groupRenamed } == 1, "applied once")
        #expect(again.engine.drainEvents().allSatisfy { $0 != .groupChanged(group.id) })
    }

    /// Two renames stamped in the same millisecond, each taken at its first verdict, the second winning the tie as on
    /// Android: replayed at every start, neither may trade places with the other or write a notice (phase P7a).
    @Test func twoRenamesOnOneClockChangeNothingAtLaterStarts() throws {
        let stores = MeshStores.inMemory()
        let (fixture, group) = try member(of: stores, ratchet: true)
        fixture.deliver(
            try alice.groupUpdate(roster([me, alice, carol], name: "Hike", createdBy: alice), id: "r-alice", sentAt: now + 1), from: alice)
        fixture.deliver(
            try carol.groupUpdate(roster([me, alice, carol], name: "Swim", createdBy: alice), id: "r-carol", sentAt: now + 1), from: carol)
        let settled = try #require(stores.groups.group(group.id))
        #expect(settled.name == "Swim", "a first verdict's tie goes to the incoming frame")
        let notices = stores.messages.messages(in: group.id).count { $0.kind == .groupRenamed }
        for wall in [now + 60_000, now + 120_000] {
            let restarted = relaunched(stores, ratchet: true, wall: wall)
            #expect(stores.groups.group(group.id) == settled, "the row at the start at \(wall)")
            #expect(stores.messages.messages(in: group.id).count { $0.kind == .groupRenamed } == notices)
            #expect(restarted.engine.drainEvents().allSatisfy { $0 != .groupChanged(group.id) })
        }
    }

    /// The same tie where only the loser is in our custody: the winner reached us point to point. Replayed, the loser
    /// must not take the row back, nor rewrite the notice the two share (its id is the group's and the clock's).
    @Test func aTiedRenameReplayedAloneDoesNotTakeTheRowBack() throws {
        let stores = MeshStores.inMemory()
        let (fixture, group) = try member(of: stores, ratchet: true)
        fixture.deliver(
            try carol.groupUpdate(roster([me, alice, carol], name: "Swim", createdBy: alice), id: "r-carol", sentAt: now + 1), from: carol)
        let hike = RelayEnvelope(
            type: .groupUpdate,
            id: "r-alice",
            senderId: alice.nodeId.string,
            sentAt: now + 1,
            group: roster([me, alice, carol], name: "Hike", createdBy: alice),
            payload: []
        )
        fixture.deliver(try alice.signed(hike, relay: false), from: alice)
        let settled = try #require(stores.groups.group(group.id))
        #expect(settled.name == "Hike" && !stores.custody.contains("r-alice"))
        let notices = stores.messages.messages(in: group.id).filter { $0.kind == .groupRenamed }
        let restarted = relaunched(stores, ratchet: true, wall: now + 60_000)
        #expect(stores.groups.group(group.id) == settled)
        #expect(stores.messages.messages(in: group.id).filter { $0.kind == .groupRenamed } == notices)
        #expect(restarted.engine.drainEvents().allSatisfy { $0 != .groupChanged(group.id) })
    }

    /// With the switch on, the hourly replay recovers a lost departure without a restart; with it off, only a start does.
    @Test func withTheSwitchOnTheHourlyReplayRecoversALostDeparture() throws {
        for ratchet in [true, false] {
            let directory = scratchDirectory("departure-lost-hourly")
            defer { try? FileManager.default.removeItem(at: directory) }
            let (stores, refusing) = try StoreKind.memory.storesRefusingGroupWrites(blobs: directory, failures: ReportedFailures().record)
            let (fixture, group) = try member(of: stores, ratchet: ratchet)
            refusing.refusesWrites = true
            fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
            refusing.refusesWrites = false
            fixture.advance(Self.hour + 1)
            #expect(fixture.roster(of: group).departed == (ratchet ? [carol.nodeId.string] : []), "switch \(ratchet)")
        }
    }
}
