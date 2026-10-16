import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The group form received in the mesh across a restart, over the database with the switch on (ADR 2026-10.5sk9, phase
/// P6a2): the park dies with the process and the first sight's replay opens its seed, with or without a session held,
/// and the start opens the DMs before the group frames, so a seed whose unit failed adopts before its frames ask again.
@Suite struct MeshEngineGroupRatchetRestartTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)

    private var now: Int64 { EngineFixture.start }

    /// knit-next's `SessionLabTest` restart with a parked seed, receive half: the park dies with the process, the start's
    /// replay leaves the seed in custody unopened, and the group's first sight opens it from there, over the database.
    @Test func aRestartWithAParkedSeedOpensItAtTheGroupsFirstSight() throws {
        let directory = scratchDirectory("parked-restart")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, _) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let keychain = KeptSecretStore(me.keys.storedForm)
        let fixture = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let group = roster([me, alice], createdBy: alice)
        let author = GroupFormAuthor(android, in: group.id)
        let prekey = try fixture.ourPrekey()
        // A DM before the seed: the first sight's replay meets both, oldest first, and the DM stops at its row.
        fixture.deliver(try android.dm("hello", to: me, prekey: prekey, id: "dm-1", sentAt: now - 1), from: android)
        fixture.deliver(try author.seedDm(to: me, prekey: prekey, id: "seed-1", sentAt: now), from: android)
        #expect(fixture.engine.groupCounts.groupSeedsHeld == 1)
        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 60_000, seed: 8)
        #expect(restarted.engine.pendingGroupKeys.isEmpty && restarted.recvChains(group.id, from: alice).isEmpty)
        restarted.deliver(try author.frame(group, id: "g-first", body: "after the restart", sentAt: now + 60_000), from: alice)
        #expect(restarted.recvChains(group.id, from: alice).count == 1, "the first sight's replay opened the seed")
        #expect(restarted.stores.messages.message("g-first")?.body == "after the restart")
        #expect(restarted.engine.dropped[.groupRatchetNoKey] == nil && restarted.engine.dropped[.ratchetDuplicate] == nil)
        #expect(restarted.controls(to: android).contains { $0.ctl == MessageContent.Control.groupKeyAck })
    }

    /// The same restart when the parked seed was Android's first DM to us, so it carries the init and no session is held:
    /// the abandoned open left none, and the first sight's replay, which holds the era, still founds one from the init.
    @Test func aRestartWithAParkedFirstContactSeedFoundsTheSessionAtTheGroupsFirstSight() throws {
        let directory = scratchDirectory("parked-first-contact")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, _) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let keychain = KeptSecretStore(me.keys.storedForm)
        let fixture = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let group = roster([me, alice], createdBy: alice)
        let author = GroupFormAuthor(android, in: group.id)
        fixture.deliver(try author.seedDm(to: me, prekey: try fixture.ourPrekey(), id: "seed-1", sentAt: now), from: android)
        #expect(fixture.engine.groupCounts.groupSeedsHeld == 1)
        #expect(stores.ratchet.records(of: alice.nodeId).session == nil, "the abandoned open founded nothing")
        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 60_000, seed: 8)
        #expect(stores.ratchet.records(of: alice.nodeId).session == nil, "the start's replay left the seed unopened")
        restarted.deliver(try author.frame(group, id: "g-first", body: "first contact", sentAt: now + 60_000), from: alice)
        #expect(stores.ratchet.records(of: alice.nodeId).session != nil, "the init founded the session")
        #expect(restarted.recvChains(group.id, from: alice).count == 1, "the first sight's replay opened the seed")
        #expect(restarted.stores.messages.message("g-first")?.body == "first contact")
        #expect(restarted.controls(to: android).contains { $0.ctl == MessageContent.Control.groupKeyAck })
    }

    /// The start's order: the DM replay runs before the group replay, so a seed whose unit failed before we stopped adopts
    /// first and its instant replay opens the frames it keys. The other way round, those frames would count as keyless
    /// again, and three of them would ask Android for a key it already sent.
    @Test func aRestartAdoptsASeedWhoseUnitFailedBeforeItsFramesCanAskForTheKeyAgain() throws {
        let directory = scratchDirectory("restart-seed-first")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try StoreKind.sql.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let keychain = KeptSecretStore(me.keys.storedForm)
        let fixture = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        let prekey = try fixture.ourPrekey()
        fixture.deliver(try android.dm("hello", to: me, prekey: prekey, id: "dm-1", sentAt: now - 1), from: android)
        refusing.refusesWrites = true
        fixture.deliver(try author.seedDm(to: me, prekey: prekey, id: "seed-1", sentAt: now), from: android)
        refusing.refusesWrites = false
        #expect(fixture.engine.dropped[.storeRefused] == 1)
        let frames = ["g-1", "g-2", "g-3"]
        for (offset, id) in frames.enumerated() {
            fixture.deliver(try author.frame(group, id: id, body: id, sentAt: now + 1 + Int64(offset)), from: alice)
        }
        #expect(fixture.engine.dropped[.groupRatchetNoKey] == 3)
        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 60_000, seed: 8)
        #expect(restarted.recvChains(group.id, from: alice).count == 1, "the DM replay adopted the seed")
        #expect(frames.allSatisfy { restarted.stores.messages.message($0)?.body == $0 }, "and its instant replay opened every frame")
        #expect(restarted.engine.dropped[.groupRatchetNoKey] == nil, "none counted keyless again")
        #expect(!restarted.controls(to: android).contains { $0.ctl == MessageContent.Control.groupKeyRequest }, "nothing asked")
        #expect(restarted.controls(to: android).contains { $0.ctl == MessageContent.Control.groupKeyAck })
    }
}
