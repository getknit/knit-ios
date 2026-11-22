import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A reset our replacement floor refused, held and opened again once the floor ends (knit-next ADR 2026-11.sfms, #251;
/// ADR 2026-10.5sk9's P9b amendment), two sides: the engine under test and Android's own session layer (``AndroidPeer``).
/// After knit-next's `ResetOverRelayLabTest.aResetBobsFloorRefusedIsReOpenedWhenTheFloorEndsAndItsDmLands` and the hold
/// cases of `InboundPipelineTest` at `f018bc8ce`, through the engine's real inbound path, the router's seen set included.
///
/// The shape is the lab's: Android resets, and its reset waits unanswered; a minute later on its own clock it resets again,
/// and both reach us within seconds, so the second lands inside the minute our adoption of the first started. Its restarted
/// `se = 1 n = 0` meets the first reset's row, which used to read as `DUPLICATE` and was never run again.
@Suite struct MeshEngineFlooredResetTests {
    /// The iPhone, whose node id sorts first, so a race against Android is its own to win.
    let me: TestPeer
    let alice: TestPeer
    let bob = TestPeer(seed: 3)
    let carol = TestPeer(seed: 4)
    static let second: Int64 = 1000
    static let minute = RatchetResetPolicy.resetReplacementMilliseconds
    var now: Int64 { EngineFixture.start }

    init() {
        let pair = [TestPeer(seed: 1), TestPeer(seed: 2)].sorted { $0.nodeId < $1.nodeId }
        me = pair[0]
        alice = pair[1]
    }

    /// Where the floored shape leaves the pair: our first reset adopted at `now + 10 s`, the second held.
    struct Floored {
        let fixture: EngineFixture
        let android: AndroidPeer
        /// The second reset's init ephemeral, which an adoption leaves anchored.
        let initEph: [UInt8]
        /// The root our adoption of the first reset left us on.
        let firstRoot: [UInt8]
    }

    /// Android, confirmed on its first contact with us: its opener, our answer, and its open of that answer.
    func confirmed(stores: MeshStores, keychain: KeptSecretStore) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        fixture.deliver(
            try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: frameIdOf("hello"), sentAt: now), from: android)
        let answer = try #require(fixture.answers(to: android).last)
        #expect(plaintext(try android.open(answer, from: me, now: now)) != nil)
        #expect(android.session(with: me)?.confirmed == true, "precondition: Android confirmed, so its next reset re-roots")
        return (fixture, android)
    }

    /// The floored shape: Android's first reset at `now + 10 s`, adopted on arrival; its second at `now + 70 s` by its own
    /// clock, past its own minute, delivered to us at `now + 20 s` through the real inbound path.
    func floored(stores: MeshStores = .inMemory(), keychain: KeptSecretStore? = nil) throws -> Floored {
        let (fixture, android) = try confirmed(stores: stores, keychain: keychain ?? KeptSecretStore(me.keys.storedForm))
        let prekey = try fixture.ourPrekey()
        fixture.clock.advance(10 * Self.second)
        fixture.deliver(try android.resetDm(to: me, prekey: prekey, id: frameIdOf("reset-1"), at: now + 10 * Self.second), from: android)
        let first = try #require(fixture.ratchetRecords(of: alice).session)
        #expect(first.establishedAt == now + 10 * Self.second, "the first reset adopted")
        fixture.clock.advance(10 * Self.second)
        let reset = try android.resetDm(to: me, prekey: prekey, id: frameIdOf("reset-2"), at: now + 70 * Self.second)
        let eph = try #require(try ChatContent(decoding: reset.envelope.payload).enc?.ratchet?.initial?.eph)
        fixture.deliver(reset, from: android)
        #expect(fixture.engine.dropped[.ratchetResetFloored] == 1, "floored, never a duplicate")
        #expect(fixture.engine.dropped[.ratchetDuplicate] == nil)
        #expect(fixture.ratchetRecords(of: alice).session?.root == first.root, "refused: nothing moved")
        return Floored(fixture: fixture, android: android, initEph: eph, firstRoot: first.root)
    }

    /// Three DMs Android sealed under its second reset, each carrying its init unflagged, delivered to us at `now + 25 s`:
    /// counted, they would cross the heuristic's three distinct frames and fire our own reset.
    func followUps(_ shape: Floored) throws -> [String] {
        shape.fixture.clock.advance(5 * Self.second)
        let prekey = try shape.fixture.ourPrekey()
        return try (1...RatchetResetPolicy.distinctFrames).map { index in
            let id = frameIdOf("under-second-\(index)")
            let sentAt = now + 70 * Self.second + Int64(index)
            shape.fixture.deliver(
                try shape.android.dm("under the second reset \(index)", to: me, prekey: prekey, id: id, sentAt: sentAt), from: shape.android
            )
            return id
        }
    }

    /// Moves our wall clock to `now + offset`, firing nothing.
    func clock(_ shape: Floored, at offset: Int64) {
        shape.fixture.clock.advance(now + offset - shape.fixture.clock.wallMilliseconds())
    }

    /// The lab's trace (`aResetBobsFloorRefusedIsReOpenedWhenTheFloorEndsAndItsDmLands`): the hold is taken; its follow-ups
    /// are explained, never counted; the re-open stays shut a millisecond inside the minute and runs at it; the adoption is
    /// answered, which confirms Android under its second reset; the backlog delivers every follow-up out of our custody; a DM
    /// crosses each way; and we never reset back. A copy of the reset served again goes no further than the router's seen
    /// set, which is why the re-open goes around it.
    @Test func aResetOurFloorRefusedIsReOpenedWhenTheFloorEndsAndItsDmsLand() throws {
        let shape = try floored()
        let (fixture, android) = (shape.fixture, shape.android)
        #expect(fixture.engine.flooredCounts.flooredResetsHeld == 1)
        #expect(fixture.log.all.contains { $0.contains("mesh holding floored reset \(frameIdOf("reset-2")) from \(alice.nodeId)") })
        let dms = try followUps(shape)
        #expect(fixture.resetsSent(to: alice).isEmpty, "the follow-ups ride the reset we hold: no evidence")
        #expect(fixture.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 0)
        #expect(fixture.log.all.contains { $0.contains("rides the reset we hold floored") })
        fixture.deliver(try reServe(frameIdOf("reset-2"), in: fixture), from: carol)
        #expect(fixture.engine.dropped[.ratchetResetFloored] == 1, "the router's seen set holds its id")

        clock(shape, at: 10 * Self.second + Self.minute - 1)
        fixture.engine.reopenFlooredResets()
        #expect(fixture.engine.flooredCounts.flooredResetsReopened == 0, "shut a millisecond inside the minute")
        #expect(fixture.ratchetRecords(of: alice).session?.root == shape.firstRoot)
        clock(shape, at: 10 * Self.second + Self.minute)
        fixture.engine.reopenFlooredResets()
        #expect(
            fixture.engine.flooredCounts == RatchetFlooredCounts(flooredResetsHeld: 1, flooredResetsReopened: 1, flooredResetsAdopted: 1))
        let adopted = try #require(fixture.ratchetRecords(of: alice).session)
        #expect(adopted.peerInitEphPub == shape.initEph, "the second reset adopted")
        #expect(
            fixture.log.all.contains { $0.contains("mesh re-opened floored reset \(frameIdOf("reset-2")) from \(alice.nodeId): adopted") })
        for (index, id) in dms.enumerated() {
            #expect(fixture.stores.messages.message(id)?.body == "under the second reset \(index + 1)", "the backlog delivered it")
        }
        // Run again, the backlog stops at the rows it wrote.
        fixture.engine.replayFlooredResetBacklog(of: alice.nodeId, initEph: shape.initEph, except: frameIdOf("reset-2"))
        #expect(fixture.engine.dropped[.ratchetDuplicate] == nil)

        let answer = try #require(fixture.answers(to: android).last)
        #expect(plaintext(try android.open(answer, from: me, now: now + 71 * Self.second)) != nil)
        let theirs = try #require(android.session(with: me))
        #expect(theirs.confirmed && theirs.root == adopted.root, "Android confirmed on its second reset's root")

        let back = try #require(fixture.engine.sendDirectMessage("back to you", to: alice.nodeId))
        let written = try #require(fixture.transport.written(.chat).last { $0.envelope.id == back.id })
        #expect(android.peek(written, from: me)?.body == "back to you")
        fixture.deliver(
            try android.dm("and to you", to: me, prekey: try fixture.ourPrekey(), id: frameIdOf("after"), sentAt: now + 73 * Self.second),
            from: android)
        #expect(fixture.stores.messages.message(frameIdOf("after"))?.body == "and to you")
        #expect(fixture.ratchetRecords(of: alice).session?.lastResetSentAt == 0, "we never reset back")
    }

    /// The re-open is the 60-second re-offer's: the tick past the floor runs it, with nobody linked.
    @Test func theReOffersTickRunsTheReOpen() throws {
        let shape = try floored()
        shape.fixture.advance(MeshConfiguration().reofferMilliseconds)
        #expect(shape.fixture.engine.flooredCounts.flooredResetsAdopted == 1)
        #expect(shape.fixture.ratchetRecords(of: alice).session?.peerInitEphPub == shape.initEph)
    }

    /// Our own re-root since the hold is a root change: the hold is dropped, never run, and our reset stands.
    @Test func aRootChangeDropsTheHold() throws {
        let shape = try floored()
        guard case .sent(_, reRooted: true) = shape.fixture.engine.sendRatchetReset(to: alice.nodeId) else {
            Issue.record("our re-root goes")
            return
        }
        let ours = try #require(shape.fixture.ratchetRecords(of: alice).session)
        clock(shape, at: 10 * Self.second + Self.minute)
        shape.fixture.engine.reopenFlooredResets()
        #expect(shape.fixture.engine.flooredCounts == RatchetFlooredCounts(flooredResetsHeld: 1, flooredResetsDropped: 1))
        #expect(shape.fixture.ratchetRecords(of: alice).session?.root == ours.root, "still on our own reset")
        #expect(shape.fixture.log.all.contains { $0.contains("the session's root moved since it was held") })
    }

    /// Another peer's session changing, a first contact and then an adopted reset, moves only that peer's root generation:
    /// Alice's hold stands and opens. Read off the facade's one global counter, which moves at any peer's settlement, the hold
    /// would be dropped and the floored reset lost for good.
    @Test func anotherPeersRootChangeLeavesTheHoldStanding() throws {
        let shape = try floored()
        let fixture = shape.fixture
        let other = try AndroidPeer(bob)
        try fixture.pin(other)
        let generation = fixture.engine.ratchet.generation
        fixture.deliver(
            try other.dm("hi", to: me, prekey: try fixture.ourPrekey(), id: frameIdOf("bob-hello"), sentAt: now + 20 * Self.second),
            from: other)
        let answer = try #require(fixture.answers(to: other).last)
        #expect(plaintext(try other.open(answer, from: me, now: now + 20 * Self.second)) != nil)
        fixture.deliver(
            try other.resetDm(to: me, prekey: try fixture.ourPrekey(), id: frameIdOf("bob-reset"), at: now + 21 * Self.second), from: other)
        #expect(fixture.engine.ratchet.rootGeneration(of: bob.nodeId) == 1, "Bob's reset adopted")
        #expect(fixture.engine.ratchet.generation > generation, "the global counter moved")
        clock(shape, at: 10 * Self.second + Self.minute)
        fixture.engine.reopenFlooredResets()
        #expect(fixture.engine.flooredCounts.flooredResetsAdopted == 1)
        #expect(fixture.ratchetRecords(of: alice).session?.peerInitEphPub == shape.initEph)
    }

    /// The flag rides outside a v2 frame's AEAD, so only a signed frame is held: an unsigned frame carrying a flagged init,
    /// one the live-link tick's door admits, is counted as floored and held nowhere.
    @Test func anUnsignedFrameIsNeverHeld() throws {
        let shape = try floored()
        let (fixture, android) = (shape.fixture, shape.android)
        let tick = try android.dm(
            MessageContent(body: "tick"),
            to: me,
            prekey: try fixture.ourPrekey(),
            id: frameIdOf("unsigned"),
            sentAt: now + 71 * Self.second,
            v3: true,
            signed: false,
            relay: false
        ) { $0.ratchet?.flags = RatchetHeader.resetFlag }
        fixture.deliver(tick, from: android)
        #expect(fixture.engine.dropped[.ratchetResetFloored] == 2, "floored")
        #expect(fixture.engine.flooredCounts.flooredResetsHeld == 1, "but not held")
        #expect(fixture.log.all.contains { $0.contains("mesh no hold for floored reset \(frameIdOf("unsigned"))") })
    }

    /// One entry per peer, the newest by the sender's own stamp: a later reset replaces the one held, and an earlier one
    /// arriving after it is kept out. The re-open adopts the newest.
    @Test(arguments: [false, true]) func theNewestResetByTheSendersStampIsTheOneHeld(newestFirst: Bool) throws {
        let (fixture, android) = try confirmed(stores: .inMemory(), keychain: KeptSecretStore(me.keys.storedForm))
        let prekey = try fixture.ourPrekey()
        fixture.clock.advance(10 * Self.second)
        fixture.deliver(try android.resetDm(to: me, prekey: prekey, id: frameIdOf("reset-1"), at: now + 10 * Self.second), from: android)
        let older = try android.resetDm(to: me, prekey: prekey, id: frameIdOf("reset-2"), at: now + 70 * Self.second)
        let newer = try android.resetDm(to: me, prekey: prekey, id: frameIdOf("reset-3"), at: now + 130 * Self.second)
        fixture.clock.advance(10 * Self.second)
        for frame in newestFirst ? [newer, older] : [older, newer] {
            fixture.deliver(frame, from: android)
        }
        #expect(fixture.engine.dropped[.ratchetResetFloored] == 2)
        let counts = fixture.engine.flooredCounts
        #expect(newestFirst ? counts.flooredResetsHeld == 1 : counts == RatchetFlooredCounts(flooredResetsHeld: 2, flooredResetsDropped: 1))
        fixture.clock.advance(Self.minute)
        fixture.engine.reopenFlooredResets()
        #expect(fixture.ratchetRecords(of: alice).session?.root == android.session(with: me)?.root, "the newest adopted")
    }

    /// iOS ends a suspended Knit often, and the hold and the floor die with it. The start's replay out of our custody holds
    /// the reset again whatever the dead floor said, moving no era, and the re-open runs it as a first verdict, its backlog
    /// with it (ADR 2026-10.5sk9's P9b amendment). Here the restart comes inside the minute, where Android loses the re-open.
    @Test func theStartsReplayHoldsTheResetAgainAcrossARestart() throws {
        let stores = MeshStores.inMemory()
        let keychain = KeptSecretStore(me.keys.storedForm)
        let shape = try floored(stores: stores, keychain: keychain)
        let dms = try followUps(shape)

        let restarted = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: now + 30 * Self.second, seed: 8)
        #expect(restarted.engine.flooredCounts.flooredResetsHeld == 1, "held again at the start's replay")
        #expect(restarted.ratchetRecords(of: alice).session?.root == shape.firstRoot, "the replay moved no era")
        #expect(restarted.resetsSent(to: alice).isEmpty)
        restarted.engine.reopenFlooredResets()
        #expect(restarted.engine.flooredCounts.flooredResetsAdopted == 1)
        #expect(restarted.ratchetRecords(of: alice).session?.peerInitEphPub == shape.initEph)
        for id in dms {
            #expect(restarted.stores.messages.message(id) != nil, "the backlog delivered \(id)")
        }
        let answer = try #require(restarted.answers(to: shape.android).last)
        #expect(plaintext(try shape.android.open(answer, from: me, now: now + 71 * Self.second)) != nil)
        #expect(shape.android.session(with: me)?.confirmed == true)
    }

    /// Custody keeps a frame a spool served without saying so, and a spool's frame is never evidence (ADR 2026-11.adrq), so
    /// the backlog opens as a first verdict and counts nothing: three frames carrying the reset's init that still fail after
    /// the adoption, in custody as a spool's door leaves them, buy no reset.
    @Test func aBacklogFrameFromASpoolIsNeverCounted() throws {
        let shape = try floored()
        let (fixture, android) = (shape.fixture, shape.android)
        let prekey = try fixture.ourPrekey()
        for index in 1...RatchetResetPolicy.distinctFrames {
            let frame = try android.dm(
                MessageContent(body: "spoiled \(index)"),
                to: me,
                prekey: prekey,
                id: frameIdOf("spoiled-\(index)"),
                sentAt: now + 70 * Self.second + Int64(index)
            ) { $0.ct[0] ^= 1 }
            let carried = CarriedFrame(envelope: frame.envelope, sig: frame.wire.sig, signed: frame.wire.signed)
            _ = fixture.stores.custody.store(carried, origin: .relayed, now: fixture.clock.wallMilliseconds())
        }
        clock(shape, at: 10 * Self.second + Self.minute)
        fixture.engine.reopenFlooredResets()
        #expect(fixture.engine.flooredCounts.flooredResetsAdopted == 1)
        #expect(fixture.engine.dropped[.ratchetAeadFail] == RatchetResetPolicy.distinctFrames, "each replayed, and failed")
        #expect(fixture.resetsSent(to: alice).isEmpty, "no evidence")
        #expect(fixture.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 0)
    }

    /// A sender blocked since the hold: the re-open hands the frame to the chat door, which delivers nothing from a blocked
    /// sender, and says it was not adopted.
    @Test func aReOpenTheChatDoorRefusesIsNotAdopted() throws {
        let shape = try floored()
        shape.fixture.engine.block(alice.nodeId)
        clock(shape, at: 10 * Self.second + Self.minute)
        shape.fixture.engine.reopenFlooredResets()
        #expect(shape.fixture.engine.flooredCounts.flooredResetsReopened == 1)
        #expect(shape.fixture.engine.flooredCounts.flooredResetsAdopted == 0)
        #expect(shape.fixture.log.all.contains { $0.contains("from \(alice.nodeId): not adopted") })
    }

    /// The custody copy of `id`, as a carrier serves it again.
    func reServe(_ id: String, in fixture: EngineFixture) throws -> TestFrame {
        let carried = try #require(fixture.stores.custody.frame(id, now: fixture.clock.wallMilliseconds()))
        return TestFrame(wire: WireEnvelope(sig: carried.sig, signed: carried.signed), envelope: carried.envelope)
    }
}
