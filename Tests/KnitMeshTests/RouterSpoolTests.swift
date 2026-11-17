import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The router's spool door (ADR 2026-11.adrq, P4a): a spool's copy is admitted by id shape and the seen set alone, is no
/// overhear, and is bridged as a flood heard from nobody.
@Suite struct RouterSpoolTests {
    private let alice = fixtureNodeId(1)
    private let carol = fixtureNodeId(3)

    private func frame(_ id: String, hops: Int = 0, relay: Bool = true) -> (WireEnvelope, RelayEnvelope) {
        let envelope = RelayEnvelope(type: .chat, id: id, senderId: "a", payload: [])
        return (WireEnvelope(hops: hops, relay: relay, sig: [], signed: envelope.encoded), envelope)
    }

    @Test func aSpoolsCopyIsCountedApartAndIsNoOverhear() {
        var router = Router()
        let (wire, envelope) = frame(frameIdOf("m1"))
        #expect(router.admit(InboundFrame(wire: wire, envelope: envelope, from: alice), now: 0) == .new)
        _ = router.relay(InboundFrame(wire: wire, envelope: envelope, from: alice), neighbors: [alice, carol], jitter: 10, now: 0)
        #expect(router.admitPulled(envelope: envelope, now: 1) == .duplicate)
        #expect(router.counters.suppressed == 0 && router.pendingRelayCount == 1, "a spool's copy cancels no relay")
        #expect(router.fireDue(now: 10, neighbors: [alice, carol]).map(\.to) == [carol])
        let bad = RelayEnvelope(type: .chat, id: "\u{FEFF}" + frameIdOf("m2"), senderId: "a", payload: [])
        #expect(router.admitPulled(envelope: bad, now: 1) == .nonCanonical)
        #expect(router.counters.spoolDeduplicated == 1 && router.counters.spoolNonCanonical == 1 && router.counters.admitted == 1)
    }

    @Test func aBridgeIsHeardFromNobodyAndItsMarkCanBeTakenBack() {
        var router = Router()
        let (wire, envelope) = frame(frameIdOf("m1"))
        #expect(router.admitPulled(envelope: envelope, now: 0) == .new)
        let bridged = router.relayPulled(wire, id: envelope.id, jitter: 5, now: 0)
        #expect(bridged)
        // The radio's first copy is the first overhear, not the second.
        #expect(router.admit(InboundFrame(wire: wire, envelope: envelope, from: alice), now: 1) == .duplicate)
        #expect(router.fireDue(now: 5, neighbors: [alice, carol]).map(\.to) == [carol])
        router.reopenPulled(envelope.id)
        router.reopenPulled(envelope.id)
        #expect(router.admitPulled(envelope: envelope, now: 6) == .new, "taken back, however often")
        let (spent, last) = frame(frameIdOf("m2"), hops: WireEnvelope.defaultTTL)
        let (single, point) = frame(frameIdOf("m3"), relay: false)
        let refused = [
            router.relayPulled(spent, id: last.id, jitter: 0, now: 0), router.relayPulled(single, id: point.id, jitter: 0, now: 0),
        ]
        #expect(refused == [false, false], "no hops left, or point to point")
        #expect(router.counters.spoolBridged == 1 && router.counters.spoolAdmitted == 2)
    }
}
