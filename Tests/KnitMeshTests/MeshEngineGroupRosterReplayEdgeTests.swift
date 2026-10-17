import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The replayed leave's edges (ADR 2026-10.5sk9, phase P7a, after its two reviews): the evidence that outlives a lost leave
/// when custody has evicted it, what the recovery puts on the air against a start whose departure committed, and the
/// leaver, an Android member, reading nothing we send after it.
@Suite struct MeshEngineGroupRosterReplayEdgeTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }
    private static let hour: Int64 = 3_600_000

    /// The crypto review of P7a: Carol's leave is lost, her newer chat is delivered, then the group's custody bucket evicts
    /// that chat, oldest first, while the leave, which names no group, stays. Her row in the thread still outlives the leave,
    /// so the start keeps her, and our chain and her outbox row stand.
    @Test(arguments: StoreKind.allCases)
    func aLostLeaveWhoseOutlivingFrameCustodyEvictedIsStillNotReplayed(kind: StoreKind) throws {
        let directory = scratchDirectory("leave-outlived-evicted")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingRows(
            blobs: directory, failures: ReportedFailures().record, custodyLimits: CustodyLimits(maxPerGroup: 3))
        let keychain = KeptSecretStore(me.keys.storedForm)
        let fixture = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        try fixture.pin(try AndroidPeer(alice))
        try fixture.pin(try AndroidPeer(carol))
        let group = fixture.holdGroup(with: [alice, carol])
        _ = try #require(fixture.engine.sendGroupMessage("minted", to: group.id))
        refusing.refusesSaves = true
        fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
        refusing.refusesSaves = false
        fixture.deliver(try carol.groupMessage("still here", in: group, to: [me, alice], id: "carol-chat", sentAt: now + 2), from: carol)
        for index in 0..<3 {
            fixture.deliver(
                try alice.groupMessage("busy \(index)", in: group, to: [me, carol], id: "alice-\(index)", sentAt: now + 3 + Int64(index)),
                from: alice)
        }
        #expect(stores.messages.message("carol-chat") != nil)
        #expect(!stores.custody.contains("carol-chat") && stores.custody.contains("carol-leaves"), "evicted from the group's bucket")
        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 60_000, seed: 61)
        #expect(restarted.roster(of: group).departed.isEmpty)
        #expect(stores.messages.messages(in: group.id).allSatisfy { $0.kind != .memberLeft })
        _ = try #require(restarted.engine.sendGroupMessage("with carol", to: group.id))
        let held = stores.groupRatchet
        #expect(held.sendChains(group.id).map(\.epoch) == [1], "not retired")
        #expect(Set(held.keySends(group.id).map(\.member)) == [alice.nodeId, carol.nodeId], "Carol is still seeded")
    }

    /// Both reviews of P7a's fixes: the same lost leave, its outliving frame evicted from custody, at a start whose read of
    /// the group's thread fails. That read answers no rows on its fallback, which would depart Carol; it holds the leave back
    /// instead, and the next start, which reads, keeps her too.
    @Test(arguments: StoreKind.allCases)
    func aLostLeaveWhoseThreadCannotBeReadIsHeldBack(kind: StoreKind) throws {
        let directory = scratchDirectory("leave-thread-unread")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingRows(
            blobs: directory, failures: ReportedFailures().record, custodyLimits: CustodyLimits(maxPerGroup: 3))
        let keychain = KeptSecretStore(me.keys.storedForm)
        let fixture = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        try fixture.pin(try AndroidPeer(alice))
        try fixture.pin(try AndroidPeer(carol))
        let group = fixture.holdGroup(with: [alice, carol])
        _ = try #require(fixture.engine.sendGroupMessage("minted", to: group.id))
        refusing.refusesSaves = true
        fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
        refusing.refusesSaves = false
        fixture.deliver(try carol.groupMessage("still here", in: group, to: [me, alice], id: "carol-chat", sentAt: now + 2), from: carol)
        for index in 0..<3 {
            fixture.deliver(
                try alice.groupMessage("busy \(index)", in: group, to: [me, carol], id: "alice-\(index)", sentAt: now + 3 + Int64(index)),
                from: alice)
        }
        #expect(!stores.custody.contains("carol-chat") && stores.custody.contains("carol-leaves"), "evicted from the group's bucket")
        refusing.failsThreadReads = true
        let unread = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 60_000, seed: 62)
        refusing.failsThreadReads = false
        #expect(unread.roster(of: group).departed.isEmpty, "held back, not departed on the fallback")
        #expect(stores.groupRatchet.sendChains(group.id).map(\.epoch) == [1])
        let read = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 120_000, seed: 63)
        #expect(read.roster(of: group).departed.isEmpty, "her row outlives the leave")
        #expect(stores.messages.messages(in: group.id).allSatisfy { $0.kind != .memberLeft })
    }

    /// The blobs review of P7a: a lost departure recovered at start, against a control whose departure committed at its
    /// first verdict, over the same history otherwise. With a peer linked, both put the same frames on the air, the start
    /// writes no custody row, and with the switch on the hourly step adds the same frames and no drop.
    @Test(arguments: StoreKind.allCases, [false, true])
    func aLostDepartureIsRecoveredAtStartWithNothingMoreOnTheAir(kind: StoreKind, ratchet: Bool) throws {
        let directory = scratchDirectory("departure-lost-air")
        defer { try? FileManager.default.removeItem(at: directory) }
        func history(lost: Bool) throws -> (MeshStores, GroupInfo) {
            let (stores, refusing) = try kind.storesRefusingGroupWrites(
                blobs: directory.appending(path: lost ? "lost" : "control"), failures: ReportedFailures().record)
            let fixture = EngineFixture(me, stores: stores, configuration: MeshConfiguration(ratchet: ratchet))
            try fixture.pin(alice)
            try fixture.pin(carol)
            let group = fixture.holdGroup(with: [alice, carol])
            refusing.refusesWrites = lost
            fixture.deliver(try carol.groupLeave(group.id, id: "carol-leaves", sentAt: now + 1), from: carol)
            refusing.refusesWrites = false
            #expect(fixture.roster(of: group).departed.isEmpty == lost)
            return (stores, group)
        }
        let (lostStores, group) = try history(lost: true)
        let (controlStores, _) = try history(lost: false)
        let wall = now + 60_000
        let custodied = lostStores.custody.liveIds(now: wall)
        #expect(custodied == controlStores.custody.liveIds(now: wall))
        func relaunch(_ stores: MeshStores) -> EngineFixture {
            EngineFixture(me, stores: stores, configuration: MeshConfiguration(ratchet: ratchet), wall: wall, seed: 71)
        }
        let restarted = relaunch(lostStores)
        let control = relaunch(controlStores)
        #expect(restarted.roster(of: group) == control.roster(of: group))
        #expect(restarted.roster(of: group).departed == [carol.nodeId.string])
        #expect(lostStores.custody.liveIds(now: wall) == custodied, "the start wrote no custody row")
        restarted.link(alice)
        control.link(alice)
        func air(_ fixture: EngineFixture) -> [String] {
            fixture.transport.written.map { written in
                "\(written.envelope.type.rawValue) \(written.envelope.id) \(written.to?.string ?? "*") \(written.envelope.payload)"
            }
        }
        #expect(air(restarted).contains { $0.hasPrefix("digest") || $0.contains(alice.nodeId.string) }, "the link wrote something")
        #expect(air(restarted) == air(control), "the same frames as a start whose departure committed")
        #expect(restarted.engine.dropped == control.engine.dropped)
        if ratchet {
            let dropped = restarted.engine.dropped
            let (before, controlBefore) = (air(restarted).count, air(control).count)
            restarted.advance(Self.hour + 1)
            control.advance(Self.hour + 1)
            #expect(air(restarted).dropFirst(before) == air(control).dropFirst(controlBefore), "the hourly step adds the same")
            #expect(restarted.engine.dropped == dropped, "and no drop")
        }
        if !ratchet {
            #expect(lostStores.groupRatchet.holdings(of: group.id) == .empty, "the switch never wrote the group store")
        }
    }
}
