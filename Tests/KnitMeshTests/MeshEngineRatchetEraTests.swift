import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The reset heuristic's era gate through the engine's real drop path (ADR 2026-10.5sk9, phase P5a; knit-next ADR 024 and
/// ADR 026): a frame authored before the session we hold is no evidence that it is broken, a peer's clock is compared only
/// with its own stamps, and past every retention window no stranded tail survives. Ported by name from knit-next's
/// `InboundPipelineTest.kt:5021-5202`, with the brief's fast clock.
@Suite struct MeshEngineRatchetEraTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private static let hour: Int64 = 3_600_000

    private func rig() throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    private var now: Int64 { EngineFixture.start }

    /// Our own reset toward `android` at `era`, which leaves us the initiator of a session established then
    /// (`initiateEraAt`, `InboundPipelineTest.kt:5093-5106`).
    private func initiateEra(_ fixture: EngineFixture, toward android: AndroidPeer, at era: Int64) throws {
        guard case .sent = fixture.engine.sendSessionReset(to: android.nodeId, now: era, cause: .onDemand) else {
            Issue.record("the reset that starts the era")
            return
        }
        let session = try #require(fixture.ratchetRecords(of: alice).session)
        #expect(session.weAreInitiator && session.establishedAt == era)
    }

    @Test func framesSealedBeforeTheCurrentEraAreNotEvidenceThatItIsBroken() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let era = now - 60_000
        fixture.deliver(
            try android.dm(MessageContent(body: "hello"), to: me, prekey: prekey, id: "era-1", sentAt: era, now: era), from: android)
        #expect(fixture.ratchetRecords(of: alice).session?.establishedAt == era)
        for index in 0..<3 {
            let frame = try android.dm(
                MessageContent(body: "x"),
                to: me,
                prekey: prekey,
                id: "old\(index)",
                sentAt: era - 100,
                now: era
            ) { $0.ratchet = $0.ratchet?.skipping(5) }
            fixture.deliver(frame, from: android)
        }
        #expect(fixture.engine.dropped[.ratchetAeadFail] == 3)
        #expect(fixture.resetsSent(to: alice).isEmpty, "ciphertext from an era we left is unreadable by construction")
        for index in 0..<3 {
            let frame = try android.dm(
                MessageContent(body: "x"),
                to: me,
                prekey: prekey,
                id: "new\(index)",
                sentAt: era,
                now: era
            ) { $0.ratchet = $0.ratchet?.skipping(9) }
            fixture.deliver(frame, from: android)
        }
        #expect(fixture.resetsSent(to: alice).count == 1, "the same failure from the live era still resets")
    }

    @Test func aPeerWhoseClockLagsOursStillProvesTheSessionIsBroken() throws {
        let (fixture, android) = try rig()
        let era = now - 7 * Self.hour
        try initiateEra(fixture, toward: android, at: era)
        let before = fixture.resetsSent(to: alice).count
        try fixture.deliverUnreadable(from: android, tag: "lag", sentAt: era - (WireProtocol.maxFutureSkewMilliseconds - 60_000))
        #expect(fixture.engine.dropped[.ratchetAeadFail] == 3)
        #expect(fixture.resetsSent(to: alice).count == before + 1, "skew within the tolerance must not disarm the heuristic")
    }

    @Test func aTailFromTheEraWeLeftIsStillNotEvidenceOnTheInitiatorSide() throws {
        let (fixture, android) = try rig()
        let era = now - 7 * Self.hour
        try initiateEra(fixture, toward: android, at: era)
        let before = fixture.resetsSent(to: alice).count
        try fixture.deliverUnreadable(from: android, tag: "tail", sentAt: now - 30 * Self.hour)
        #expect(fixture.engine.dropped[.ratchetAeadFail] == 3)
        #expect(fixture.resetsSent(to: alice).count == before)
    }

    @Test func anEraOlderThanEveryRetentionWindowRearmsTheHeuristic() throws {
        let (fixture, android) = try rig()
        let era = now - 49 * Self.hour
        try initiateEra(fixture, toward: android, at: era)
        let before = fixture.resetsSent(to: alice).count
        try fixture.deliverUnreadable(from: android, tag: "stale", sentAt: now - 60 * Self.hour)
        #expect(fixture.resetsSent(to: alice).count == before + 1, "past every retention window, whatever the clocks say")
    }

    /// The clock skew the era gate must survive: Alice's clock runs 10 minutes ahead of ours, so the session she starts is
    /// established at her clock, and only her frames' own signed stamps compare with it. A stamp clamped to five minutes
    /// past our clock would read every one of her live failures as pre-era, and the heuristic would never fire toward her
    /// (knit-next `cf447a9b`).
    @Test func aPeerWhoseClockRunsTenMinutesFastStillBuysItsReset() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let ahead = now + 600_000
        fixture.deliver(try android.dm(MessageContent(body: "hi"), to: me, prekey: prekey, id: "fast-0", sentAt: ahead), from: android)
        #expect(fixture.ratchetRecords(of: alice).session?.establishedAt == ahead)
        for index in 1...3 {
            let stamp = ahead + Int64(index)
            let frame = try android.dm(
                MessageContent(body: "x"),
                to: me,
                prekey: prekey,
                id: "fast-\(index)",
                sentAt: stamp,
                now: ahead
            ) { $0.ratchet = $0.ratchet?.skipping(5) }
            fixture.deliver(frame, from: android)
        }
        #expect(fixture.engine.dropped[.ratchetAeadFail] == 3)
        #expect(fixture.resetsSent(to: alice).count == 1)
    }

    /// `anEpochGoneOnAnEpochWeRetiredBehindThePeersAckIsNeverEvidence` (knit-next ADR 2026-10.9wvr, `InboundPipelineTest.kt`
    /// at `4f3cd995`), the field's shape: a session we initiated more than 48 h ago, so the era gate's escape is open, whose
    /// epochs have churned past the 16-row cap. A restart's custody re-serve brings frames the peer sealed against epochs
    /// we retired long since, behind one it has sealed against after. They are doomed as a pre-era tail is, and neither buy
    /// a reset nor take a slot among the heuristic's ids; an `EPOCH_GONE` on an epoch at or above the lowest we hold, a
    /// hole, is the split-era case and still counts.
    @Test func anEpochGoneOnAnEpochWeRetiredBehindThePeersAckIsNeverEvidence() throws {
        let (fixture, android) = try rig()
        try initiateEra(fixture, toward: android, at: now - 49 * Self.hour)
        // A long-lived session: confirmed, Alice's newest seal against us on our epoch 20, epochs 12...20 kept but 15.
        var session = try #require(fixture.stores.ratchet.session(alice.nodeId))
        session.confirmed = true
        session.initEphPub = nil
        session.highestPeAcked = 20
        fixture.stores.ratchet.deletePeer(alice.nodeId)
        fixture.stores.ratchet.upsertSession(session)
        for epoch in Array(12...20) where epoch != 15 {
            let pair = RatchetCrypto.generateKeyPair()
            let kept = RatchetLocalEpochRecord(
                epoch: epoch, privateKey: pair.privateKey, publicKey: pair.publicKey, createdAt: Int64(epoch))
            fixture.stores.ratchet.commitSend(session, newLocalEpoch: kept)
        }
        #expect(fixture.stores.ratchet.lowestLocalEpoch(alice.nodeId) == 12)
        let before = fixture.resetsSent(to: alice).count
        let prekey = try fixture.ourPrekey()

        // An epoch of Alice's we hold no chain for, based on the epoch named: the open reaches the fresh derivation and finds
        // no base key.
        func basedOn(_ id: String, pe: Int) throws -> TestFrame {
            try android.dm(MessageContent(body: "x"), to: me, prekey: prekey, id: id, sentAt: now - 51 * Self.hour, now: now) { envelope in
                guard var header = envelope.ratchet else {
                    return
                }
                header.se += 1
                header.pe = pe
                header.initial = nil
                envelope.ratchet = header
            }
        }

        for index in 1...3 {
            fixture.deliver(try basedOn("retired-\(index)", pe: 5), from: android)
        }
        #expect(fixture.engine.dropped[.ratchetEpochGone] == 3)
        #expect(fixture.resetsSent(to: alice).count == before, "ciphertext on a key retention already took is doomed, not divergence")
        #expect(fixture.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 0, "and never took a slot")
        #expect(
            fixture.log.all.contains { $0.contains("mesh reset gate: retired-1 from \(alice.nodeId) retired epoch pe=5 lowestRetained=12") }
        )

        // Two holes: had the doomed three entered the ids, these would make five distinct and fire.
        for index in 1...2 {
            fixture.deliver(try basedOn("hole-\(index)", pe: 15), from: android)
        }
        #expect(fixture.resetsSent(to: alice).count == before, "the doomed frames never took a slot among the distinct ids")
        fixture.deliver(try basedOn("hole-3", pe: 15), from: android)
        #expect(fixture.resetsSent(to: alice).count == before + 1, "a missing epoch we should still hold is the split-era case")
    }
}
