import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The ticks the engine owes, over ``AckSync`` (phase P5c of ADR 2026-10.5sk9): with the seams as this build ships them,
/// every tick is today's cleartext one, byte for byte; with the seams faked to seal (``EngineSeals``), a group's tick toward
/// an absent author escalates into custody as one originated frame, a room's waits for a carrier and is never carried,
/// and a live link ends each hold as one tick. Bob is the author, Carol the neighbour his frames come through.
@Suite struct MeshEngineTickTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let start = EngineFixture.start
    private let debounce = AckSync.batchDebounceMilliseconds

    private var bobsGroup: GroupInfo { roster([bob, carol, alice], createdBy: bob) }

    /// Alice's engine, linked to Carol, with Bob's key pinned and Bob unlinked.
    private func fixture(ratchet: Bool = false) throws -> EngineFixture {
        let fixture = EngineFixture(alice, configuration: MeshConfiguration(ratchet: ratchet))
        fixture.link(carol)
        try fixture.pin(bob)
        fixture.transport.clear()
        return fixture
    }

    private func groupMessage(_ id: String, at offset: Int64 = 0) throws -> TestFrame {
        try bob.groupMessage("Hi \(id)", in: bobsGroup, to: [alice, carol], id: id, sentAt: start + offset)
    }

    /// The ticks of ours toward Bob in DM form, sealed.
    private func sealedTicks(_ fixture: EngineFixture) -> [Written] {
        fixture.transport.written(.chat).filter { written in
            written.envelope.recipientId == bob.nodeId.string && written.envelope.senderId == alice.nodeId.string
        }
    }

    // MARK: The seams as shipped

    /// The guard P5c owes: until P5d's seals, a tick on the air is today's, whatever the switch says. Point to point,
    /// signed, no `sentAt`, a fresh id each attempt, only over a live link, never carried, toward an author whose profile
    /// advertises the ratchet too.
    @Test(arguments: [false, true])
    func withTheSeamsAsShippedEveryTickIsTodaysCleartext(ratchet: Bool) throws {
        let fixture = try fixture(ratchet: ratchet)
        #expect(fixture.engine.tickSeals is NoTickSealing)
        fixture.link(bob)
        fixture.transport.clear()
        fixture.deliver(try bob.roomPost("Linked", id: "post-1", sentAt: start), from: bob)
        fixture.deliver(try groupMessage("gm-1"), from: bob)
        fixture.unlink(bob)
        let absentPost = try bob.roomPost("Absent", id: "post-2", sentAt: start + 1)
        fixture.deliver(absentPost, from: carol)
        fixture.deliver(try groupMessage("gm-2", at: 1), from: carol)
        #expect(fixture.engine.footprint.owedTicks == 2, "two ticks owed to the absent author")
        #expect(fixture.engine.ackSync.nextBatchDue == nil, "no batch waits")
        fixture.advance(debounce)
        fixture.advance(fixture.engine.configuration.healMilliseconds)
        #expect(fixture.transport.written(.receipt).count == 2, "nothing more while Bob is away")
        fixture.link(bob)
        fixture.clock.advance(SeenSetWindow.milliseconds)
        fixture.deliver(absentPost, from: carol)

        let ticks = fixture.transport.written(.receipt)
        let acked = try ticks.map { try ReceiptContent(decoding: $0.envelope.payload).ackId }
        #expect(acked == ["post-1", "gm-1", "post-2", "gm-2", "post-2"], "one per delivery, the re-served post's again")
        #expect(Set(ticks.map(\.envelope.id)).count == ticks.count, "a fresh id every attempt")
        for (tick, ackId) in zip(ticks, acked) {
            #expect(tick.to == bob.nodeId && !tick.wire.relay)
            let today = RelayEnvelope(
                type: .receipt, id: tick.envelope.id, senderId: alice.nodeId.string, payload: ReceiptContent(ackId: ackId).encoded)
            #expect(tick.wire.signed == today.encoded, "today's bytes: no sentAt, no recipient, no group")
            #expect(alice.keys.bundle.isValidSignature(tick.wire.sig, for: tick.wire.signed))
            #expect(!fixture.stores.custody.contains(tick.envelope.id), "never carried")
        }
        #expect(sealedTicks(fixture).isEmpty, "nothing sealed")
        #expect(fixture.engine.footprint.owedTicks == 0)
    }

    @Test func theSeamsAsShippedCannotSeal() {
        let seals = NoTickSealing()
        #expect(!seals.canSeal(bob.nodeId))
        #expect(seals.sealTick(to: bob.nodeId, acks: ["m1"]) == nil)
        #expect(!seals.originateTick(to: bob.nodeId, acks: ["m1", "m2"]))
    }

    // MARK: The seams faked to seal

    @Test func aGroupPostFromAnAbsentAuthorEscalatesAsOneOriginatedFrameCarriedInCustody() throws {
        let fixture = try fixture()
        let seals = EngineSeals(fixture, capable: [bob.nodeId])
        let owedAt = fixture.clock.monotonicMilliseconds()
        let first = try groupMessage("gm-1")
        fixture.deliver(first, from: carol)
        fixture.deliver(try groupMessage("gm-2", at: 1), from: carol)
        // Past the relays' jitter, the batch's debounce is the next thing due.
        fixture.advance(fixture.engine.configuration.router.jitterWindowMilliseconds)
        #expect(seals.originated.isEmpty && sealedTicks(fixture).isEmpty, "nothing before the debounce")
        #expect(fixture.engine.footprint.owedTicks == 2)
        #expect(fixture.engine.nextDeadline == owedAt + debounce, "the batch's deadline")

        fixture.advance(owedAt + debounce - fixture.clock.monotonicMilliseconds())
        #expect(seals.originated == [["gm-1", "gm-2"]], "one tick for the batch, with no heal")
        let ticks = sealedTicks(fixture)
        let tick = try #require(ticks.first)
        #expect(ticks.count == 1 && tick.to == nil && tick.wire.relay, "originated: flooded")
        #expect(tick.envelope.sentAt == fixture.clock.wallMilliseconds(), "dated, so custody keeps it a day")
        #expect(fixture.stores.custody.contains(tick.envelope.id), "and carried in our custody")
        #expect(EngineSeals.acks(of: tick, as: bob) == ["gm-1", "gm-2"])
        #expect(fixture.transport.written(.receipt).isEmpty && fixture.engine.footprint.owedTicks == 0)

        // A carrier re-serves the message after the router's window; the exists-gate acknowledges it again, and owes nothing.
        fixture.clock.advance(SeenSetWindow.milliseconds)
        fixture.deliver(first, from: carol)
        fixture.advance(debounce)
        fixture.link(bob)
        #expect(seals.originated.count == 1 && seals.sealed.isEmpty, "never sealed again")
        #expect(sealedTicks(fixture).count == 1 && fixture.transport.written(.receipt).isEmpty)
    }

    @Test func aRoomPostsTickWaitsForACarrierAndIsNeverCarried() throws {
        let fixture = try fixture()
        let seals = EngineSeals(fixture, capable: [bob.nodeId])
        let carried = Set(fixture.stores.custody.liveIds(now: fixture.clock.wallMilliseconds()))
        let post = try bob.roomPost("Hello room", id: "post-1", sentAt: start)
        fixture.deliver(post, from: carol)
        fixture.advance(AckSync.rideHoldMilliseconds)
        fixture.advance(fixture.engine.configuration.healMilliseconds)
        #expect(fixture.engine.ackSync.ridingFor(bob.nodeId) == 1, "it waits past its deadline: no route but a link")
        #expect(seals.sealed.isEmpty && seals.originated.isEmpty && sealedTicks(fixture).isEmpty)
        #expect(fixture.transport.written(.receipt).isEmpty)
        let now = Set(fixture.stores.custody.liveIds(now: fixture.clock.wallMilliseconds()))
        #expect(now.subtracting(carried) == ["post-1"], "the post is carried, and no row for its tick")

        // A frame sealed toward Bob anyway carries it, as P5d's will: the stand-in takes it and says it rode.
        let riders = fixture.engine.ackSync.takeRiding(bob.nodeId, limit: 4)
        #expect(riders == ["post-1"])
        fixture.engine.ackSync.rode(riders, now: fixture.clock.monotonicMilliseconds())
        fixture.clock.advance(SeenSetWindow.milliseconds)
        fixture.deliver(post, from: carol)
        fixture.link(bob)
        #expect(fixture.transport.written(.receipt).isEmpty && seals.sealed.isEmpty, "it rode, so nothing is owed or sent")
        #expect(fixture.engine.footprint.owedTicks == 0)
    }

    @Test func aRoomTickRidesTheGroupBatchIntoCustodyWithNoRowOfItsOwn() throws {
        let fixture = try fixture()
        let seals = EngineSeals(fixture, capable: [bob.nodeId])
        fixture.deliver(try bob.roomPost("Room", id: "post-1", sentAt: start), from: carol)
        fixture.deliver(try groupMessage("gm-1", at: 1), from: carol)
        fixture.advance(debounce)
        #expect(seals.originated == [["gm-1", "post-1"]], "the group's batch carries the room's tick")
        let ticks = sealedTicks(fixture)
        let tick = try #require(ticks.first)
        #expect(ticks.count == 1 && EngineSeals.acks(of: tick, as: bob) == ["gm-1", "post-1"])
        #expect(fixture.engine.ackSync.ridingFor(bob.nodeId) == 0 && fixture.engine.footprint.owedTicks == 0)
    }

    @Test func aLiveLinkEndsEachHoldAsOneTick() throws {
        let fixture = try fixture()
        let seals = EngineSeals(fixture, capable: [bob.nodeId])
        fixture.deliver(try groupMessage("gm-1"), from: carol)
        fixture.deliver(try groupMessage("gm-2", at: 1), from: carol)
        fixture.deliver(try bob.roomPost("One", id: "post-1", sentAt: start + 2), from: carol)
        fixture.deliver(try bob.roomPost("Two", id: "post-2", sentAt: start + 3), from: carol)
        fixture.link(bob)

        let ticks = sealedTicks(fixture)
        #expect(ticks.count == 2, "the batch and the ride hold, one tick each")
        #expect(ticks.allSatisfy { $0.to == bob.nodeId && !$0.wire.relay }, "point to point, over the link")
        #expect(ticks.compactMap { EngineSeals.acks(of: $0, as: bob) } == [["gm-1", "gm-2"], ["post-1", "post-2"]])
        #expect(ticks.allSatisfy { !fixture.stores.custody.contains($0.envelope.id) }, "no custody row")
        #expect(seals.originated.isEmpty && fixture.transport.written(.receipt).isEmpty)
        #expect(fixture.engine.footprint.owedTicks == 0)
        fixture.advance(debounce)
        fixture.advance(fixture.engine.configuration.healMilliseconds)
        #expect(sealedTicks(fixture).count == 2 && seals.originated.isEmpty, "and nothing after")
    }

    @Test func aLinkedCapableAuthorGetsOneSealedTickAtOnce() throws {
        let fixture = try fixture()
        let seals = EngineSeals(fixture, capable: [bob.nodeId])
        fixture.link(bob)
        fixture.transport.clear()
        fixture.deliver(try groupMessage("gm-1"), from: bob)
        fixture.deliver(try bob.roomPost("Room", id: "post-1", sentAt: start), from: bob)
        let ticks = sealedTicks(fixture)
        #expect(ticks.map(\.to) == [bob.nodeId, bob.nodeId] && ticks.allSatisfy { !$0.wire.relay })
        #expect(ticks.compactMap { EngineSeals.acks(of: $0, as: bob) } == [["gm-1"], ["post-1"]])
        #expect(seals.sealed == [["gm-1"], ["post-1"]] && seals.originated.isEmpty)
    }

    @Test func aFailedEscalationLeavesCleartextTicksThatGoAtTheLink() throws {
        let fixture = try fixture()
        let seals = EngineSeals(fixture, capable: [bob.nodeId])
        seals.originates = false
        fixture.deliver(try groupMessage("gm-1"), from: carol)
        fixture.deliver(try groupMessage("gm-2", at: 1), from: carol)
        fixture.advance(debounce)
        #expect(sealedTicks(fixture).isEmpty && fixture.engine.footprint.owedTicks == 2)
        // Bob is still capable, so the link offers a seal first; with none, cleartext as today.
        seals.capable = []
        fixture.link(bob)
        let acked = try fixture.transport.written(.receipt).map { try ReceiptContent(decoding: $0.envelope.payload).ackId }
        #expect(acked == ["gm-1", "gm-2"])
        #expect(sealedTicks(fixture).isEmpty)
    }

    @Test func aBlockedMembersGroupTickIsOwedLikeAnyOther() throws {
        // `ackBlockedRoomChat` (`InboundPipeline.kt:903-915`) owes it `escalatable`, and the seal has no blocked gate
        // (`MeshManager.kt:1863-1865`): a block stays invisible.
        let fixture = try fixture()
        let seals = EngineSeals(fixture, capable: [bob.nodeId])
        fixture.deliver(try groupMessage("gm-1"), from: carol)
        fixture.engine.block(bob.nodeId)
        fixture.deliver(try groupMessage("gm-2", at: 1), from: carol)
        #expect(fixture.engine.dropped[.blocked] == 1)
        fixture.advance(debounce)
        #expect(seals.originated == [["gm-1", "gm-2"]])
    }
}
