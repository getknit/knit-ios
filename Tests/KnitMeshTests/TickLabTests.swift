import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// Three engines in a line, Bob (0), Carol (1) and Alice (2), acquainted and then with Bob and Alice apart, for the ticks
/// Alice owes Bob (phase P5c of ADR 2026-10.5sk9). With the seams faked to seal on Alice (``EngineSeals``), her group tick
/// goes as one originated frame: served from Carol's custody at the link-up after it went when no link reaches Bob then
/// (knit-next ADR 033's case), or relayed by Carol while he is linked to her. Her room tick is never carried and goes home
/// over the link. With the switch off, the seams as shipped seal nothing, so her ticks wait for the link, cleartext, as they
/// always have. Bob's engine cannot read the stand-in seal, a v1 ctl frame it ignores; with the real seals and the switch on
/// at both ends (phase P5d), his own open of Alice's tick flips each of his ✓✓.
@Suite struct TickLabTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    /// The line: every pair linked once, so each pinned the others, then Bob and Alice apart.
    private func line() -> EngineLab {
        let lab = EngineLab([EngineFixture(bob, seed: 21), EngineFixture(carol, seed: 22), EngineFixture(alice, seed: 23)])
        lab.link(0, 1)
        lab.link(1, 2)
        lab.link(0, 2)
        lab.unlink(0, 2)
        return lab
    }

    /// Moves the line on past a relay's jitter, so what Carol heard reaches her other neighbour.
    private func relay(_ lab: EngineLab) {
        lab.advance(lab[1].engine.configuration.router.jitterWindowMilliseconds)
    }

    /// The DM-form chats Alice wrote toward Bob.
    private func alicesTicks(_ lab: EngineLab) -> [Written] {
        lab[2].transport.written(.chat).filter { $0.envelope.recipientId == bob.nodeId.string }
    }

    @Test func aGroupTickReachesAnAbsentAuthorFromACarriersCustody() throws {
        let lab = line()
        let seals = EngineSeals(lab[2], capable: [bob.nodeId])
        let group = try #require(lab[0].engine.createGroup(with: [carol.nodeId, alice.nodeId]))
        let message = try #require(lab[0].engine.sendGroupMessage("Hi both", to: group.id))
        lab.carry()
        relay(lab)
        #expect(lab[2].stores.messages.message(message.id) != nil, "Alice has it through Carol")
        // No path reaches Bob when the batch goes.
        lab.unlink(0, 1)

        lab.advance(AckSync.batchDebounceMilliseconds)
        relay(lab)
        #expect(seals.originated == [[message.id]])
        let tick = try #require(alicesTicks(lab).first)
        #expect(alicesTicks(lab).count == 1 && tick.to == nil && tick.wire.relay, "one originated frame")
        #expect(lab[1].stores.custody.contains(tick.envelope.id), "Carol carries it")
        #expect(lab[2].stores.custody.contains(tick.envelope.id))
        #expect(!lab[0].stores.custody.contains(tick.envelope.id), "and nothing reaches Bob")

        // Linked to Carol alone, Bob's digest lacks it, and her answer serves it from her custody.
        lab.link(0, 1)
        let served = lab[1].transport.written.filter { ExactKey($0.envelope.id) == ExactKey(tick.envelope.id) && $0.to == bob.nodeId }
        #expect(served.count == 1, "one copy, point to point: Carol's digest answer")
        #expect(alicesTicks(lab).count == 1, "and Alice sent nothing again")
        #expect(lab[0].stores.custody.contains(tick.envelope.id), "Bob holds the tick from Carol's custody")
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)) && Set(lab.liveIds(1)) == Set(lab.liveIds(2)), "the custodies agree")
    }

    /// The real seal's lab, the P5c reviews' owed test, in the shape of the stand-in's above: Bob and Alice with the
    /// ratchet's switch on, Carol without it, carrying, and outside the group, so no tick of hers flips Bob's. Alice's batch
    /// for Bob's two group messages goes as one sealed `CTL_RECEIPT`, her first seal to Bob, so it starts a session. Carol's
    /// custody serves it to Bob at the link-up, Bob's own open of it flips each tick, and Bob answers nothing, since a ctl
    /// frame is never acknowledged. A re-serve of his message past the router's ten minutes owes nothing more, so Alice's
    /// send index does not move.
    @Test func aSealedGroupTickReachesAnAbsentAuthorFromACarriersCustodyAndFlipsEachTick() throws {
        let lab = EngineLab([
            try EngineFixture.ratcheting(bob, seed: 21), EngineFixture(carol, seed: 22), try EngineFixture.ratcheting(alice, seed: 23),
        ])
        lab.link(0, 1)
        lab.link(1, 2)
        lab.link(0, 2)
        lab.unlink(0, 2)
        let group = try #require(lab[0].engine.createGroup(with: [alice.nodeId]))
        let first = try #require(lab[0].engine.sendGroupMessage("Hi", to: group.id))
        let second = try #require(lab[0].engine.sendGroupMessage("Still there?", to: group.id))
        lab.carry()
        relay(lab)
        #expect(lab[2].stores.messages.message(first.id) != nil && lab[2].stores.messages.message(second.id) != nil)
        #expect(lab[0].stores.messages.message(first.id)?.delivered == false, "nobody has ticked them yet")
        lab.unlink(0, 1)
        _ = lab[0].engine.drainEvents()

        lab.advance(AckSync.batchDebounceMilliseconds)
        relay(lab)
        let ticks = alicesTicks(lab)
        let tick = try #require(ticks.first)
        #expect(ticks.count == 1 && tick.to == nil && tick.wire.relay, "one originated, sealed frame")
        #expect(try ChatContent(decoding: tick.envelope.payload).enc?.ratchet?.initial != nil, "her first seal to Bob, an init")
        #expect(lab[1].stores.custody.contains(tick.envelope.id) && lab[2].stores.custody.contains(tick.envelope.id))
        let sent = try #require(lab[2].ratchetRecords(of: bob).session?.sendCount)
        #expect(sent == 1, "one chain key for the batch")

        lab.link(0, 1)
        let served = lab[1].transport.written.filter { ExactKey($0.envelope.id) == ExactKey(tick.envelope.id) && $0.to == bob.nodeId }
        #expect(served.count == 1, "one copy, point to point: Carol's digest answer")
        #expect(lab[0].stores.messages.message(first.id)?.delivered == true, "Bob's own open flips the first tick")
        #expect(lab[0].stores.messages.message(second.id)?.delivered == true, "and the second")
        #expect(Set(deliveredIds(in: lab[0].engine.drainEvents())) == [first.id, second.id])
        #expect(lab[0].ratchetRecords(of: alice).session?.confirmed == true, "Bob holds the session Alice's tick began")
        // Bob's one DM-form frame is his answer to the init Alice's batch carried (phase P5e): never an acknowledgement.
        let fromBob = EngineFixture.once(lab[0].transport.written(.chat)).filter { written in
            written.envelope.senderId == bob.nodeId.string && written.envelope.isDirect
        }
        #expect(fromBob.count == 1 && Set(fromBob.map { ExactKey($0.envelope.id) }) == lab[0].answerIds, "his answer to her init")
        #expect(lab[0].transport.written(.receipt).isEmpty, "a ctl frame is never acknowledged")

        let original = try #require(lab[0].transport.written(.chat).first { $0.envelope.id == first.id })
        lab.advance(SeenSetWindow.milliseconds)
        lab[2].engine.receive(InboundFrame(wire: original.wire, envelope: original.envelope, from: carol.nodeId))
        lab.advance(AckSync.batchDebounceMilliseconds)
        relay(lab)
        #expect(alicesTicks(lab).count == 1, "no second seal")
        #expect(lab[2].ratchetRecords(of: bob).session?.sendCount == sent, "Alice's send index unchanged")
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)) && Set(lab.liveIds(1)) == Set(lab.liveIds(2)), "the custodies agree")
    }

    @Test func aGroupTickReachesAnAbsentAuthorRelayedByCarol() throws {
        let lab = line()
        let seals = EngineSeals(lab[2], capable: [bob.nodeId])
        let group = try #require(lab[0].engine.createGroup(with: [carol.nodeId, alice.nodeId]))
        let message = try #require(lab[0].engine.sendGroupMessage("Hi both", to: group.id))
        lab.carry()
        relay(lab)
        #expect(lab[2].stores.messages.message(message.id) != nil, "Alice has it through Carol")
        #expect(seals.originated.isEmpty && lab[2].engine.footprint.owedTicks == 1, "her tick waits out the debounce")

        lab.advance(AckSync.batchDebounceMilliseconds)
        relay(lab)
        #expect(seals.originated == [[message.id]])
        let tick = try #require(alicesTicks(lab).first)
        #expect(alicesTicks(lab).count == 1 && tick.to == nil && tick.wire.relay)
        for node in 0..<3 {
            #expect(lab[node].stores.custody.contains(tick.envelope.id), "node \(node) carries the tick")
        }
        #expect(EngineSeals.acks(of: tick, as: bob) == [message.id], "Bob holds the tick for his message")
        lab.advance(lab[0].engine.configuration.reofferMilliseconds)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)) && Set(lab.liveIds(1)) == Set(lab.liveIds(2)), "the custodies agree")
    }

    @Test func aRoomTickIsNeverCarriedAndGoesHomeOverTheLink() throws {
        let lab = line()
        let seals = EngineSeals(lab[2], capable: [bob.nodeId])
        let post = try #require(lab[0].engine.postToRoom("Hello room"))
        lab.carry()
        relay(lab)
        lab.advance(AckSync.rideHoldMilliseconds)
        lab.advance(lab[2].engine.configuration.healMilliseconds)
        #expect(lab[2].engine.ackSync.ridingFor(bob.nodeId) == 1, "it waits for a ride or a link")
        #expect(alicesTicks(lab).isEmpty && seals.sealed.isEmpty && seals.originated.isEmpty)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(2)) && Set(lab.liveIds(1)) == Set(lab.liveIds(2)), "no row for a tick anywhere")

        lab.link(0, 2)
        let ticks = alicesTicks(lab)
        let tick = try #require(ticks.first)
        #expect(ticks.count == 1 && tick.to == bob.nodeId && !tick.wire.relay, "one tick, over the link")
        #expect(EngineSeals.acks(of: tick, as: bob) == [post.id])
        #expect((0..<3).allSatisfy { !lab[$0].stores.custody.contains(tick.envelope.id) }, "and no custody holds it")
        #expect(lab[2].engine.footprint.owedTicks == 0)
    }

    @Test func withTheSeamsAsShippedAnAbsentAuthorsTicksWaitForItsLink() throws {
        let lab = line()
        // Alice wrote Bob her profile while they were linked; only what she writes from here on counts.
        let mark = lab[2].transport.written.count
        let group = try #require(lab[0].engine.createGroup(with: [carol.nodeId, alice.nodeId]))
        let message = try #require(lab[0].engine.sendGroupMessage("Hi both", to: group.id))
        let post = try #require(lab[0].engine.postToRoom("Hello room"))
        lab.carry()
        relay(lab)
        lab.advance(AckSync.batchDebounceMilliseconds)
        lab.advance(lab[2].engine.configuration.healMilliseconds)
        #expect(lab[2].transport.written.dropFirst(mark).allSatisfy { $0.to != bob.nodeId }, "nothing of Alice's toward Bob")
        #expect(alicesTicks(lab).isEmpty && lab[2].engine.footprint.owedTicks == 2)

        lab.link(0, 2)
        let ticks = lab[2].transport.written.dropFirst(mark).filter { $0.envelope.type == .receipt && $0.to == bob.nodeId }
        let acked = try ticks.map { try ReceiptContent(decoding: $0.envelope.payload).ackId }
        #expect(Set(acked) == [message.id, post.id] && ticks.count == 2, "cleartext, one per message, at the link")
        #expect(ticks.allSatisfy { !$0.wire.relay && $0.envelope.sentAt == 0 })
        #expect((0..<3).allSatisfy { node in ticks.allSatisfy { !lab[node].stores.custody.contains($0.envelope.id) } })
        #expect(lab[0].stores.messages.message(message.id)?.delivered == true)
    }
}
