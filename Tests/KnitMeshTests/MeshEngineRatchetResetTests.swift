import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The reset heuristic end to end, through the engine's real drop path (ADR 2026-10.5sk9, phase P5a): knit-next's
/// `InboundPipelineTest` reset cases, ported by name (`InboundPipelineTest.kt:4897-5460`), and the brief's own. The drop
/// path calls `noteUndecryptable` outside any unit, where it counts; inside one it would answer false and count nothing,
/// and these tests would see no reset.
@Suite struct MeshEngineRatchetResetTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private static let hour: Int64 = 3_600_000

    private func rig(stores: MeshStores = .inMemory()) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    private var now: Int64 { EngineFixture.start }

    @Test func aSplitBrainRootRequestsAResetInsteadOfDeadlockingForever() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        for id in ["sb1", "sb2", "sb3"] {
            let frame = try android.dm(MessageContent(body: "unreadable"), to: me, prekey: prekey, id: id, sentAt: now) { envelope in
                envelope.ratchet = envelope.ratchet?.skipping(5)
            }
            fixture.deliver(frame, from: android)
        }
        #expect(fixture.engine.dropped[.ratchetAeadFail] == 3)
        #expect(fixture.engine.dropped[.cannotOpen] == nil, "a split brain is not filed under the generic failure")
        let resets = fixture.resetsSent(to: alice)
        #expect(resets.count == 1, "one reset for the burst")
        #expect(resets.first?.envelope.recipientId == alice.nodeId.string)
    }

    @Test func sealingAResetDropsOurOwnRecvStateSoThePeersFreshEpochsAreNotJudgedStale() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        fixture.deliver(try android.dm("hello", to: me, prekey: prekey, id: "ok-1", sentAt: now), from: android)
        #expect(!fixture.ratchetRecords(of: alice).recvEpochs.isEmpty, "a receive epoch to go stale")
        for id in ["sb1", "sb2", "sb3"] {
            let frame = try android.dm(MessageContent(body: "unreadable"), to: me, prekey: prekey, id: id, sentAt: now) { envelope in
                envelope.ratchet = envelope.ratchet?.skipping(5)
            }
            fixture.deliver(frame, from: android)
        }
        #expect(fixture.resetsSent(to: alice).count == 1)
        #expect(fixture.ratchetRecords(of: alice).recvEpochs.isEmpty, "the era left takes its receive state with it")
    }

    @Test func distinctFramesLandingOnConsumedChainIndicesNeverRequestAReset() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        for (index, id) in ["d1", "d2", "d3"].enumerated() {
            fixture.deliver(try android.dm("body-\(id)", to: me, prekey: prekey, id: id, sentAt: now + Int64(index)), from: android)
        }
        for index in 0..<3 {
            let frame = try android.dm(
                MessageContent(body: "x"),
                to: me,
                prekey: prekey,
                id: "replayer-\(index)",
                sentAt: now
            ) { $0.ratchet?.n = index }
            fixture.deliver(frame, from: android)
        }
        #expect(fixture.engine.dropped[.ratchetDuplicate] == 3)
        #expect(fixture.resetsSent(to: alice).isEmpty, "our own delivered history coming back is never divergence")
    }

    @Test func oneFrameReservedFromCustodyNeverRequestsAResetHoweverOftenItArrives() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let once = try android.dm("body", to: me, prekey: prekey, id: "d1", sentAt: now)
        fixture.deliver(once, from: android)
        for _ in 0..<8 {
            fixture.deliverPastRouter(once, from: alice)
        }
        #expect(fixture.resetsSent(to: alice).isEmpty)
        #expect(fixture.acknowledged.count == 9)
    }

    @Test func repeatedUndecryptableFramesTriggerExactlyOneRateLimitedResetRequest() throws {
        let (fixture, android) = try rig()
        try fixture.deliverUnreadable(from: android, tag: "o", sentAt: now, count: 2)
        #expect(fixture.transport.written(.chat).isEmpty, "below the distinct-frames threshold, no reset yet")
        try fixture.deliverUnreadable(from: android, tag: "o3", sentAt: now, count: 1)
        let resets = fixture.resetsSent(to: alice)
        #expect(resets.count == 1)
        let reset = try #require(resets.first)
        let header = try #require(try ChatContent(decoding: reset.envelope.payload).enc?.ratchet)
        #expect(header.flags & RatchetHeader.resetFlag != 0 && header.initial != nil, "a fresh X3DH init, flagged")
        try fixture.deliverUnreadable(from: android, tag: "o4", sentAt: now, count: 1)
        #expect(fixture.resetsSent(to: alice).count == 1, "inside the floor nothing fires again")
    }

    @Test func structurallyInvalidHeadersNeverTriggerAResetRequest() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        for index in 0..<RatchetResetPolicy.distinctFrames {
            let frame = try android.dm(
                MessageContent(body: "malformed"),
                to: me,
                prekey: prekey,
                id: "bad-\(index)",
                sentAt: now
            ) { $0.ratchet?.pe = -1 }
            fixture.deliver(frame, from: android)
        }
        #expect(fixture.engine.dropped[.ratchetBadHeader] == 3)
        #expect(fixture.engine.dropped[.ratchetEpochGone] == nil)
        #expect(fixture.resetsSent(to: alice).isEmpty)
    }

    @Test func theSixHourFloorHoldsOurNextResetBack() throws {
        let (fixture, android) = try rig()
        try fixture.deliverUnreadable(from: android, tag: "first", sentAt: now)
        #expect(fixture.resetsSent(to: alice).count == 1)
        fixture.clock.advance(60_000)
        try fixture.deliverUnreadable(from: android, tag: "again", sentAt: now + 60_000)
        #expect(fixture.resetsSent(to: alice).count == 1, "six hours from our last reset, read from the session row")
        fixture.clock.advance(6 * Self.hour)
        try fixture.deliverUnreadable(from: android, tag: "later", sentAt: now + 6 * Self.hour + 60_000)
        #expect(fixture.resetsSent(to: alice).count == 2)
    }

    @Test func aStoreThatCannotAnswerBuysNoReset() throws {
        let refusing = RefusingRatchetStore()
        let memory = MeshStores.inMemory()
        let stores = memory.replacing(ratchet: refusing, transactor: refusing.transactor)
        let (fixture, android) = try rig(stores: stores)
        refusing.refuse(.reads)
        try fixture.deliverUnreadable(from: android, tag: "refused", sentAt: now, count: 4)
        #expect(fixture.engine.dropped[.storeRefused] == 4)
        #expect(fixture.engine.dropped[.ratchetNoSession] == nil, "a store's fallback is no verdict")
        #expect(fixture.resetsSent(to: alice).isEmpty)
        #expect(fixture.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 0)
    }

    @Test func aCountedFailureLetsOneCopyOfItsIdPastTheRouter() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let orphan = try android.dm(MessageContent(body: "lost"), to: me, prekey: prekey, id: "orphan", sentAt: now) { envelope in
            envelope.ratchet = envelope.ratchet?.steady
        }
        // The copy our reset's answer re-seals under the same id comes in once inside the window, and only once.
        for _ in 0..<3 {
            fixture.deliver(orphan, from: android)
        }
        #expect(fixture.engine.dropped[.ratchetNoSession] == 2)
        let malformed = try android.dm(MessageContent(body: "bad"), to: me, prekey: prekey, id: "bad", sentAt: now) { $0.ratchet?.pe = -1 }
        fixture.deliver(malformed, from: android)
        fixture.deliver(malformed, from: android)
        #expect(fixture.engine.dropped[.ratchetBadHeader] == 1, "a failure that counts for nothing reopens nothing")
    }

    /// The heuristic fires, and the gates the reset needs refuse it: a peer pinned with no prekey can never be re-rooted
    /// from this side (`sendSessionReset`'s "no pinned prekey id", `InboundPipeline.kt:1918-1924`), and nothing goes out.
    @Test func aPeerWeCannotResetGetsNoResetHoweverManyFramesFail() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        fixture.deliver(try alice.profile(publishedAt: now, capabilities: AndroidPeer.capabilities), from: alice)
        fixture.transport.clear()
        try fixture.deliverUnreadable(from: android, tag: "stuck", sentAt: now, count: 4)
        #expect(fixture.engine.dropped[.ratchetNoSession] == 4)
        #expect(fixture.transport.written(.chat).isEmpty)
        #expect(fixture.log.all.contains { $0.contains("mesh no session reset to \(alice.nodeId): no pinned prekey id") })
    }

    @Test func aSweepTheStoreRefusesIsReportedAndCostsNothingElse() throws {
        let refusing = RefusingRatchetStore()
        refusing.refuse(.writes)
        let fixture = try EngineFixture.ratcheting(
            me, stores: MeshStores.inMemory().replacing(ratchet: refusing, transactor: refusing.transactor))
        #expect(fixture.log.all.contains { $0.contains("mesh ratchet sweep failed") }, "the start's sweep")
        #expect(fixture.engine.isStarted)
    }

    @Test func aResetTheRatchetDeclinesOriginatesNothingAndSaysWhy() throws {
        let (fixture, android) = try rig()
        guard case .sent = fixture.engine.sendRatchetReset(to: android.nodeId) else {
            Issue.record("the first reset goes")
            return
        }
        let sent = fixture.transport.written.count
        #expect(fixture.engine.sendRatchetReset(to: android.nodeId) == .declined("our reset is still on its way"))
        #expect(
            fixture.engine.sendSessionReset(to: android.nodeId, now: now, cause: .afterWipe)
                == .declined("a reset already went since the restore"))
        #expect(fixture.transport.written.count == sent)
    }
}

extension MeshStores {
    /// These stores with the ratchet's swapped for `ratchet`, under `transactor`.
    func replacing(ratchet: any RatchetStore, transactor: any StoreTransactor) -> Self {
        MeshStores(
            custody: custody,
            peers: peers,
            messages: messages,
            conversations: conversations,
            blocks: blocks,
            groups: groups,
            ownProfile: ownProfile,
            blobs: blobs,
            ratchet: ratchet,
            transactor: transactor
        )
    }
}
