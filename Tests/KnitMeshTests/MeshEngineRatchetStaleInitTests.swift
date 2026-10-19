import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A frame riding an init that a session of ours answered before a reinstall lost it, refused, on one engine and an
/// Android phone (ADR 2026-10.wcex): the edges `RatchetRestoreLabTests` and `RatchetAnsweredInitLabTests` never reach. The
/// frame is evidence only when it is signed and at its first verdict; then it lets one copy of its id past the router and
/// resets at once when the session held calls for it, and when that reset declines it counts as `NO_SESSION` instead.
/// The node is reinstalled after answering Android's opener, and our answer never reached the phone, so every frame the
/// phone seals next still rides that init.
@Suite struct MeshEngineRatchetStaleInitTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private static let minute: Int64 = 60_000
    private var now: Int64 { EngineFixture.start }

    /// A node that answered `android`'s opener and kept its init in the identity's item, then reinstalled over `stores`
    /// and pinned the phone again: what the identity's item kept, and the reinstalled engine.
    private func reinstalled(
        _ android: AndroidPeer, stores: MeshStores = .inMemory()
    ) throws -> (keychain: KeptSecretStore, fixture: EngineFixture) {
        let keychain = KeptSecretStore(me.keys.storedForm)
        let before = try EngineFixture.ratcheting(me, keychain: keychain)
        try before.pin(android)
        before.deliver(try android.dm("the opener", to: me, prekey: try before.ourPrekey(), id: "opener", sentAt: now), from: android)
        #expect(before.engine.prekeyRing?.answeredInits.map(\.peer) == [alice.nodeId], "the node kept the init it answered")
        #expect(android.session(with: me)?.confirmed == false, "our answer never reached the phone")

        let fixture = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + Self.minute, seed: 21)
        try fixture.pin(android)
        fixture.transport.clear()
        return (keychain, fixture)
    }

    /// The phone's next DM, `id`, which still rides the opener's init, signed and flooded.
    private func onTheInit(_ android: AndroidPeer, _ fixture: EngineFixture, id: String) throws -> TestFrame {
        let frame = try android.dm("on the same init", to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: now + Self.minute)
        let header = try ChatContent(decoding: frame.envelope.payload).enc?.ratchet
        #expect(header?.initial != nil, "it rides the opener's init")
        return frame
    }

    private func staleDrops(_ fixture: EngineFixture, _ id: String) -> [String] {
        fixture.log.all.filter { $0.hasPrefix("info mesh ratchet drop \(id) ") && $0.hasSuffix(" answered-before") }
    }

    /// The unsigned live-link tick is never evidence: one riding the answered init is counted as a stale drop, and nothing
    /// else follows, no reset, no session and no slot among the heuristic's ids.
    @Test func anUnsignedTickOnAnAnsweredInitIsDroppedAndMovesNothing() throws {
        let android = try AndroidPeer(alice)
        let (_, fixture) = try reinstalled(android)
        var generator = SeededGenerator(seed: 5)
        let tick = MessageContent(body: "", ctl: MessageContent.Control.receipt, ack: FrameId.generate(using: &generator))
        let id = FrameId.generate(using: &generator)
        let frame = try android.dm(
            tick, to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: now + Self.minute, v3: true, signed: false, relay: false)
        #expect(try ChatContent(decoding: frame.envelope.payload).enc?.ratchet?.initial != nil, "it rides the opener's init")

        fixture.deliver(frame, from: android)
        #expect(staleDrops(fixture, id).count == 1, "\(fixture.log.all)")
        #expect(fixture.engine.dropped[.ratchetNoSession] == 1)
        #expect(fixture.resetsSent(to: alice).isEmpty, "no reset")
        #expect(fixture.ratchetRecords(of: alice).session == nil, "no session")
        #expect(fixture.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 0, "no evidence for the heuristic")
        #expect(fixture.transport.written(.chat).isEmpty, "nothing sent")
    }

    /// A start's replay is a delivery path and nothing more: the stale frame our custody hands back after a restart is
    /// counted as a drop, and resets nothing and counts toward nothing, even with no session held, where its first verdict
    /// would have reset at once. Otherwise custody's tail of a lost era would buy a reset at every restart. The first
    /// verdict's reset is declined here by a store that refuses it, so the restart meets the frame with no session.
    @Test(arguments: StoreKind.allCases)
    func aStartsReplayOfAStaleFrameResetsNothing(kind: StoreKind) throws {
        let directory = scratchDirectory("stale-replay")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let android = try AndroidPeer(alice)
        let (keychain, fixture) = try reinstalled(android, stores: stores)
        refusing.refusesWrites = true
        fixture.deliver(try onTheInit(android, fixture, id: "stale"), from: android)
        refusing.refusesWrites = false
        #expect(staleDrops(fixture, "stale").count == 1)
        #expect(fixture.resetsSent(to: alice).isEmpty && fixture.ratchetRecords(of: alice).session == nil, "its reset was declined")
        #expect(stores.custody.contains("stale") && stores.messages.message("stale") == nil, "custody keeps it, with no row")

        let wall = fixture.clock.wallMilliseconds()
        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: wall + Self.minute, seed: 22)
        #expect(staleDrops(restarted, "stale").count == 1, "the start's replay met it, stale: \(restarted.log.all)")
        #expect(restarted.engine.dropped == [.ratchetNoSession: 1])
        #expect(restarted.resetsSent(to: alice).isEmpty, "and reset nothing")
        #expect(!restarted.log.all.contains { $0.contains(" at once") }, "nor tried to")
        #expect(restarted.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 0, "nor counted toward a reset")
        #expect(restarted.ratchetRecords(of: alice).session == nil)

        // Another frame on that init, live, at its first verdict, still resets at once.
        restarted.deliver(try onTheInit(android, restarted, id: "stale-live"), from: android)
        #expect(Set(restarted.resetsSent(to: alice).map(\.envelope.id)).count == 1)
    }

    /// The at-once reset can decline: here the store refuses the reset's unit, as a full disk does. The frame then counts
    /// as `NO_SESSION`, one slot among the heuristic's ids, and the reset that went nowhere leaves no session and no frame
    /// on the air; once the store takes writes again, the next frame on that init resets at once.
    @Test(arguments: StoreKind.allCases)
    func aDeclinedResetAtOnceCountsTheFrameAsNoSession(kind: StoreKind) throws {
        let directory = scratchDirectory("stale-declined")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let android = try AndroidPeer(alice)
        let (_, fixture) = try reinstalled(android, stores: stores)
        let first = try onTheInit(android, fixture, id: "stale-1")

        refusing.refusesWrites = true
        fixture.deliver(first, from: android)
        refusing.refusesWrites = false
        #expect(staleDrops(fixture, "stale-1").count == 1)
        #expect(fixture.log.all.contains("info mesh no session reset to \(alice.nodeId) at once: the store failed"), "\(fixture.log.all)")
        #expect(fixture.engine.dropped[.ratchetNoSession] == 1)
        #expect(fixture.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 1, "counted as NO_SESSION")
        #expect(fixture.resetsSent(to: alice).isEmpty && fixture.transport.written(.chat).isEmpty, "nothing on the air")
        #expect(fixture.ratchetRecords(of: alice).session == nil, "and no session")

        fixture.deliver(try onTheInit(android, fixture, id: "stale-2"), from: android)
        #expect(Set(fixture.resetsSent(to: alice).map(\.envelope.id)).count == 1, "the next one resets at once")
    }

    /// A node that keeps no prekey ring has no answered inits either (``MeshEngine/prekeyRing``): no init reads as one a
    /// lost session answered, so a frame on an init against a prekey it no longer holds is refused as before ADR
    /// 2026-10.wcex, `EPOCH_GONE` and evidence, and the third resets through the heuristic. Here the phone seals against a
    /// prekey the node published under a ring it no longer has.
    @Test func withNoRingNoInitIsAnsweredBeforeAndTheHeuristicResets() throws {
        var ring = try PrekeyRing.load(for: me.keys, from: KeptSecretStore(me.keys.storedForm))
        let lost = try ring.rotate(now: now)
        let prekey = try #require(PeerPrekey(verifying: lost.info, signedBy: me.keys.bundle))
        let fixture = EngineFixture(me, configuration: MeshConfiguration(ratchet: true))
        #expect(fixture.engine.prekeyRing == nil)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        fixture.transport.clear()

        let ids = ["no-ring-1", "no-ring-2", "no-ring-3"]
        for (index, id) in ids.enumerated() {
            fixture.deliver(try android.dm("on a lost prekey", to: me, prekey: prekey, id: id, sentAt: now + Int64(index)), from: android)
            if index == 0 {
                #expect(fixture.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 1, "evidence, not stale")
                #expect(fixture.resetsSent(to: alice).isEmpty, "and no reset at once")
            }
        }
        #expect(ids.allSatisfy { staleDrops(fixture, $0).isEmpty }, "never answered-before")
        #expect(fixture.engine.dropped == [.ratchetEpochGone: 3], "the prekey it named is gone: \(fixture.engine.dropped)")
        #expect(Set(fixture.resetsSent(to: alice).map(\.envelope.id)).count == 1, "the third reset through the heuristic")
    }
}
