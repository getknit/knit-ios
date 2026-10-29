import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The exists-gate's sealed re-ack, bounded per era (knit-next #176, ADR 2026-10.8hn6): knit-next's `InboundPipelineTest`
/// cases for it (at `afdd37204`) by name where one ports, each read by Android's own session layer (``AndroidPeer``). A DM
/// to us re-delivered past the router's window draws no new sealed receipt while the one we sealed for it was sealed under
/// the root we hold now, inside its floor, and is still live in our custody; it draws exactly one otherwise. Not ported,
/// as the LoRa plane's: `aReServedDmOverLoraStillTakesTheCoalescer`.
@Suite struct MeshEngineReAckTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private var now: Int64 { EngineFixture.start }
    private var floor: Int64 { DmReAckLedger.floorMilliseconds }

    /// The iPhone with the switch on, Alice an Android phone pinned with its prekey and the ratchet's bits, Carol linked as
    /// the neighbour copies come through, and nothing recorded yet.
    private func rig(stores: MeshStores = .inMemory()) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        fixture.link(carol)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    /// A canonical frame id, which the compact layout carries as 16 raw bytes.
    private func canonicalId(_ seed: UInt64) -> String {
        var generator = SeededGenerator(seed: seed)
        return FrameId.generate(using: &generator)
    }

    /// Alice's v3 DM to us, sealed against our prekey.
    private func dm(_ body: String, _ android: AndroidPeer, _ fixture: EngineFixture, id: String, at: Int64? = nil) throws -> TestFrame {
        try android.dm(body, to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: at ?? now, v3: true)
    }

    /// A copy of `frame` through Carol once the router's window has passed: the re-delivery the exists-gate answers.
    private func copy(_ frame: TestFrame, into fixture: EngineFixture, after milliseconds: Int64 = SeenSetWindow.milliseconds) {
        fixture.clock.advance(milliseconds)
        fixture.deliver(frame, from: carol)
    }

    /// Our sealed receipts to Alice's phone, in the order they went.
    private func receiptIds(_ fixture: EngineFixture, _ android: AndroidPeer) -> [String] {
        fixture.sealedReceipts(to: android).map(\.envelope.id)
    }

    // MARK: InboundPipelineTest

    /// `aReServedDeliveredDmIsAnsweredByTheReceiptAlreadySealedInItsEra`: a copy past the router's window, inside the floor,
    /// is answered by the receipt we already sealed in this era and still hold. This replaces
    /// `MeshEngineSealedReceiptTests.aReServedDeliveredDmReAcksInTheSealedForm`, which pinned one sealed receipt per copy.
    @Test func aReServedDeliveredDmIsAnsweredByTheReceiptAlreadySealedInItsEra() throws {
        let (fixture, android) = try rig()
        let id = canonicalId(1)
        let frame = try dm("again", android, fixture, id: id)
        fixture.deliver(frame, from: android)
        let first = try #require(receiptIds(fixture, android).first)

        copy(frame, into: fixture)
        #expect(fixture.stores.messages.messages(in: alice.nodeId.string).count == 1, "delivered once")
        #expect(fixture.transport.written(.receipt).isEmpty, "never a cleartext receipt")
        #expect(receiptIds(fixture, android) == [first], "one sealed receipt for both copies")
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 1, receiptsReAckSkipped: 1))
        #expect(fixture.engine.reAcks.entry(id)?.receiptId == first, "the memo names the first receipt")
        #expect(fixture.engine.reAcks.entry(id)?.rootTag == fixture.engine.ratchet.rootTag(of: alice.nodeId))
    }

    /// `aReServedDmWhoseReceiptLeftOurCustodyReAcks`: our receipt gone from our custody (quota, a sweep) is re-served by
    /// nobody, so the copy re-seals, and the fresh receipt is carried and filed in its place.
    @Test func aReServedDmWhoseReceiptLeftOurCustodyReAcks() throws {
        let (fixture, android) = try rig()
        let id = canonicalId(1)
        let frame = try dm("evicted receipt", android, fixture, id: id)
        fixture.deliver(frame, from: android)
        let first = try #require(receiptIds(fixture, android).first)
        fixture.stores.custody.remove(first)

        copy(frame, into: fixture)
        let receipts = receiptIds(fixture, android)
        #expect(receipts.count == 2 && receipts.last != first, "a fresh receipt, under its own id")
        let second = try #require(receipts.last)
        #expect(fixture.stores.custody.contains(second), "and carried like the first")
        #expect(fixture.engine.reAcks.entry(id)?.receiptId == second)
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 2))
    }

    /// `aReServedDmWhoseReceiptExpiredUnsweptReAcks`: a receipt past its expiry that the sweep has not reached still counts
    /// in `contains`, and is not live, so the copy re-seals. Our custody keeps frames 10 minutes here, so the receipt
    /// expires inside the memo's 15-minute floor; Alice's DM is stamped 4 minutes ahead, so it is still carried then.
    @Test func aReServedDmWhoseReceiptExpiredUnsweptReAcks() throws {
        let stores = MeshStores.inMemory(custodyLimits: CustodyLimits(ttlMilliseconds: 10 * 60_000))
        let (fixture, android) = try rig(stores: stores)
        let id = canonicalId(1)
        let frame = try dm("stale receipt", android, fixture, id: id, at: now + 4 * 60_000)
        fixture.deliver(frame, from: android)
        let first = try #require(receiptIds(fixture, android).first)

        fixture.clock.advance(10 * 60_000 + 1)
        #expect(fixture.stores.custody.contains(first), "unswept")
        #expect(fixture.stores.custody.frame(first, now: fixture.clock.wallMilliseconds()) == nil, "and expired")
        let tag = fixture.engine.ratchet.rootTag(of: alice.nodeId)
        let held = fixture.engine.reAcks.heldReceipt(acked: id, currentRootTag: tag, now: fixture.clock.wallMilliseconds())
        #expect(held == first, "inside the floor, under the root held: only custody tells")
        fixture.deliver(frame, from: carol)
        #expect(receiptIds(fixture, android).count == 2)
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 2))
    }

    /// `aReServedDmPastItsFloorReAcksAndTheFloorDoubles`: held in custody is not applied at the author, so past the floor a
    /// copy re-seals though ours is held, and the floor doubles for the next.
    @Test func aReServedDmPastItsFloorReAcksAndTheFloorDoubles() throws {
        let (fixture, android) = try rig()
        let id = canonicalId(1)
        let frame = try dm("heal me", android, fixture, id: id)
        fixture.deliver(frame, from: android)

        copy(frame, into: fixture, after: floor)
        #expect(fixture.engine.receipts.receiptsSealed == 2, "past 15 minutes, held or not")
        #expect(fixture.engine.reAcks.entry(id)?.step == 1)

        copy(frame, into: fixture, after: floor)
        #expect(fixture.engine.receipts.receiptsSealed == 2, "inside the doubled 30-minute floor")
        #expect(fixture.engine.receipts.receiptsReAckSkipped == 1)

        copy(frame, into: fixture, after: floor)
        #expect(fixture.engine.receipts.receiptsSealed == 3, "30 minutes on, past it")
        #expect(fixture.engine.reAcks.entry(id)?.step == 2)
        #expect(Set(receiptIds(fixture, android)).count == 3, "each under an id of its own")
    }

    /// `aReServedDmAfterAResetDrawsExactlyOneReceiptInTheNewEra`, through our own facade: a reset re-roots the pair, so the
    /// receipt sealed under the old root may be unreadable to an author that dropped that era. The next copy seals exactly
    /// one under the new root, which starts its own floor, and a copy after that is answered by it.
    @Test func aReServedDmAfterAResetDrawsExactlyOneReceiptInTheNewEra() throws {
        let (fixture, android) = try rig()
        let id = canonicalId(1)
        let frame = try dm("before the reset", android, fixture, id: id)
        fixture.deliver(frame, from: android)
        let oldTag = try #require(fixture.engine.ratchet.rootTag(of: alice.nodeId))
        #expect(fixture.engine.reAcks.entry(id)?.rootTag == oldTag)

        let prekey = try #require(PeerPrekey(verifying: android.prekey.info, signedBy: alice.keys.bundle))
        let reset = fixture.engine.ratchet.sealResetDm(
            to: alice.keys.bundle,
            prekey: prekey,
            plaintext: RatchetSessions.resetPlaintext,
            aad: Array("aad".utf8),
            now: fixture.clock.wallMilliseconds()
        )
        guard case .settled(.sealed(_, let plan)) = reset, plan.action == .reRoot else {
            Issue.record("expected a re-root: \(reset)")
            return
        }
        let newTag = try #require(fixture.engine.ratchet.rootTag(of: alice.nodeId))
        #expect(newTag != oldTag)

        copy(frame, into: fixture)
        #expect(fixture.engine.receipts.receiptsSealed == 2, "one receipt for the new era")
        #expect(fixture.engine.reAcks.entry(id)?.rootTag == newTag)
        #expect(fixture.engine.reAcks.entry(id)?.step == 0, "a new era starts its own floor")

        copy(frame, into: fixture)
        #expect(fixture.engine.receipts.receiptsSealed == 2, "and only one")
        #expect(fixture.engine.receipts.receiptsReAckSkipped == 1)
    }

    /// A reset that marks the session held rather than re-rooting it leaves the era where it was: no new receipt.
    @Test func aMarkResetDrawsNoNewReceipt() throws {
        let (fixture, android) = try rig()
        let id = canonicalId(1)
        let frame = try dm("marked", android, fixture, id: id)
        fixture.deliver(frame, from: android)
        let tag = try #require(fixture.engine.ratchet.rootTag(of: alice.nodeId))

        let prekey = try #require(PeerPrekey(verifying: android.prekey.info, signedBy: alice.keys.bundle))
        let reset = fixture.engine.ratchet.sealResetDm(
            to: alice.keys.bundle,
            prekey: prekey,
            plaintext: RatchetSessions.resetPlaintext,
            aad: Array("aad".utf8),
            now: fixture.clock.wallMilliseconds(),
            cause: .afterWipe
        )
        guard case .settled(.sealed(_, let plan)) = reset, plan.action == .mark else {
            Issue.record("expected a mark: \(reset)")
            return
        }
        #expect(fixture.engine.ratchet.rootTag(of: alice.nodeId) == tag, "the root held stays")

        copy(frame, into: fixture)
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 1, receiptsReAckSkipped: 1))
    }

    /// `aReceiptThatOpenedTheSessionAnswersTheNextCopy`: a capable author's DM came v1, so no session was held until the
    /// receipt's own prekey initiation created one. A v1 DM opens nothing in the ratchet, so only the seal's own result can
    /// name that root: a tag read before the seal would be `nil`, and one read of another session would differ.
    @Test func aReceiptThatOpenedTheSessionAnswersTheNextCopy() throws {
        let (fixture, android) = try rig()
        let id = canonicalId(1)
        let frame = try alice.directMessage("hello, stranger", to: me, id: id, sentAt: now)
        #expect(fixture.engine.ratchet.rootTag(of: alice.nodeId) == nil, "no session held")

        fixture.deliver(frame, from: alice)
        let tag = try #require(fixture.engine.ratchet.rootTag(of: alice.nodeId), "the receipt's seal initiated the session")
        #expect(fixture.engine.reAcks.entry(id)?.rootTag == tag)
        #expect(receiptIds(fixture, android).count == 1)

        copy(frame, into: fixture)
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 1, receiptsReAckSkipped: 1))
    }

    // MARK: The port's own

    /// Our wall clock stepped back before the receipt's stamp (a network fix after weeks offline) reads as past the floor:
    /// the copy re-seals once, and the receipt it seals answers the next copy. The monotonic clock does not move, so each
    /// copy is handed past the router as a later copy would arrive.
    @Test func aWallClockSteppedBackBeforeTheReceiptReSealsOnce() throws {
        let (fixture, android) = try rig()
        let id = canonicalId(1)
        let frame = try dm("time travel", android, fixture, id: id)
        fixture.deliver(frame, from: android)

        fixture.clock.stepWall(-60_000)
        fixture.deliverPastRouter(frame, from: carol)
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 2), "re-sealed once")
        #expect(fixture.engine.reAcks.entry(id)?.sealedAt == fixture.clock.wallMilliseconds())
        #expect(fixture.engine.reAcks.entry(id)?.step == 0, "the dropped entry starts again")

        fixture.deliverPastRouter(frame, from: carol)
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 2, receiptsReAckSkipped: 1), "and only once")
    }

    /// The room ticks that ride a DM's receipt are AckSync's: only the DM's own id is filed.
    @Test func theRidersOfAReceiptAreNotRecorded() throws {
        let (fixture, android) = try rig()
        let posts = try (0..<2).map { index in
            let post = canonicalId(100 + UInt64(index))
            fixture.deliver(try alice.roomPost("room \(index)", id: post, sentAt: now + Int64(index)), from: carol)
            return post
        }
        let id = canonicalId(1)
        fixture.deliver(try dm("with riders", android, fixture, id: id), from: android)
        let content = try #require(fixture.sealedReceipts(to: android).first.flatMap { android.peek($0, from: me) })
        #expect(content.ack == id && content.acks == posts, "both rode")

        #expect(fixture.engine.reAcks.count == 1)
        #expect(fixture.engine.reAcks.entry(id) != nil)
        #expect(posts.allSatisfy { fixture.engine.reAcks.entry($0) == nil }, "never the riders")
    }

    /// Only the exists-gate is gated: a first delivery seals whatever the memo holds. Here the memo is made to name a
    /// receipt that is live in our custody under the root held now, so every leg of the gate would hold.
    @Test func aFirstDeliveryAlwaysSeals() throws {
        let (fixture, android) = try rig()
        fixture.deliver(try dm("first", android, fixture, id: canonicalId(1)), from: android)
        let held = try #require(receiptIds(fixture, android).first)
        let tag = try #require(fixture.engine.ratchet.rootTag(of: alice.nodeId))
        let id = canonicalId(2)
        fixture.engine.reAcks.record(acked: id, rootTag: tag, receiptId: held, now: fixture.clock.wallMilliseconds())

        fixture.deliver(try dm("second", android, fixture, id: id), from: android)
        #expect(fixture.stores.messages.message(id)?.body == "second")
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 2), "sealed, never skipped")
        #expect(fixture.engine.reAcks.entry(id)?.receiptId != held)
    }

    /// An author who cannot read a sealed receipt gets the cleartext one at every copy, as before: it purges the DM at every
    /// carrier, which ends the loop by itself, and the memo is never read for it.
    @Test func anIncapableAuthorIsAnsweredInTheClearAtEveryCopy() throws {
        let (fixture, _) = try rig()
        fixture.deliver(try dave.profile(publishedAt: now, capabilities: 0xF), from: dave)
        let id = frameIdOf("v1-plain")
        let frame = try dave.directMessage("old style", to: me, id: id, sentAt: now)
        fixture.deliver(frame, from: dave)
        fixture.clock.advance(SeenSetWindow.milliseconds)
        fixture.deliverPastRouter(frame, from: carol)
        #expect(fixture.acknowledged == [id, id], "a cleartext receipt per copy")
        #expect(fixture.engine.receipts == RatchetReceiptCounts())
        #expect(fixture.engine.reAcks.entry(id) == nil, "nothing filed")
    }
}
