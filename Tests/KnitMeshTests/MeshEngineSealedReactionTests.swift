import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Our reactions with the ratchet's switch on (ADR 2026-10.5sk9, phase P5e): knit-next's `MeshManagerTest` reaction cases by
/// name (`MeshManagerTest.kt:2419-2588`, at `cbf2a487`), each read by Android's own session layer (``AndroidPeer``). A
/// reaction to a message in a DM with a peer who can read one goes as a sealed `CTL_REACTION`, never the cleartext frame and
/// never the v1 wrap; the room's goes in the clear always. A group's goes in the group form when every member can read it
/// (phase P6b): `aGroupReactionWithEveryMemberEligibleRidesTheGroupFormAndDistributesItsSeed` is
/// `MeshEngineGroupSendTests`', and the ineligible group's fallback is here.
@Suite struct MeshEngineSealedReactionTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let bob = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private var now: Int64 { EngineFixture.start }

    /// A canonical frame id, which the compact layout carries as 16 raw bytes.
    private func canonicalId(_ seed: UInt64) -> String {
        var generator = SeededGenerator(seed: seed)
        return FrameId.generate(using: &generator)
    }

    /// The id of Alice's DM the rig holds, a canonical one.
    private var target: String { canonicalId(1) }

    /// The iPhone with the switch on, Alice an Android phone pinned with its prekey and the ratchet's bits, and the DM she
    /// sent us held under ``target``. What its delivery wrote, our answer to her init and our receipt, is cleared.
    private func rig(stores: MeshStores = .inMemory()) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        fixture.deliver(try android.dm("hello", to: me, prekey: try fixture.ourPrekey(), id: target, sentAt: now, v3: true), from: android)
        #expect(fixture.stores.messages.message(target)?.body == "hello")
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    /// What `frame`, a sealed reaction of ours, says, as Android's own open reads it, committing it.
    private func opened(_ frame: Written, by android: AndroidPeer) throws -> MessageContent? {
        let bytes = try #require(plaintext(try android.open(frame, from: me, now: frame.envelope.sentAt)))
        let enc = try #require(try ChatContent(decoding: frame.envelope.payload).enc)
        return enc.version == EncEnvelope.Version.compactRatchet ? MessageContentV2.decode(bytes) : try? MessageContent(decoding: bytes)
    }

    // MARK: MeshManagerTest

    /// `aDmReactionToACapablePeerRidesSealedNeverAsACleartextFrame` (`MeshManagerTest.kt:2429-2446`): one DM-form chat to
    /// Alice, compact since she reads v3 and the id is canonical, originated, dated by the row's own clock, and no
    /// cleartext frame that would show anyone in range who reacted to what.
    @Test func aDmReactionToACapablePeerRidesSealedNeverAsACleartextFrame() throws {
        let (fixture, android) = try rig()
        let reaction = try #require(fixture.engine.react(to: target, with: "👍"))
        #expect(fixture.transport.written(.reaction).isEmpty, "no cleartext reaction may show the target or the emoji")
        let frames = fixture.transport.written(.chat)
        let frame = try #require(frames.first)
        #expect(frames.count == 1 && frame.envelope.recipientId == alice.nodeId.string && frame.to == nil && frame.wire.relay)
        #expect(frame.envelope.sentAt == reaction.updatedAt, "the row's clock, which last writer wins compares on both phones")
        #expect(me.keys.bundle.isValidSignature(frame.wire.sig, for: frame.wire.signed), "signed once, and it verifies")
        let enc = try #require(try ChatContent(decoding: frame.envelope.payload).enc)
        #expect(enc.version == EncEnvelope.Version.compactRatchet && enc.ratchet != nil, "the DM form, compact")
        let content = try #require(try opened(frame, by: android))
        #expect(content.ctl == MessageContent.Control.reaction && content.rp == ReactionContent(messageId: target, emoji: "👍"))
        #expect(fixture.stores.messages.reaction(on: target, by: me.nodeId) == reaction, "the row applied first, at that clock")
        #expect(fixture.stores.custody.contains(frame.envelope.id), "carried for its day, as the cleartext frame was")
        #expect(fixture.engine.seals == RatchetSealCounts(reactionsSealed: 1))
    }

    /// `aReactionToAnIncapablePeerFallsBackToTheCleartextFrame` (`MeshManagerTest.kt:2449-2461`): Dave's pinned profile lacks
    /// `CAP_RATCHET`, so the cleartext frame goes, counted as the seal that fell back.
    @Test func aReactionToAnIncapablePeerFallsBackToTheCleartextFrame() throws {
        let (fixture, _) = try rig()
        fixture.deliver(try dave.profile(publishedAt: now, capabilities: 0xF), from: dave)
        fixture.deliver(try dave.directMessage("old style", to: me, id: "v1-dm", sentAt: now), from: dave)
        fixture.transport.clear()
        let reaction = try #require(fixture.engine.react(to: "v1-dm", with: "👍"))
        let frame = try #require(fixture.transport.written(.reaction).first)
        #expect(try ReactionContent(decoding: frame.envelope.payload) == ReactionContent(messageId: "v1-dm", emoji: "👍"))
        #expect(frame.envelope.sentAt == reaction.updatedAt && frame.envelope.recipientId == nil, "today's frame, naming nobody")
        #expect(fixture.transport.written(.chat).isEmpty)
        #expect(fixture.engine.seals == RatchetSealCounts(reactionsSealedFallback: 1))
    }

    /// `aBroadcastReactionStaysCleartextByDesignAndCountsNoFallback` (`MeshManagerTest.kt:2500-2510`): the room is plaintext,
    /// so its reaction is the cleartext frame and nothing tried to seal it.
    @Test func aBroadcastReactionStaysCleartextByDesignAndCountsNoFallback() throws {
        let (fixture, _) = try rig()
        fixture.deliver(try alice.roomPost("hello room", id: "room-1", sentAt: now), from: alice)
        fixture.transport.clear()
        _ = try #require(fixture.engine.react(to: "room-1", with: "👍"))
        #expect(fixture.transport.written(.reaction).count == 1 && fixture.transport.written(.chat).isEmpty)
        #expect(fixture.engine.seals == RatchetSealCounts())
    }

    /// `aRetractionRidesTheSealedPathWithANullEmoji` (`MeshManagerTest.kt:2513-2525`): our emoji again takes it back, sealed,
    /// with no emoji, which Android reads as the retraction.
    @Test func aRetractionRidesTheSealedPathWithANullEmoji() throws {
        let (fixture, android) = try rig()
        _ = try #require(fixture.engine.react(to: target, with: "👍"))
        let retraction = try #require(fixture.engine.react(to: target, with: "👍"))
        #expect(retraction.emoji == nil)
        let frames = fixture.transport.written(.chat)
        #expect(frames.count == 2 && fixture.transport.written(.reaction).isEmpty)
        _ = try opened(frames[0], by: android)
        let content = try #require(try opened(frames[1], by: android))
        #expect(content.rp == ReactionContent(messageId: target, emoji: nil), "no emoji: taken back")
        #expect(frames[1].envelope.sentAt == retraction.updatedAt && retraction.updatedAt > frames[0].envelope.sentAt)
        #expect(fixture.engine.seals == RatchetSealCounts(reactionsSealed: 2))
    }

    /// `aCtlReactionNeverFallsBackToTheV1Wrap` (`MeshManagerTest.kt:2528-2551`): a peer that claims the bits with a prekey
    /// that cannot start a session (Kotlin's garbled one; here a prekey that will not verify never pins, so none is held)
    /// gets the cleartext frame, never a v1 envelope, which a build before the ratchet would store as an empty bubble.
    @Test func aCtlReactionNeverFallsBackToTheV1Wrap() throws {
        let (fixture, _) = try rig()
        fixture.deliver(try dave.profile(publishedAt: now, capabilities: AndroidPeer.capabilities), from: dave)
        #expect(fixture.stores.peers.peer(dave.nodeId)?.prekey == nil)
        fixture.deliver(try dave.directMessage("hi", to: me, id: "v1-dm", sentAt: now), from: dave)
        fixture.transport.clear()
        _ = try #require(fixture.engine.react(to: "v1-dm", with: "👍"))
        #expect(fixture.transport.written(.chat).isEmpty, "no v1 envelope for a ctl, ever")
        #expect(fixture.transport.written(.reaction).count == 1)
        #expect(fixture.ratchetRecords(of: dave).session == nil, "no key moved")
        #expect(fixture.engine.seals == RatchetSealCounts(reactionsSealedFallback: 1))
    }

    /// `anOversizedReactionIsRefusedBeforeItTouchesTheRowOrTheWire` (`MeshManagerTest.kt:2554-2570`): past the 32 UTF-16
    /// units, or blank, nothing is stored, sealed, sent or counted.
    @Test func anOversizedReactionIsRefusedBeforeItTouchesTheRowOrTheWire() throws {
        let (fixture, _) = try rig()
        #expect(fixture.engine.react(to: target, with: String(repeating: "👍", count: 17)) == nil)
        #expect(fixture.engine.react(to: target, with: " ") == nil)
        #expect(fixture.stores.messages.reaction(on: target, by: me.nodeId) == nil)
        #expect(fixture.transport.written.isEmpty)
        #expect(fixture.engine.seals == RatchetSealCounts())
    }

    /// `theLongestRgiSequenceRidesSealedVerbatim` (`MeshManagerTest.kt:2573-2587`): a ten-scalar ZWJ sequence is one emoji
    /// and only a longer string, which Android reads back byte for byte.
    @Test func theLongestRgiSequenceRidesSealedVerbatim() throws {
        let (fixture, android) = try rig()
        let kiss = "\u{1F469}\u{1F3FD}\u{200D}\u{2764}\u{FE0F}\u{200D}\u{1F48B}\u{200D}\u{1F468}\u{1F3FC}"
        _ = try #require(fixture.engine.react(to: target, with: kiss))
        let frame = try #require(fixture.transport.written(.chat).first)
        let emoji = try #require(try opened(frame, by: android)?.rp?.emoji)
        #expect(Array(emoji.utf8) == Array(kiss.utf8), "verbatim, compared by its bytes")
        #expect(fixture.transport.written(.reaction).isEmpty)
        #expect(fixture.engine.seals == RatchetSealCounts(reactionsSealed: 1))
    }

    /// Kotlin's `aGroupReactionWithAnIneligibleMemberFallsBackToTheCleartextFrame` (`MeshManagerTest.kt:2485`): Bob has no
    /// pinned profile, so the group cannot take the group form, and the reaction goes as the cleartext frame, counted as a
    /// fallback, as Kotlin counts a group that cannot seal (`MeshManager.kt:2189`), and nothing reaches the group store.
    @Test func aGroupReactionWithAnIneligibleMemberFallsBackToTheCleartextFrame() throws {
        let (fixture, _) = try rig()
        let group = roster([alice, bob, me], createdBy: alice)
        fixture.deliver(try alice.groupMessage("group", in: group, to: [bob, me], id: "gm-1", sentAt: now), from: alice)
        #expect(fixture.stores.messages.message("gm-1") != nil)
        fixture.transport.clear()
        _ = try #require(fixture.engine.react(to: "gm-1", with: "👍"))
        #expect(fixture.transport.written(.reaction).count == 1 && fixture.transport.written(.chat).isEmpty)
        #expect(fixture.engine.seals == RatchetSealCounts(reactionsSealedFallback: 1))
        #expect(fixture.engine.groupCounts.groupSealedV1Fallback == 0, "never eligible, so no group fallback")
        #expect(fixture.stores.groupRatchet.holdings(of: group.id) == .empty)
    }

    /// A message whose id the compact codec cannot carry: the reaction seals named under v2, still never in the clear.
    @Test func aReactionToANonCanonicalIdSealsV2() throws {
        let (fixture, android) = try rig()
        let id = "not-a-canonical-id"
        fixture.deliver(try android.dm("odd id", to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: now + 1), from: android)
        fixture.transport.clear()
        _ = try #require(fixture.engine.react(to: id, with: "👍"))
        let frame = try #require(fixture.transport.written(.chat).first)
        #expect(try ChatContent(decoding: frame.envelope.payload).enc?.version == EncEnvelope.Version.ratchet)
        #expect(try opened(frame, by: android)?.rp == ReactionContent(messageId: id, emoji: "👍"))
    }

    // MARK: Store failures and units

    /// A store that fails mid-seal, over both store kinds: nothing goes on the air, sealed or cleartext, as Kotlin's throw
    /// out of `sendReaction` sends nothing, and nothing is counted. The row stays applied, as Kotlin's optimistic row
    /// does, and the next reaction, once the store heals, seals: here our emoji again, which takes it back.
    @Test(arguments: StoreKind.allCases)
    func aStoreThatFailsMidSealSendsNoReactionAndKeepsTheRow(kind: StoreKind) throws {
        let directory = scratchDirectory("reaction-unit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let (fixture, android) = try rig(stores: stores)
        let held = stores.ratchet.records(of: alice.nodeId)

        refusing.refusesWrites = true
        let reaction = try #require(fixture.engine.react(to: target, with: "👍"))
        refusing.refusesWrites = false
        #expect(fixture.transport.written.isEmpty, "nothing on the air, sealed or cleartext")
        #expect(stores.messages.reaction(on: target, by: me.nodeId) == reaction, "the row stays")
        #expect(stores.ratchet.records(of: alice.nodeId) == held, "no chain advanced")
        #expect(fixture.engine.seals == RatchetSealCounts(), "a store that failed counts nothing")

        let retraction = try #require(fixture.engine.react(to: target, with: "👍"))
        let frame = try #require(fixture.transport.written(.chat).first)
        #expect(try opened(frame, by: android)?.rp == ReactionContent(messageId: target, emoji: nil) && retraction.emoji == nil)
        #expect(fixture.engine.seals == RatchetSealCounts(reactionsSealed: 1))
    }

    /// The peer's row read inside the seal's unit, over both store kinds: a read that fails fails the unit, so nothing goes,
    /// where a read outside it would have answered as if no row were pinned and sent the cleartext frame. Kotlin's
    /// `peers.find` throws there (`MeshManager.kt:2255`, `PeerRepository.kt:138`), and nothing goes.
    @Test(arguments: StoreKind.allCases)
    func aFailedReadOfThePeersRowSendsNoReaction(kind: StoreKind) throws {
        let directory = scratchDirectory("reaction-read")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingPeerReads(blobs: directory, failures: ReportedFailures().record)
        let (fixture, _) = try rig(stores: stores)
        refusing.failsReads = true
        _ = try #require(fixture.engine.react(to: target, with: "👍"))
        refusing.failsReads = false
        #expect(fixture.transport.written.isEmpty, "nothing on the air, sealed or cleartext")
        #expect(fixture.engine.seals == RatchetSealCounts())
    }

    /// A reaction sealed inside a unit its caller opened, which nothing opens around a send: the seal joins that unit, so
    /// neither form goes before an outer commit it never sees. Abandoned, the unit takes the joined seal with it. Committed,
    /// what the seal wrote stands, the chain's advance and the frame in our custody, unflooded and unmarked, and the next
    /// custody exchange serves it, so the reaction reaches Alice after all.
    @Test func aReactionSealedInsideAUnitPutsNothingOnTheAir() throws {
        let (fixture, android) = try rig()
        let reaction = ReactionRecord(messageId: target, reactor: me.nodeId, emoji: "👍", updatedAt: now)
        let held = fixture.ratchetRecords(of: alice)
        let abandoned = fixture.stores.transactor.atomically { () -> Void? in
            fixture.engine.sendReaction(reaction, in: alice.nodeId.string)
            return nil
        }
        guard case .abandoned = abandoned else {
            Issue.record("the outer unit abandons: \(abandoned)")
            return
        }
        #expect(fixture.transport.written.isEmpty, "nothing on the air, sealed or cleartext")
        #expect(fixture.ratchetRecords(of: alice) == held, "and the joined seal undone with the unit")

        let carried = Set(fixture.stores.custody.liveIds(now: now).map(ExactKey.init))
        let committed = fixture.stores.transactor.atomically { () -> Void? in
            fixture.engine.sendReaction(reaction, in: alice.nodeId.string)
            return ()
        }
        guard case .committed = committed else {
            Issue.record("the outer unit commits: \(committed)")
            return
        }
        #expect(fixture.transport.written.isEmpty, "nothing on the air now")
        let added = Set(fixture.stores.custody.liveIds(now: now).map(ExactKey.init)).subtracting(carried)
        #expect(added.count == 1, "the joined seal's frame stands in our custody")
        fixture.engine.receiveDigest([], from: bob.nodeId)
        let served = fixture.transport.written(.chat).first { added.contains(ExactKey($0.envelope.id)) && $0.to == bob.nodeId }
        let frame = try #require(served, "the next exchange serves it")
        #expect(try opened(frame, by: android)?.rp == ReactionContent(messageId: target, emoji: "👍"))
        #expect(fixture.engine.seals == RatchetSealCounts(), "and nothing counted it")
    }
}
