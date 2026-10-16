import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A DM's receipt sealed with the ratchet's switch on (ADR 2026-10.5sk9, phase P5d): knit-next's `InboundPipelineTest`
/// receipt cases by name (`InboundPipelineTest.kt:5788-6221`, at `cbf2a487`), each read by Android's own session layer
/// (``AndroidPeer``). A DM to us from an author who can read one answers with one `CTL_RECEIPT`, its `ack` and up to eleven
/// room ticks riding, originated, and purging nothing, ours included; an author who cannot, and a seal the facade cannot
/// make, get the cleartext receipt and its self-purge, and a store that fails sends none. Not ported, as the LoRa plane's:
/// `aDmHeardOverLoraHoldsItsReceiptThenTicksOnce` and `anIncapableAuthorsLoraDmKeepsTheInstantCleartextReceipt`; every
/// receipt here goes at once, as `aDmHeardOverBluetoothStillAcksInstantly` has it.
@Suite struct MeshEngineSealedReceiptTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private var now: Int64 { EngineFixture.start }

    /// The iPhone with the switch on, Alice an Android phone pinned with its prekey and the ratchet's bits, Carol linked as
    /// the neighbour Alice's frames come through, and nothing recorded yet.
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

    /// `author`'s room posts, Alice's unless told, delivered through Carol while the author is away: each one's tick waits in
    /// the author's ride hold.
    private func roomTicksWaiting(_ count: Int, in fixture: EngineFixture, by author: TestPeer? = nil) throws -> [String] {
        try (0..<count).map { index in
            let id = canonicalId(100 + UInt64(index))
            fixture.deliver(try (author ?? alice).roomPost("room \(index)", id: id, sentAt: now + Int64(index)), from: carol)
            return id
        }
    }

    // MARK: InboundPipelineTest

    /// `aDeliveredDmAcksSealedWhenTheAuthorIsCapable` (`InboundPipelineTest.kt:5788-5806`), with
    /// `aDmHeardOverBluetoothStillAcksInstantly`'s instant receipt: an ordinary ctl chat, never a cleartext `receipt`, dated
    /// by our clock so custody keeps it a day, and the delivered DM stays in our own custody.
    @Test func aDeliveredDmAcksSealedWhenTheAuthorIsCapable() throws {
        let (fixture, android) = try rig()
        let id = canonicalId(1)
        fixture.deliver(try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: now, v3: true), from: android)
        #expect(fixture.stores.messages.message(id)?.body == "hello")
        #expect(fixture.transport.written(.receipt).isEmpty, "never a cleartext receipt")

        let receipts = fixture.sealedReceipts(to: android)
        let receipt = try #require(receipts.first)
        #expect(receipts.count == 1 && receipt.to == nil && receipt.wire.relay, "one, originated: flooded")
        #expect(receipt.envelope.sentAt == fixture.clock.wallMilliseconds() && receipt.envelope.recipientId == alice.nodeId.string)
        #expect(me.keys.bundle.isValidSignature(receipt.wire.sig, for: receipt.wire.signed), "signed once, and it verifies")
        let enc = try #require(try ChatContent(decoding: receipt.envelope.payload).enc)
        #expect(enc.version == EncEnvelope.Version.compactRatchet && enc.nonce.isEmpty, "v3, the author reads it")
        let content = try #require(android.peek(receipt, from: me))
        #expect(content.ctl == MessageContent.Control.receipt && content.ack == id && content.acks == nil)
        #expect(fixture.stores.custody.contains(receipt.envelope.id), "carried, like the message it acknowledges")
        #expect(fixture.stores.custody.contains(id), "and the DM stays: a sealed receipt purges nothing, ours included")
        #expect(!fixture.engine.custody.isTombstoned(id, now: fixture.clock.wallMilliseconds()))
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 1), "counted as Android counts it")
    }

    /// `aSealedDmReceiptCarriesTheRoomTicksWaitingForItsAuthor` (`InboundPipelineTest.kt:5810-5829`): a frame already
    /// sealed to that author is a ride for its room ticks, said to have ridden only once its unit commits, so a re-serve
    /// of the post owes nothing more.
    @Test func aSealedDmReceiptCarriesTheRoomTicksWaitingForItsAuthor() throws {
        let (fixture, android) = try rig()
        let posts = try roomTicksWaiting(2, in: fixture)
        #expect(fixture.engine.ackSync.ridingFor(alice.nodeId) == 2, "Alice is away: her room ticks wait for a ride")
        let id = canonicalId(1)
        fixture.deliver(try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: now, v3: true), from: android)

        let receipts = fixture.sealedReceipts(to: android)
        #expect(receipts.count == 1, "one frame toward Alice, the receipt")
        let content = try #require(receipts.first.flatMap { android.peek($0, from: me) })
        #expect(content.ack == id && content.acks == posts, "both room ticks rode the receipt")
        #expect(fixture.engine.ackSync.ridingFor(alice.nodeId) == 0, "nothing left waiting")
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 1, receiptsRidden: 2))

        fixture.clock.advance(SeenSetWindow.milliseconds)
        fixture.deliver(try alice.roomPost("room 0", id: posts[0], sentAt: now), from: carol)
        #expect(
            fixture.engine.ackSync.ridingFor(alice.nodeId) == 0 && fixture.engine.footprint.owedTicks == 0, "and a re-serve parks nothing")
    }

    /// The bound Kotlin sizes for the LoRa hop (`DmAckCoalescer.MAX_LORA_TICK_ACKS - 1`, `InboundPipeline.kt:2924`), the
    /// analog of `aCoalescedTickNeverCarriesMoreRidersThanTheLoraHopFits` for the receipt: eleven ride, the oldest, and the
    /// rest wait for the next carrier.
    @Test func aSealedDmReceiptCarriesAtMostElevenRoomTicks() throws {
        let (fixture, android) = try rig()
        let posts = try roomTicksWaiting(13, in: fixture)
        let id = canonicalId(1)
        fixture.deliver(try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: now, v3: true), from: android)
        let content = try #require(fixture.sealedReceipts(to: android).first.flatMap { android.peek($0, from: me) })
        #expect(content.acks == Array(posts.prefix(RatchetOutbound.maxReceiptRiders)), "the eleven oldest")
        #expect(fixture.engine.ackSync.ridingFor(alice.nodeId) == 2, "the rest wait for the next carrier")
    }

    /// `anIncapableAuthorsDmGetsTheCleartextReceiptAndSelfVaccinates` (`InboundPipelineTest.kt:6183-6201`), with the switch
    /// on: a pinned peer whose profile lacks `CAP_RATCHET` gets the cleartext receipt, and our custody follows the rule every
    /// carrier applies to it: captured at delivery, purged at once, and tombstoned against a re-plant.
    @Test func anIncapableAuthorsDmGetsTheCleartextReceiptAndSelfVaccinates() throws {
        let (fixture, android) = try rig()
        fixture.deliver(try dave.profile(publishedAt: now, capabilities: 0xF), from: dave)
        let frame = try dave.directMessage("old style", to: me, id: "v1-dm1", sentAt: now)
        fixture.deliver(frame, from: dave)
        #expect(fixture.stores.messages.message("v1-dm1")?.body == "old style")
        #expect(fixture.acknowledged == ["v1-dm1"], "the cleartext receipt, the old author's build reads nothing else")
        #expect(fixture.sealedReceipts(to: android).isEmpty && fixture.transport.written(.chat).isEmpty)
        #expect(fixture.engine.receipts == RatchetReceiptCounts(), "an author who cannot read one counts nothing")
        #expect(!fixture.stores.custody.contains("v1-dm1"), "purged right out of our own custody")
        fixture.clock.advance(SeenSetWindow.milliseconds)
        fixture.deliver(frame, from: carol)
        #expect(!fixture.stores.custody.contains("v1-dm1"), "and a stale carrier's re-plant is refused")
        #expect(fixture.ratchetRecords(of: dave) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
    }

    /// `aReServedDeliveredDmReAcksInTheSealedForm` (`InboundPipelineTest.kt:6204-6219`): delivered once, re-acknowledged per
    /// copy at the exists-gate, both sealed, each under an id of its own.
    @Test func aReServedDeliveredDmReAcksInTheSealedForm() throws {
        let (fixture, android) = try rig()
        let id = canonicalId(1)
        let frame = try android.dm("again", to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: now, v3: true)
        fixture.deliver(frame, from: android)
        fixture.deliverPastRouter(frame, from: alice)
        #expect(fixture.stores.messages.messages(in: alice.nodeId.string).count == 1, "delivered once")
        #expect(fixture.transport.written(.receipt).isEmpty)
        #expect(fixture.acknowledged(by: android) == [id, id], "re-acked per copy, sealed")
        #expect(Set(fixture.sealedReceipts(to: android).map(\.envelope.id)).count == 2, "a fresh id each")
    }

    // MARK: The prekey path, and seals that fail

    /// The prekey path (`sealDmReceipt`'s doc, `InboundPipeline.kt:2888-2894`): a capable author whose DM came v1, sent before
    /// our profile reached it, gets a sealed receipt all the same, under a session the receipt starts, which Android answers.
    @Test func aCapableAuthorsV1DmIsAcknowledgedUnderASessionTheReceiptStarts() throws {
        let (fixture, android) = try rig()
        let id = canonicalId(1)
        fixture.deliver(try alice.directMessage("sent v1", to: me, id: id, sentAt: now), from: alice)
        #expect(fixture.stores.messages.message(id)?.body == "sent v1")
        let receipt = try #require(fixture.sealedReceipts(to: android).first)
        let enc = try #require(try ChatContent(decoding: receipt.envelope.payload).enc)
        #expect(enc.version == EncEnvelope.Version.compactRatchet)
        #expect(enc.ratchet?.initial?.pkid == android.prekey.id, "an X3DH init against Android's prekey")
        #expect(fixture.ratchetRecords(of: alice).session?.weAreInitiator == true)
        let opened = try android.open(receipt, from: me, now: fixture.clock.wallMilliseconds())
        let content = try #require(plaintext(opened).flatMap(MessageContentV2.decode))
        #expect(content.ctl == MessageContent.Control.receipt && content.ack == id, "Android reads it as a responder")
        #expect(fixture.stores.custody.contains(id), "and nothing was purged")
    }

    /// The facade's `unavailable` (no session and no usable prekey): Dave claims the bits with no prekey, so the receipt
    /// goes in the clear, with its self-purge, and the room tick it took goes back with its stamp.
    @Test func aSealTheFacadeCannotMakeGoesInTheClearAndGivesItsRiderBack() throws {
        let (fixture, _) = try rig()
        fixture.deliver(try dave.profile(publishedAt: now, capabilities: AndroidPeer.capabilities), from: dave)
        #expect(fixture.stores.peers.peer(dave.nodeId)?.prekey == nil)
        _ = try roomTicksWaiting(1, in: fixture, by: dave)
        let stamp = try #require(fixture.engine.ackSync.riding[dave.nodeId]?.first?.at)
        fixture.clock.advance(1000)

        fixture.deliver(try dave.directMessage("no prekey", to: me, id: "v1-np", sentAt: now), from: dave)
        #expect(fixture.acknowledged == ["v1-np"], "the cleartext receipt")
        #expect(fixture.transport.written(.chat).isEmpty && !fixture.stores.custody.contains("v1-np"), "and its self-purge")
        #expect(fixture.engine.ackSync.riding[dave.nodeId]?.map(\.at) == [stamp], "the rider back, with its stamp")
        #expect(fixture.ratchetRecords(of: dave).session == nil, "no key moved")
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealedFallback: 1), "the seal that fell through, counted")
    }

    /// A store that fails mid-seal, over both store kinds: nothing goes on the air, sealed or cleartext, no chain advances,
    /// nothing is purged, and the room tick the receipt took is back in its hold with its stamp. This is Kotlin's level: its
    /// seal throws out of `sealDmReceipt`, and nothing goes (`RatchetSessions.kt:247`, `:259`, `InboundPipeline.kt:304`;
    /// ADR 2026-10.5sk9's P5d amendment, decided at review). The DM stays in our custody, and our digest lists it, so its
    /// tick waits until a copy reaches us past the router's window: a back-fill once our quotas evict it, or a re-flood of
    /// a copy some node took from another holder before ours crossed to it, through whatever neighbour relays it. Such a
    /// copy is acknowledged sealed once the store heals, and the tick rides it.
    @Test(arguments: StoreKind.allCases)
    func aStoreThatFailsMidSealSendsNoReceiptAndGivesTheRiderBack(kind: StoreKind) throws {
        let directory = scratchDirectory("receipt-unit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let (fixture, android) = try rig(stores: stores)
        let posts = try roomTicksWaiting(1, in: fixture)
        let stamp = try #require(fixture.engine.ackSync.riding[alice.nodeId]?.first?.at)
        fixture.clock.advance(1000)
        // A v1 DM from a capable author: its delivery writes nothing in the ratchet's tables, its receipt's seal does.
        let frame = try alice.directMessage("while full", to: me, id: "v1-full", sentAt: now)

        refusing.refusesWrites = true
        fixture.deliver(frame, from: alice)
        refusing.refusesWrites = false
        #expect(fixture.stores.messages.message("v1-full")?.body == "while full")
        #expect(fixture.transport.written(.chat).isEmpty && fixture.acknowledged.isEmpty, "nothing on the air, sealed or cleartext")
        #expect(stores.custody.contains("v1-full"), "nothing purged: the DM stays in our custody")
        #expect(!fixture.engine.custody.isTombstoned("v1-full", now: fixture.clock.wallMilliseconds()))
        #expect(stores.ratchet.records(of: alice.nodeId).session == nil, "no chain advanced")
        #expect(fixture.engine.ackSync.riding[alice.nodeId]?.map(\.at) == [stamp], "the rider back, with its stamp")
        #expect(fixture.engine.receipts == RatchetReceiptCounts(), "and a store that failed counts nothing")

        fixture.clock.advance(SeenSetWindow.milliseconds)
        fixture.deliver(frame, from: carol)
        let content = try #require(fixture.sealedReceipts(to: android).first.flatMap { android.peek($0, from: me) })
        #expect(content.ack == "v1-full" && content.acks == posts, "a later copy's receipt is sealed, and the tick rides it")
        #expect(fixture.engine.ackSync.ridingFor(alice.nodeId) == 0)
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 1, receiptsRidden: 1))
    }

    /// The author's row read inside the seal's unit, over both store kinds: a read that fails fails the unit, so nothing goes
    /// and nothing is purged, where a read outside the unit would have answered as if no row were pinned and sent the
    /// cleartext receipt with its self-purge. Kotlin's `peers.find` throws there (`PeerRepository.kt:138`), and nothing
    /// goes. The DM was delivered and acknowledged sealed first; this is the exists-gate's re-ack of a later copy.
    @Test(arguments: StoreKind.allCases)
    func aFailedReadOfTheAuthorsRowSendsNoReceipt(kind: StoreKind) throws {
        let directory = scratchDirectory("receipt-read")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingPeerReads(blobs: directory, failures: ReportedFailures().record)
        let (fixture, android) = try rig(stores: stores)
        let frame = try alice.directMessage("twice", to: me, id: "v1-twice", sentAt: now)
        fixture.deliver(frame, from: alice)
        #expect(fixture.acknowledged(by: android) == ["v1-twice"], "the first copy's receipt, sealed")
        _ = try roomTicksWaiting(1, in: fixture)
        let stamp = try #require(fixture.engine.ackSync.riding[alice.nodeId]?.first?.at)
        let advanced = stores.ratchet.records(of: alice.nodeId)
        fixture.transport.clear()

        refusing.failsReads = true
        #expect(fixture.engine.sendSealedReceipt(for: "v1-twice", to: alice.nodeId) == .failed)
        fixture.engine.acknowledge(frame.envelope, sender: alice.nodeId)
        refusing.failsReads = false
        #expect(fixture.transport.written.isEmpty, "nothing on the air, sealed or cleartext")
        #expect(stores.custody.contains("v1-twice"), "nothing purged")
        #expect(!fixture.engine.custody.isTombstoned("v1-twice", now: fixture.clock.wallMilliseconds()))
        #expect(stores.ratchet.records(of: alice.nodeId) == advanced, "no chain advanced")
        #expect(fixture.engine.ackSync.riding[alice.nodeId]?.map(\.at) == [stamp], "the rider back, with its stamp")
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 1))
    }

    /// A receipt asked for inside a unit its caller opened, which nothing does around a delivery's second half (the standing
    /// rule a group open in a unit keeps, phase P6): its seal joins that unit, so neither the sealed frame nor the cleartext
    /// one may go before an outer commit it never sees. Nothing goes on the air, the rider goes back, and the abandoned unit
    /// takes the joined seal with it.
    @Test func aReceiptAskedForInsideAUnitPutsNothingOnTheAir() throws {
        let (fixture, android) = try rig()
        _ = try roomTicksWaiting(1, in: fixture)
        var attempt: SealedReceiptAttempt?
        let outer = fixture.stores.transactor.atomically { () -> Void? in
            attempt = fixture.engine.sendSealedReceipt(for: "dm-1", to: alice.nodeId)
            return nil
        }
        guard case .abandoned = outer else {
            Issue.record("the outer unit abandons: \(outer)")
            return
        }
        #expect(attempt == .heldBack)
        #expect(fixture.transport.written.isEmpty, "nothing on the air, sealed or cleartext")
        #expect(fixture.engine.ackSync.ridingFor(alice.nodeId) == 1, "the rider back")
        #expect(fixture.ratchetRecords(of: alice).session == nil, "and the joined seal undone with the unit")
        #expect(fixture.sealedReceipts(to: android).isEmpty)
        #expect(fixture.engine.receipts == RatchetReceiptCounts())
    }

    /// The same receipt inside a caller's unit that then commits (the P5d crypto review's second finding): nothing goes on
    /// the air then, but what the joined seal wrote stands with the outer unit, the chain's advance and the receipt in our
    /// custody, unflooded and unmarked. No key is used twice, since the advance committed with the frame. The next custody
    /// exchange serves it, so the receipt "held back" reaches its author after all, with the rider it also gave back, which
    /// rides again, and the author applies it twice, idempotently. Nothing may count on this: the standing rule keeps
    /// `acknowledge` out of a unit.
    @Test func aReceiptAskedForInsideAUnitThatCommitsStandsInCustodyAndGoesAtTheNextExchange() throws {
        let (fixture, android) = try rig()
        let posts = try roomTicksWaiting(1, in: fixture)
        let seen = fixture.engine.router.seenCount
        var attempt: SealedReceiptAttempt?
        let outer = fixture.stores.transactor.atomically { () -> Void? in
            attempt = fixture.engine.sendSealedReceipt(for: "dm-1", to: alice.nodeId)
            return ()
        }
        guard case .committed = outer else {
            Issue.record("the outer unit commits: \(outer)")
            return
        }
        #expect(attempt == .heldBack)
        #expect(fixture.transport.written.isEmpty, "nothing on the air now")
        #expect(fixture.engine.router.seenCount == seen, "nor marked as ours")
        #expect(fixture.engine.ackSync.ridingFor(alice.nodeId) == 1, "the rider back, to ride again")
        #expect(fixture.ratchetRecords(of: alice).session?.weAreInitiator == true, "the joined seal's advance stands")
        let carried = fixture.stores.custody.liveFrames(now: fixture.clock.wallMilliseconds()).filter { frame in
            frame.envelope.type == .chat && frame.envelope.recipientId == alice.nodeId.string
        }
        #expect(carried.count == 1, "and so does the receipt, in our custody")

        fixture.engine.receiveDigest([], from: carol.nodeId)
        let served = fixture.sealedReceipts(to: android)
        #expect(served.count == 1 && served.first?.to == carol.nodeId, "the next exchange serves it")
        #expect(served.first?.envelope.id == carried.first?.envelope.id)
        let content = try #require(served.first.flatMap { android.peek($0, from: me) })
        #expect(content.ack == "dm-1" && content.acks == posts, "the receipt, with the rider it also gave back")
    }

    /// A blocked sender's DM is never delivered, so it earns no receipt of either form (`aBlockedSendersDmIsNeitherDeliveredNorAcked`,
    /// `InboundPipelineTest.kt:4027-4041`): a cleartext one would purge it from every carrier, and a sealed one would show
    /// the delivery.
    @Test func aBlockedSendersDmIsNeitherDeliveredNorAcknowledged() throws {
        let (fixture, android) = try rig()
        fixture.engine.block(alice.nodeId)
        let id = canonicalId(1)
        fixture.deliver(try android.dm("let me in", to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: now, v3: true), from: android)
        #expect(fixture.stores.messages.message(id) == nil)
        #expect(fixture.transport.written(.receipt).isEmpty && fixture.transport.written(.chat).isEmpty)
    }
}
