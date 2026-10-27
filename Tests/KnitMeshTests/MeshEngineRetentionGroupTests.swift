import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Retention in a group request (knit-ios #21): a stranger's group that names us, where no one we know has posted. The
/// start's replay of custodied group frames brings back none of the trimmed messages, and the count trim keeps each
/// member's newest act, so a leave replayed from custody after its first verdict was lost does not depart a member who
/// posted since (ADR 2026-10.5sk9's phase P7a, the crypto review's non-blocking finding).
@Suite struct MeshEngineRetentionGroupTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private var now: Int64 { EngineFixture.start }
    private var sweep: Int64 { MeshConfiguration().sweepMilliseconds }

    @Test(arguments: StoreKind.allCases)
    func theStartsReplayOfCustodiedGroupFramesBringsBackNoTrimmedMessage(kind: StoreKind) throws {
        let directory = scratchDirectory("retention-group-replay")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, _) = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let fixture = EngineFixture(me, stores: stores)
        try fixture.pin(alice)
        try fixture.pin(carol)
        let group = fixture.holdGroup(with: [alice, carol])
        for index in 0..<55 {
            fixture.deliver(
                try alice.groupMessage(
                    "busy \(index)", in: group, to: [me, carol], id: frameIdOf("alice-\(index)"), sentAt: now + Int64(index)),
                from: alice)
        }
        let requests = announced(fixture.engine.drainEvents()).map(\.isRequest)
        #expect(requests.count == 55 && !requests.contains(false))
        fixture.advance(sweep)
        let trimmed = (0..<5).map { frameIdOf("alice-\($0)") }
        #expect(stores.messages.messages(in: group.id).count == 50)
        #expect(trimmed.allSatisfy { stores.custody.contains($0) && stores.messages.contains($0) }, "carried, and remembered")

        let restarted = EngineFixture(me, stores: stores, wall: fixture.clock.wallMilliseconds(), seed: 61)
        #expect(stores.messages.messages(in: group.id).count == 50, "the replay brought none back")
        #expect(announced(restarted.engine.drainEvents()).isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func aMembersNewestPostOutsideTheNewestFiftyStillOutlivesTheirLostLeave(kind: StoreKind) throws {
        let directory = scratchDirectory("retention-group-leave")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingRows(
            blobs: directory, failures: ReportedFailures().record, custodyLimits: CustodyLimits(maxPerGroup: 3))
        let keychain = KeptSecretStore(me.keys.storedForm)
        let fixture = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        try fixture.pin(try AndroidPeer(alice))
        try fixture.pin(try AndroidPeer(carol))
        let group = fixture.holdGroup(with: [alice, carol])
        refusing.refusesSaves = true
        fixture.deliver(try carol.groupLeave(group.id, id: frameIdOf("carol-leaves"), sentAt: now + 1), from: carol)
        refusing.refusesSaves = false
        fixture.deliver(
            try carol.groupMessage("still here", in: group, to: [me, alice], id: frameIdOf("carol-chat"), sentAt: now + 2), from: carol)
        for index in 0..<55 {
            fixture.deliver(
                try alice.groupMessage(
                    "busy \(index)", in: group, to: [me, carol], id: frameIdOf("alice-\(index)"), sentAt: now + 3 + Int64(index)),
                from: alice)
        }
        #expect(
            !stores.custody.contains(frameIdOf("carol-chat")) && stores.custody.contains(frameIdOf("carol-leaves")),
            "evicted from the group's bucket, while the leave, in none, stays")

        fixture.advance(sweep)
        #expect((0..<5).allSatisfy { stores.messages.message(frameIdOf("alice-\($0)")) == nil }, "the request was trimmed")
        #expect(stores.messages.message(frameIdOf("carol-chat")) != nil, "Carol's newest act stays, past the newest 50")
        #expect(stores.messages.messages(in: group.id).count == 51)

        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + sweep + 60_000, seed: 61)
        #expect(restarted.roster(of: group).departed.isEmpty, "her row outlives the replayed leave")
        #expect(stores.messages.messages(in: group.id).allSatisfy { $0.kind != .memberLeft })
    }
}
