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
}
