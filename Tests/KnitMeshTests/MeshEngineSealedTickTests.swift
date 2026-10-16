import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The ticks we owe, sealed by the seams this build ships with the ratchet's switch on (``RatchetTickSeals``, ADR
/// 2026-10.5sk9, phase P5d), toward an Android author whose profile carries the ratchet's bits and a signed prekey
/// (``AndroidPeer``), each read by Android's own session layer. `MeshManagerTest`'s tick cases by name
/// (`MeshManagerTest.kt:1741-2069`, at `cbf2a487`), where this port has the path they take. Not ported, as the LoRa
/// plane's coalescer: `heldLoraReceiptsFlushAsOneHintedTick`, `theCoalescedTickCarriesTheRoomTicksWaitingForTheSameAuthor`
/// and `aCoalescedTickNeverCarriesMoreRidersThanTheLoraHopFits` (a sealed DM receipt's own bound is
/// `MeshEngineSealedReceiptTests`'), and as the fast plane's, `theRideDeadlineSendsATickOverTheFastPlaneToAReachableAuthor`;
/// `aNewSightingOfTheAuthorFlushesADueRideAtOnce` is a link-up here. Alice is the iPhone, Bob the author, Carol the
/// neighbour his frames come through.
@Suite struct MeshEngineSealedTickTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let start = EngineFixture.start
    private let debounce = AckSync.batchDebounceMilliseconds

    private var bobsGroup: GroupInfo { roster([bob, carol, alice], createdBy: bob) }

    /// Alice's engine with the switch on, Bob an Android phone pinned with its prekey and away, and Carol linked.
    private func rig(stores: MeshStores = .inMemory()) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(alice, stores: stores)
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

    private func groupMessage(_ id: String, at offset: Int64 = 0) throws -> TestFrame {
        try bob.groupMessage("Hi \(id)", in: bobsGroup, to: [alice, carol], id: id, sentAt: start + offset)
    }

    private func roomPost(_ id: String, at offset: Int64 = 0) throws -> TestFrame {
        try bob.roomPost("Room \(id)", id: id, sentAt: start + offset)
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

    private func envelope(of written: Written) throws -> EncEnvelope {
        try #require(try ChatContent(decoding: written.envelope.payload).enc)
    }

    // MARK: A linked author

    @Test func theSeamsThisBuildShipsSealWithTheSwitchOn() throws {
        let (fixture, _) = try rig()
        #expect(fixture.engine.tickSeals is RatchetTickSeals)
        #expect(fixture.engine.tickSeals.canSeal(bob.nodeId), "the bits and a bundle, from one read of Bob's row")
        #expect(!fixture.engine.tickSeals.canSeal(TestPeer(seed: 9).nodeId), "nobody pinned, nothing sealed")
    }

    /// A linked author's tick, sealed: one `CTL_RECEIPT` over its link, `relay = false`, signed, as this port sends every
    /// tick, where Kotlin's v3 one goes unsigned (ADR 059); never carried, never cleartext.
    @Test func aLinkedAuthorsTickIsSealedSignedAndPointToPoint() throws {
        let (fixture, android) = try rig()
        fixture.link(bob)
        fixture.transport.clear()
        let post = canonicalId(1)
        fixture.deliver(try roomPost(post), from: bob)

        let ticks = sealedTicks(fixture)
        let tick = try #require(ticks.first)
        #expect(ticks.count == 1 && tick.to == bob.nodeId && !tick.wire.relay, "point to point, over the link")
        #expect(alice.keys.bundle.isValidSignature(tick.wire.sig, for: tick.wire.signed), "signed once, and it verifies")
        #expect(tick.envelope.sentAt == fixture.clock.wallMilliseconds(), "under a fresh id and sentAt now")
        #expect(try envelope(of: tick).version == EncEnvelope.Version.compactRatchet, "v3, Bob reads it")
        #expect(android.receiptAcks(tick, from: alice) == [post])
        #expect(!fixture.stores.custody.contains(tick.envelope.id), "never carried")
        #expect(try clearlyTicked(fixture).isEmpty && fixture.engine.footprint.owedTicks == 0)
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 1), "counted as Android counts it")
    }

    /// `aTickAckingANonCanonicalIdToAV3AuthorFallsBackToV2` (`MeshManagerTest.kt:2056-2069`): the compact codec cannot carry
    /// the id, so the tick goes v2, its nonce carried, and signed like every tick of ours.
    @Test func aTickAckingANonCanonicalIdToAV3AuthorFallsBackToV2() throws {
        let (fixture, android) = try rig()
        fixture.link(bob)
        fixture.transport.clear()
        fixture.deliver(try roomPost("not-a-frame-id"), from: bob)
        let tick = try #require(sealedTicks(fixture).first)
        let enc = try envelope(of: tick)
        #expect(enc.version == EncEnvelope.Version.ratchet && enc.nonce.count == 12)
        #expect(alice.keys.bundle.isValidSignature(tick.wire.sig, for: tick.wire.signed))
        #expect(android.receiptAcks(tick, from: alice) == ["not-a-frame-id"])
    }

    // MARK: An absent author

    /// The group's batch toward an absent author, sealed: one originated `CTL_RECEIPT` for every id, v3 and signed
    /// (`theCoalescedTickToAV3AuthorIsV3AndStillSigned`'s form, `MeshManagerTest.kt:2036-2054`), carried for a day. A
    /// re-serve past the router's window owes nothing, so the batch costs one chain key, and never another.
    @Test func aGroupTickToAnAbsentAuthorEscalatesAsOneOriginatedSealedFrameAndNeverAgain() throws {
        let (fixture, android) = try rig()
        let owedAt = fixture.clock.monotonicMilliseconds()
        let ids = [canonicalId(1), canonicalId(2)]
        let first = try groupMessage(ids[0])
        fixture.deliver(first, from: carol)
        fixture.deliver(try groupMessage(ids[1], at: 1), from: carol)
        fixture.advance(fixture.engine.configuration.router.jitterWindowMilliseconds)
        #expect(sealedTicks(fixture).isEmpty && fixture.engine.nextDeadline == owedAt + debounce, "nothing before the debounce")

        fixture.advance(owedAt + debounce - fixture.clock.monotonicMilliseconds())
        let ticks = sealedTicks(fixture)
        let tick = try #require(ticks.first)
        #expect(ticks.count == 1 && tick.to == nil && tick.wire.relay, "one originated frame for the batch")
        #expect(alice.keys.bundle.isValidSignature(tick.wire.sig, for: tick.wire.signed), "signed, since it is carried")
        #expect(try envelope(of: tick).version == EncEnvelope.Version.compactRatchet)
        #expect(tick.envelope.sentAt == fixture.clock.wallMilliseconds() && fixture.stores.custody.contains(tick.envelope.id))
        #expect(android.receiptAcks(tick, from: alice) == ids, "one tick, every id")
        let sent = try #require(fixture.ratchetRecords(of: bob).session).sendCount
        #expect(sent == 1, "one chain key")
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 1, receiptsCustodied: 1), "sealed, and custodied")

        fixture.clock.advance(SeenSetWindow.milliseconds)
        fixture.deliver(first, from: carol)
        fixture.advance(debounce)
        fixture.link(bob)
        #expect(sealedTicks(fixture).count == 1 && fixture.ratchetRecords(of: bob).session?.sendCount == sent, "never sealed again")
        #expect(try clearlyTicked(fixture).isEmpty)
    }

    /// `theGroupBatchTickCarriesTheRoomTicksWaitingForTheSameAuthor` (`MeshManagerTest.kt:1880-1897`): the escalated batch is
    /// a frame already sealed to the author and carried, so the room ticks waiting for it ride along.
    @Test func theGroupBatchTickCarriesTheRoomTicksWaitingForTheSameAuthor() throws {
        let (fixture, android) = try rig()
        let post = canonicalId(1)
        let message = canonicalId(2)
        fixture.deliver(try roomPost(post), from: carol)
        fixture.deliver(try groupMessage(message, at: 1), from: carol)
        fixture.advance(debounce)
        let ticks = sealedTicks(fixture)
        #expect(ticks.count == 1, "one originated tick")
        #expect(ticks.first.flatMap { android.receiptAcks($0, from: alice) } == [message, post], "the batch, then its rider")
        #expect(fixture.engine.ackSync.ridingFor(bob.nodeId) == 0)
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealed: 1, receiptsCustodied: 1, receiptsRidden: 1))
    }

    /// `theRideDeadlineKeepsHoldingWhenTheAuthorIsNowhere` (`MeshManagerTest.kt:1911-1922`), then the link-up that is this
    /// port's sighting (`aNewSightingOfTheAuthorFlushesADueRideAtOnce`, `:1925-1943`): no chain key is spent on nobody,
    /// and the due ride goes over the link as one sealed tick.
    @Test func theRideDeadlineKeepsHoldingWhenTheAuthorIsNowhereAndTheLinkUpSendsIt() throws {
        let (fixture, android) = try rig()
        let post = canonicalId(1)
        fixture.deliver(try roomPost(post), from: carol)
        fixture.advance(AckSync.rideHoldMilliseconds + 1)
        fixture.advance(fixture.engine.configuration.healMilliseconds)
        #expect(sealedTicks(fixture).isEmpty && fixture.engine.ackSync.ridingFor(bob.nodeId) == 1)
        #expect(fixture.ratchetRecords(of: bob).session == nil, "no chain key spent on nobody")

        fixture.link(bob)
        let tick = try #require(sealedTicks(fixture).first)
        #expect(sealedTicks(fixture).count == 1 && tick.to == bob.nodeId && !tick.wire.relay, "one tick, over the link")
        #expect(android.receiptAcks(tick, from: alice) == [post] && fixture.engine.ackSync.ridingFor(bob.nodeId) == 0)
        #expect(!fixture.stores.custody.contains(tick.envelope.id))
    }

    /// `aBlockedMembersGroupTickIsOwedLikeAnyOther` with the real seams (`ackBlockedRoomChat`, `InboundPipeline.kt:903-915`;
    /// no blocked gate, `MeshManager.kt:1863-1865`): a blocked member's ticks are sealed and batched like anyone's, and his
    /// room tick rides his group's batch, which costs one custody row and none of its own.
    @Test func aBlockedMembersGroupTickIsOwedLikeAnyOther() throws {
        let (fixture, android) = try rig()
        let first = canonicalId(1)
        fixture.deliver(try groupMessage(first), from: carol)
        fixture.engine.block(bob.nodeId)
        let carried = Set(fixture.stores.custody.liveIds(now: fixture.clock.wallMilliseconds()))
        let post = canonicalId(2)
        let second = canonicalId(3)
        fixture.deliver(try roomPost(post, at: 1), from: carol)
        fixture.deliver(try groupMessage(second, at: 2), from: carol)
        #expect(fixture.engine.dropped[.blocked] == 2, "neither delivered")

        fixture.advance(debounce)
        let tick = try #require(sealedTicks(fixture).first)
        #expect(sealedTicks(fixture).count == 1 && android.receiptAcks(tick, from: alice) == [first, second, post])
        let held = Set(fixture.stores.custody.liveIds(now: fixture.clock.wallMilliseconds()))
        #expect(held.subtracting(carried) == [post, second, tick.envelope.id], "the batch's row, and none of the room tick's own")
    }

    // MARK: Seals that cannot stand

    /// A seal the facade cannot make toward an author who could read one: Dave claims the bits and pins no prekey, and no
    /// session is held, so neither seam seals (`sealDeliveryTickEnvelope`'s `sealDm` answering `null`,
    /// `MeshManager.kt:1884-1888`). The linked tick goes in the clear, the batch comes back as a cleartext entry that waits
    /// for the link, and each refused seal counts as Android's `receiptsSealedFallback` does.
    @Test func aSealTheFacadeCannotMakeLeavesTheCleartextTickAndCountsAFallback() throws {
        let (fixture, _) = try rig()
        let dave = TestPeer(seed: 4)
        fixture.deliver(try dave.profile(publishedAt: start, capabilities: AndroidPeer.capabilities), from: dave)
        #expect(fixture.stores.peers.peer(dave.nodeId)?.prekey == nil && fixture.engine.tickSeals.canSeal(dave.nodeId))
        fixture.link(dave)
        fixture.transport.clear()
        let post = canonicalId(1)
        fixture.deliver(try dave.roomPost("Room", id: post, sentAt: start), from: dave)
        #expect(try clearlyTicked(fixture) == [post], "the linked tick, in the clear")
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealedFallback: 1))

        fixture.unlink(dave)
        let message = canonicalId(2)
        let group = roster([dave, carol, alice], createdBy: dave)
        fixture.deliver(try dave.groupMessage("Hi", in: group, to: [alice, carol], id: message, sentAt: start + 1), from: carol)
        fixture.advance(debounce)
        #expect(fixture.engine.footprint.owedTicks == 1, "the batch's id, a cleartext entry")
        #expect(fixture.engine.receipts == RatchetReceiptCounts(receiptsSealedFallback: 2))
        #expect(fixture.ratchetRecords(of: dave).session == nil, "no key moved")
        fixture.link(dave)
        #expect(try clearlyTicked(fixture) == [post, message], "and it goes in the clear at the link-up")
    }

    /// A store that fails mid-seal, over both store kinds: nothing sealed goes on the air and no chain advances. A linked
    /// author's tick goes in the clear at once; an absent author's batch comes back as cleartext entries, its rider back
    /// in its hold with its stamp, and the entries go in the clear at the link-up, as a cleartext entry stays.
    @Test(arguments: StoreKind.allCases)
    func aStoreThatFailsMidSealPutsNothingSealedOnTheAir(kind: StoreKind) throws {
        let directory = scratchDirectory("tick-unit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let (fixture, _) = try rig(stores: stores)
        fixture.link(bob)
        fixture.transport.clear()
        let linkedPost = canonicalId(1)
        refusing.refusesWrites = true
        fixture.deliver(try roomPost(linkedPost), from: bob)
        refusing.refusesWrites = false
        let ticked = try clearlyTicked(fixture)
        #expect(sealedTicks(fixture).isEmpty && ticked == [linkedPost], "the linked tick, in the clear")

        fixture.unlink(bob)
        let post = canonicalId(2)
        let message = canonicalId(3)
        fixture.deliver(try roomPost(post, at: 1), from: carol)
        let stamp = try #require(fixture.engine.ackSync.riding[bob.nodeId]?.first?.at)
        fixture.deliver(try groupMessage(message, at: 2), from: carol)
        refusing.refusesWrites = true
        fixture.advance(debounce)
        refusing.refusesWrites = false
        #expect(sealedTicks(fixture).isEmpty, "nothing sealed on the air")
        #expect(stores.ratchet.records(of: bob.nodeId).session == nil, "no chain advanced")
        #expect(fixture.engine.ackSync.riding[bob.nodeId]?.map(\.at) == [stamp], "the rider back, with its stamp")
        #expect(fixture.engine.footprint.owedTicks == 2, "the batch's id a cleartext entry, and the rider waiting")
        #expect(fixture.engine.receipts == RatchetReceiptCounts(), "a store that failed counts nothing")

        fixture.link(bob)
        #expect(try clearlyTicked(fixture) == [linkedPost, message], "the entry goes in the clear at the link-up")
    }
}
