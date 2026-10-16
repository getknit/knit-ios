import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The seams this build ships (``RatchetTickSeals``, ADR 2026-10.5sk9, phase P5d) asked inside a store unit their caller
/// opened, the P5c crypto review's nesting case and the P5d review's commit after it: a seal joined to the caller's unit
/// answers "nothing went" and puts nothing on the air, and what it wrote stands or falls with that unit. Nothing opens a
/// unit around a seam today; these pin what one would leave behind. Alice is the iPhone, Bob an Android author pinned with
/// his prekey, and Carol the neighbour his frames come through.
@Suite struct MeshEngineSealedTickUnitTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let start = EngineFixture.start
    private let debounce = AckSync.batchDebounceMilliseconds

    /// Alice's engine with the switch on, Bob an Android phone pinned with its prekey and away, and Carol linked.
    private func rig() throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(alice)
        let android = try AndroidPeer(bob)
        try fixture.pin(android)
        fixture.link(carol)
        fixture.transport.clear()
        return (fixture, android)
    }

    /// A canonical frame id, which the compact layout carries as 16 raw bytes.
    private func canonicalId(_ seed: UInt64) -> String {
        var generator = SeededGenerator(seed: seed)
        return FrameId.generate(using: &generator)
    }

    private func groupMessage(_ id: String) throws -> TestFrame {
        try bob.groupMessage("Hi \(id)", in: roster([bob, carol, alice], createdBy: bob), to: [alice, carol], id: id, sentAt: start)
    }

    /// The DM-form chats of ours toward Bob: our sealed ticks.
    private func sealedTicks(_ fixture: EngineFixture) -> [Written] {
        fixture.transport.written(.chat).filter { written in
            written.envelope.recipientId == bob.nodeId.string && written.envelope.senderId == alice.nodeId.string
        }
    }

    /// The ids our cleartext ticks acknowledged, in order.
    private func clearlyTicked(_ fixture: EngineFixture) throws -> [String] {
        try fixture.transport.written(.receipt).map { try ReceiptContent(decoding: $0.envelope.payload).ackId }
    }

    /// Each seam asked inside a unit its caller opened, as the P5c crypto review asks (`RatchetSessionsNestingTests`' shape):
    /// a seal joined to the caller's unit cannot go before an outer commit it never sees, so each answers "nothing went",
    /// nothing goes on the air, and the abandoned unit takes the joined seals with it.
    @Test func eachSealAskedInsideAUnitAnswersNothingAndPutsNothingOnTheAir() throws {
        let (fixture, _) = try rig()
        fixture.link(bob)
        fixture.transport.clear()
        let seals = RatchetTickSeals(engine: fixture.engine)
        var readable = false
        var live: WireEnvelope?
        var went = true
        let outer = fixture.stores.transactor.atomically { () -> Void? in
            readable = seals.canSeal(bob.nodeId)
            live = seals.sealTick(to: bob.nodeId, acks: [canonicalId(1)])
            went = seals.originateTick(to: bob.nodeId, acks: [canonicalId(1), canonicalId(2)])
            return nil
        }
        guard case .abandoned = outer else {
            Issue.record("the outer unit abandons: \(outer)")
            return
        }
        #expect(readable, "a read, which a unit may make")
        #expect(live == nil && !went)
        #expect(fixture.transport.written.isEmpty, "nothing on the air")
        #expect(fixture.ratchetRecords(of: bob) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
    }

    /// The same seams inside a caller's unit that then commits (the P5d crypto review's second finding): each still answers
    /// "nothing went" and puts nothing on the air, but what its seal wrote stands with the outer unit. Both seals' chain
    /// advances stand, each key spent once, and the originated tick stands in our custody, unflooded and unmarked, where
    /// the next custody exchange serves it. The live-link tick, never carried, leaves only its advance.
    @Test func eachSealAskedInsideAUnitThatCommitsLeavesItsAdvanceAndTheOriginatedTickInCustody() throws {
        let (fixture, android) = try rig()
        fixture.link(bob)
        fixture.transport.clear()
        let seals = RatchetTickSeals(engine: fixture.engine)
        let seen = fixture.engine.router.seenCount
        var live: WireEnvelope?
        var went = true
        let outer = fixture.stores.transactor.atomically { () -> Void? in
            live = seals.sealTick(to: bob.nodeId, acks: [canonicalId(1)])
            went = seals.originateTick(to: bob.nodeId, acks: [canonicalId(2), canonicalId(3)])
            return ()
        }
        guard case .committed = outer else {
            Issue.record("the outer unit commits: \(outer)")
            return
        }
        #expect(live == nil && !went, "each answers that nothing went")
        #expect(fixture.transport.written.isEmpty && fixture.engine.router.seenCount == seen, "nothing on the air, nothing marked")
        #expect(fixture.ratchetRecords(of: bob).session?.sendCount == 2, "both advances stand, a key each")
        let carried = fixture.stores.custody.liveFrames(now: fixture.clock.wallMilliseconds()).filter { frame in
            frame.envelope.type == .chat && frame.envelope.recipientId == bob.nodeId.string
        }
        #expect(carried.count == 1, "the originated tick stands in our custody, the live one nowhere")
        #expect(fixture.engine.receipts == RatchetReceiptCounts(), "and neither counts as sealed")

        fixture.engine.receiveDigest([], from: carol.nodeId)
        let served = try #require(sealedTicks(fixture).first)
        #expect(sealedTicks(fixture).count == 1 && served.to == carol.nodeId, "the next exchange serves it")
        #expect(android.receiptAcks(served, from: alice) == [canonicalId(2), canonicalId(3)])
    }

    /// Through the ledger: a batch that falls due inside a caller's unit that then commits goes in both forms. Its seal
    /// joined the unit, so `originateTick` answered `false` and the ledger kept the ids as cleartext entries, while the
    /// committed unit left the sealed batch in our custody. At Bob's link-up the entries go in the clear and the custody
    /// exchange serves the sealed batch: the tick the seal hides, also shown in the clear. Nothing opens a unit around the
    /// ledger today, and P6's standing rule keeps `acknowledge` out of one.
    @Test func aBatchDueInsideAUnitThatCommitsGoesInBothForms() throws {
        let (fixture, android) = try rig()
        let message = canonicalId(1)
        fixture.deliver(try groupMessage(message), from: carol)
        fixture.clock.advance(debounce)
        let outer = fixture.stores.transactor.atomically { () -> Void? in
            fixture.engine.flushDueTickBatches(now: fixture.clock.monotonicMilliseconds())
            return ()
        }
        guard case .committed = outer else {
            Issue.record("the outer unit commits: \(outer)")
            return
        }
        #expect(sealedTicks(fixture).isEmpty && fixture.engine.footprint.owedTicks == 1, "the id a cleartext entry")

        fixture.link(bob)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(try clearlyTicked(fixture) == [message], "the entry in the clear")
        let sealed = try #require(sealedTicks(fixture).first)
        #expect(android.receiptAcks(sealed, from: alice) == [message], "and the batch, sealed, from custody")
    }
}
