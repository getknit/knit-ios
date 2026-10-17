import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The roster's units and the group form's state (ADR 2026-10.5sk9, phase P6b; `GroupRepository.recordDeparture`,
/// `recordRejoin` and `leave`, `GroupRepository.kt:108-194`, at knit-next `cbf2a487`): a departure retires our send chains
/// and drops the leaver's outbox row with the roster's shrink, our leave purges the group's state and keeps its epoch number,
/// and each of them stands whole or not at all, over both store kinds. A rejoin retires whatever the switch says, and a
/// departure lost to a failed unit is recovered by the next start's replay (phase P7a), where Android loses it.
@Suite struct MeshEngineGroupRosterUnitTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }

    /// The iPhone with the switch on over `kind`'s stores, whose group store refuses its writes when told to, Alice and Carol
    /// pinned as Android members, and the group's epoch 1 minted and sent to both.
    private func minted(_ kind: StoreKind, _ directory: URL) throws -> Minted {
        let (stores, refusing) = try kind.storesRefusingGroupWrites(blobs: directory, failures: ReportedFailures().record)
        let keychain = KeptSecretStore(me.keys.storedForm)
        let fixture = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        try fixture.pin(try AndroidPeer(alice))
        try fixture.pin(try AndroidPeer(carol))
        let group = fixture.holdGroup(with: [alice, carol])
        _ = try #require(fixture.engine.sendGroupMessage("minted", to: group.id))
        #expect(fixture.stores.groupRatchet.keySends(group.id).count == 2)
        return Minted(fixture: fixture, refusing: refusing, group: group, keychain: keychain)
    }

    /// The same iPhone launched again over `rig`'s stores and keychain at `wall`, with the switch as `ratchet` says: a Debug
    /// build's `-ratchet on|off` takes effect at launch.
    private func relaunched(_ rig: Minted, ratchet: Bool, wall: Int64) throws -> EngineFixture {
        try EngineFixture.ratcheting(
            me,
            stores: rig.fixture.stores,
            keychain: rig.keychain,
            wall: wall,
            configuration: MeshConfiguration(ratchet: ratchet),
            seed: UInt64(truncatingIfNeeded: wall)
        )
    }

    /// What ``minted(_:_:)`` sets up.
    private struct Minted {
        let fixture: EngineFixture
        let refusing: RefusingGroupRatchetWrites
        let group: GroupInfo
        let keychain: KeptSecretStore
    }

    @Test(arguments: StoreKind.allCases)
    func aDepartureRetiresOurChainsAndDropsTheLeaversOutboxRowWithTheRosterShrink(kind: StoreKind) throws {
        let directory = scratchDirectory("departure-unit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try minted(kind, directory)
        let fixture = rig.fixture
        let group = rig.group
        fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
        #expect(fixture.roster(of: group).departed == [carol.nodeId.string])
        let held = fixture.stores.groupRatchet
        #expect(held.sendChains(group.id).isEmpty && held.sendChain(group.id)?.epoch == 1, "retired, its number kept")
        #expect(held.keySend(group.id, member: carol.nodeId) == nil && held.keySend(group.id, member: alice.nodeId) != nil)
        _ = try #require(fixture.engine.sendGroupMessage("after", to: group.id))
        #expect(held.sendChains(group.id).first?.epoch == 2 && held.keySends(group.id).map(\.member) == [alice.nodeId])
    }

    @Test(arguments: StoreKind.allCases)
    func aDepartureWhoseUnitFailsChangesNothing(kind: StoreKind) throws {
        let directory = scratchDirectory("departure-unit-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try minted(kind, directory)
        let fixture = rig.fixture
        let refusing = rig.refusing
        let group = rig.group
        refusing.refusesWrites = true
        fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
        refusing.refusesWrites = false
        #expect(fixture.roster(of: group).departed.isEmpty, "the roster's shrink went with the retire")
        #expect(fixture.stores.messages.messages(in: group.id).allSatisfy { $0.kind != .memberLeft }, "and the notice")
        #expect(fixture.stores.groupRatchet.sendChains(group.id).map(\.epoch) == [1])
        #expect(fixture.engine.dropped[.storeRefused] == 1)
    }

    @Test(arguments: StoreKind.allCases)
    func ourLeavePurgesTheGroupsStateAndARecreatedGroupNumbersPastIt(kind: StoreKind) throws {
        let directory = scratchDirectory("leave-unit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try minted(kind, directory)
        let fixture = rig.fixture
        let group = rig.group
        #expect(fixture.engine.leaveGroup(group.id))
        let holdings = fixture.stores.groupRatchet.holdings(of: group.id)
        #expect(
            fixture.stores.groupRatchet.keySends(group.id).isEmpty && holdings.recvChains.isEmpty
                && fixture.stores.groupRatchet.sendChains(group.id).isEmpty)
        #expect(fixture.stores.groupRatchet.sendChain(group.id)?.epoch == 1, "the number survives the purge")
        let again = try #require(fixture.engine.createGroup(with: [alice.nodeId, carol.nodeId]))
        #expect(again.id == group.id)
        _ = try #require(fixture.engine.sendGroupMessage("again", to: group.id))
        #expect(fixture.stores.groupRatchet.sendChains(group.id).first?.epoch == 2, "knit-next ADR 2026-10.xgwj")
    }

    @Test(arguments: StoreKind.allCases)
    func aLeaveWhoseUnitFailsLeavesUsInTheGroup(kind: StoreKind) throws {
        let directory = scratchDirectory("leave-unit-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try minted(kind, directory)
        let fixture = rig.fixture
        let refusing = rig.refusing
        let group = rig.group
        refusing.refusesWrites = true
        #expect(!fixture.engine.leaveGroup(group.id))
        refusing.refusesWrites = false
        #expect(fixture.stores.groups.group(group.id)?.hasLeft == false && !fixture.stores.messages.messages(in: group.id).isEmpty)
        #expect(fixture.stores.groupRatchet.keySends(group.id).count == 2, "the purge went with the tombstone")
    }

    @Test(arguments: StoreKind.allCases)
    func aRejoinWhoseUnitFailsIsNotDeliveredAndStampsNoFloor(kind: StoreKind) throws {
        let directory = scratchDirectory("rejoin-unit-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try minted(kind, directory)
        let fixture = rig.fixture
        let refusing = rig.refusing
        let group = rig.group
        fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
        _ = try #require(fixture.engine.sendGroupMessage("without carol", to: group.id))
        refusing.refusesWrites = true
        fixture.deliver(try carol.groupMessage("back", in: group, to: [me, alice], id: "carol-back", sentAt: now + 2), from: carol)
        refusing.refusesWrites = false
        #expect(fixture.roster(of: group).departed == [carol.nodeId.string] && fixture.stores.messages.message("carol-back") == nil)
        #expect(fixture.engine.groupFloors.rejoins.isEmpty && fixture.engine.dropped[.storeRefused] == 1)
        fixture.deliver(try carol.groupUpdate(group, id: "carol-again", sentAt: now + 3), from: carol)
        #expect(fixture.roster(of: group).departed.isEmpty && fixture.stores.groupRatchet.sendChains(group.id).isEmpty, "rekeyed now")
    }

    /// The crypto review of P6b: with the switch on Carol departs and we mint epoch 2 for Alice alone; with it off Carol
    /// rejoins; with it on again the next send must not reuse epoch 2, whose seed the flush would hand Carol along with every
    /// frame she missed. The rejoin retires with the switch off and stamps no floor, which is the switch's.
    @Test(arguments: StoreKind.allCases)
    func aRejoinSeenWithTheSwitchOffRetiresAChainTheSwitchMinted(kind: StoreKind) throws {
        let directory = scratchDirectory("rejoin-switch-off")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try minted(kind, directory)
        let group = rig.group
        rig.fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
        _ = try #require(rig.fixture.engine.sendGroupMessage("without carol", to: group.id))
        #expect(rig.fixture.stores.groupRatchet.sendChains(group.id).map(\.epoch) == [2])
        let off = try relaunched(rig, ratchet: false, wall: now + 60_000)
        off.deliver(try carol.groupMessage("back", in: group, to: [me, alice], id: "carol-back", sentAt: now + 2), from: carol)
        #expect(off.roster(of: group).departed.isEmpty && off.stores.messages.message("carol-back") != nil)
        #expect(off.stores.groupRatchet.sendChains(group.id).isEmpty, "retired with the switch off")
        #expect(off.engine.groupFloors.rejoins.isEmpty, "and no floor stamped")
        let on = try relaunched(rig, ratchet: true, wall: now + 120_000)
        _ = try #require(on.engine.sendGroupMessage("with carol", to: group.id))
        let held = on.stores.groupRatchet
        #expect(held.sendChains(group.id).map(\.epoch) == [3], "minted past the epoch Carol was out for")
        #expect(held.keySend(group.id, member: carol.nodeId)?.sentEpoch == 3, "Carol's seed is the new epoch's")
        #expect(held.keySend(group.id, member: alice.nodeId)?.sentEpoch == 3)
    }

    /// Both reviews of P6b: a `groupleave` whose departure unit fails stays in our custody and digest, so nobody serves it
    /// to us again. Kotlin's replay takes only group chat frames (`MeshManager.kt:1739-1764`) and the departure is lost; the
    /// start's replay here takes our custodied leave too (phase P7a), so after the restart Carol is departed and the next
    /// mint seeds Alice alone.
    @Test(arguments: StoreKind.allCases)
    func aDepartureLostToAFailedUnitIsRecoveredByTheNextStartsReplay(kind: StoreKind) throws {
        let directory = scratchDirectory("departure-lost")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try minted(kind, directory)
        let group = rig.group
        rig.refusing.refusesWrites = true
        rig.fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
        rig.refusing.refusesWrites = false
        #expect(rig.fixture.stores.custody.liveIds(now: now + 1).contains("carol-leaves"), "custodied before the unit failed")
        #expect(rig.fixture.roster(of: group).departed.isEmpty, "lost for now")
        let restarted = try relaunched(rig, ratchet: true, wall: now + 60_000)
        #expect(restarted.roster(of: group).departed == [carol.nodeId.string])
        #expect(restarted.stores.messages.messages(in: group.id).count { $0.kind == .memberLeft } == 1)
        #expect(restarted.engine.dropped.isEmpty, "the replay's departure counts nothing")
        let held = restarted.stores.groupRatchet
        #expect(held.sendChains(group.id).isEmpty && held.keySend(group.id, member: carol.nodeId) == nil, "retired with the shrink")
        restarted.transport.clear()
        _ = try #require(restarted.engine.sendGroupMessage("without carol", to: group.id))
        #expect(held.sendChains(group.id).map(\.epoch) == [2] && held.keySends(group.id).map(\.member) == [alice.nodeId])
        #expect(restarted.chats(to: carol).isEmpty, "no seed to Carol")
        #expect(restarted.chats(to: alice).count == 1, "Alice's seed")
    }
}
