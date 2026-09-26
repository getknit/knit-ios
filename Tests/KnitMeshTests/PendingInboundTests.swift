import KnitMesh
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

/// Parking frames until their sender's key pins, ported from knit-next's `PendingInboundTest`.
@Suite struct PendingInboundTests {
    private let alice = fixtureNodeId(1)
    private let bob = fixtureNodeId(2)
    private let neighbor = fixtureNodeId(9)

    private func park(_ buffer: inout PendingInbound, _ id: String, from sender: NodeId, at now: Int64 = 0) -> Bool {
        let envelope = RelayEnvelope(type: .chat, id: id, senderId: sender.string, payload: [])
        let frame = InboundFrame(wire: WireEnvelope(sig: [1], signed: envelope.encoded), envelope: envelope, from: neighbor)
        return buffer.hold(frame, now: now)
    }

    @Test func aParkedFrameIsReleasedForItsSenderOnce() {
        var buffer = PendingInbound()
        _ = park(&buffer, "m1", from: alice)
        let released = buffer.release(alice)
        let again = buffer.release(alice)
        #expect(released.map(\.frame.envelope.id) == ["m1"])
        #expect(released.map(\.frame.from) == [neighbor])
        #expect(again.isEmpty)
    }

    @Test func releaseReturnsOnlyThatSendersFramesOldestFirst() {
        var buffer = PendingInbound()
        _ = park(&buffer, "a1", from: alice, at: 0)
        _ = park(&buffer, "b1", from: bob, at: 1)
        _ = park(&buffer, "a2", from: alice, at: 2)
        let fromAlice = buffer.release(alice).map(\.frame.envelope.id)
        let fromBob = buffer.release(bob).map(\.frame.envelope.id)
        #expect(fromAlice == ["a1", "a2"])
        #expect(fromBob == ["b1"])
    }

    @Test func aDuplicateIdIsParkedOnce() {
        var buffer = PendingInbound()
        let first = park(&buffer, "m1", from: alice)
        let second = park(&buffer, "m1", from: alice)
        #expect(first && !second)
        #expect(buffer.count == 1)
    }

    @Test func aSenderPastItsShareIsRefused() {
        var buffer = PendingInbound(perSender: 2)
        let parked = (0..<5).map { park(&buffer, "m\($0)", from: alice, at: Int64($0)) }
        #expect(parked == [true, true, false, false, false])
        let released = buffer.release(alice)
        #expect(released.map(\.frame.envelope.id) == ["m0", "m1"])
    }

    @Test func aWholeCustodyQuotaParksForOneSender() {
        // A newcomer is served a stranger's backlog in one burst; the park must hold all of it (ADR 2026-09.9xuu).
        var buffer = PendingInbound()
        let quota = CustodyLimits().maxPerSender
        let parked = (0...quota).map { park(&buffer, "m\($0)", from: alice, at: Int64($0)) }
        #expect(!parked.dropLast().contains(false), "the whole quota parks")
        #expect(parked.last == false, "one past the quota")
        #expect(PendingInbound.defaultCapacity == 512)
    }

    @Test func theByteBudgetEvictsTheOldestAndFreesOnRelease() throws {
        var probe = PendingInbound()
        _ = park(&probe, "m0", from: alice)
        let size = try #require(probe.release(alice).first).bytes
        var buffer = PendingInbound(maxBytes: size * 2)
        _ = park(&buffer, "a1", from: alice, at: 0)
        _ = park(&buffer, "b1", from: bob, at: 1)
        _ = park(&buffer, "b2", from: bob, at: 2)
        #expect(buffer.release(alice).isEmpty, "the oldest went to make room")
        #expect(buffer.release(bob).map(\.frame.envelope.id) == ["b1", "b2"])
        #expect(park(&buffer, "a2", from: alice, at: 3) && park(&buffer, "a3", from: alice, at: 4), "a release frees its bytes")
        #expect(buffer.count == 2)
    }

    @Test func aFrameOverTheWholeBudgetIsNeverParked() throws {
        var probe = PendingInbound()
        _ = park(&probe, "m0", from: alice)
        let size = try #require(probe.release(alice).first).bytes
        var buffer = PendingInbound(maxBytes: size - 1)
        #expect(!park(&buffer, "m0", from: alice))
        #expect(buffer.isEmpty)
    }

    @Test func theGlobalCapEvictsTheOldest() {
        var buffer = PendingInbound(capacity: 2)
        for (index, seed) in [3, 4, 5].enumerated() {
            _ = park(&buffer, "m\(index)", from: fixtureNodeId(seed), at: Int64(index))
        }
        let evicted = buffer.release(fixtureNodeId(3))
        let second = buffer.release(fixtureNodeId(4))
        let third = buffer.release(fixtureNodeId(5))
        #expect(evicted.isEmpty, "the oldest frame went")
        #expect(second.map(\.frame.envelope.id) == ["m1"])
        #expect(third.map(\.frame.envelope.id) == ["m2"])
    }

    @Test func theSweepDropsOnlyFramesPastTheHold() {
        var buffer = PendingInbound(holdMilliseconds: 100)
        _ = park(&buffer, "old", from: alice, at: 0)
        _ = park(&buffer, "new", from: alice, at: 80)
        let swept = buffer.sweep(now: 150)
        #expect(swept == 1)
        let kept = buffer.release(alice)
        #expect(kept.map(\.frame.envelope.id) == ["new"])
    }

    @Test func aFrameIsKeptForTheWholeHold() {
        var buffer = PendingInbound(holdMilliseconds: 100)
        _ = park(&buffer, "edge", from: alice, at: 0)
        let swept = buffer.sweep(now: 100)
        #expect(swept == 0)
    }

    @Test func anEmptyBufferSaysSo() {
        var buffer = PendingInbound()
        #expect(buffer.isEmpty)
        _ = park(&buffer, "m1", from: alice)
        #expect(!buffer.isEmpty)
    }
}
