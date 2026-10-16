import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The group form received in the mesh, with the switch on (ADR 2026-10.5sk9, phase P6a2): knit-next's `InboundPipelineTest`
/// cases for the group open, its refusals and the key request, ported by name (`InboundPipelineTest.kt:4208`, `:5735`,
/// `:6415-6943`, at `cbf2a487`). The seed-before-roster race is `MeshEngineGroupSeedTests`'.
@Suite struct MeshEngineGroupRatchetTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    private var now: Int64 { EngineFixture.start }

    /// The iPhone with the switch on, and Alice and Carol pinned as Android phones with the ratchet and a prekey.
    private func rig() throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        try fixture.pin(try AndroidPeer(carol))
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    /// Alice's seed for `author`'s current epoch, delivered as a `CTL_GROUP_KEY` DM.
    private func deliverSeed(_ fixture: EngineFixture, _ author: GroupFormAuthor, id: String, sentAt: Int64? = nil) throws {
        fixture.deliver(try author.seedDm(to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: sentAt ?? now), from: author.android)
    }

    private func acks(_ fixture: EngineFixture, to android: AndroidPeer) -> [MessageContent] {
        fixture.controls(to: android).filter { $0.ctl == MessageContent.Control.groupKeyAck }
    }

    @Test func aSeedCtlDmAdoptsTheChainAndIsNeverPersistedOrAcked() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        try deliverSeed(fixture, author, id: "seed1")
        #expect(fixture.recvChains(group.id, from: alice).count == 1, "adopted through the real ctl path")
        #expect(fixture.stores.messages.message("seed1") == nil, "never a row")
        #expect(
            fixture.transport.written(.receipt).isEmpty && fixture.sealedReceipts(to: android).isEmpty, "never acknowledged as a message")
        #expect(receivedRecords(in: fixture.engine.drainEvents()).isEmpty)
        let ack = try #require(acks(fixture, to: android).first, "the adoption's ack rode back as a v2 ctl DM")
        #expect(ack.gk?.groupId == group.id && ack.gk?.ackEpoch == 1)
        let wire = try #require(fixture.chats(to: alice).first { android.peek($0, from: me)?.ctl == MessageContent.Control.groupKeyAck })
        #expect((try ChatContent(decoding: wire.envelope.payload)).enc?.version == EncEnvelope.Version.ratchet, "always v2")
        #expect(fixture.engine.groupCounts.groupSeedsAdopted == 1)
    }

    @Test func aFarFutureSealedGroupReactionIsBoundedInsideTheChainCommit() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        try deliverSeed(fixture, author, id: "seed-far")
        let far = Int64.max - 1
        let reaction = try author.reaction(group, id: "ctl-gfar", sentAt: far, on: "gm1", emoji: "\u{1F525}")
        fixture.deliver(reaction, from: alice)
        let applied = fixture.stores.messages.reaction(on: "gm1", by: alice.nodeId)
        #expect(applied?.updatedAt == now + WireProtocol.maxFutureSkewMilliseconds, "clamped to five minutes past our clock")
    }

    @Test func aSealedGroupReactionAppliesInsideTheChainCommit() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        try deliverSeed(fixture, author, id: "seed-x")
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        let reaction = try author.reaction(group, id: "ctl-gx1", sentAt: now + 11, on: "gm7", emoji: "\u{1F525}")
        fixture.deliver(reaction, from: alice)
        #expect(
            fixture.stores.messages.reaction(on: "gm7", by: alice.nodeId)
                == ReactionRecord(messageId: "gm7", reactor: alice.nodeId, emoji: "\u{1F525}", updatedAt: now + 11))
        #expect(fixture.stores.messages.message("ctl-gx1") == nil, "a ctl is never a row")
        #expect(receivedRecords(in: fixture.engine.drainEvents()).isEmpty)
        #expect(fixture.transport.written(.receipt).isEmpty && fixture.chats(to: alice).isEmpty, "no tick owed for machinery")
        let holdings = fixture.stores.groupRatchet.holdings(of: group.id)
        #expect(holdings.recvChains[alice.nodeId]?.first?.next == 1, "the chain advanced with the reaction")
    }

    @Test func anOversizedSealedGroupReactionAppliesNothingInsideTheChainCommit() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        try deliverSeed(fixture, author, id: "seed-o")
        let words = try author.reaction(group, id: "ctl-go1", sentAt: now + 11, on: "gm7", emoji: " ")
        let fire = try author.reaction(group, id: "ctl-go2", sentAt: now + 12, on: "gm7", emoji: "\u{1F525}")
        fixture.deliver(words, from: alice)
        fixture.deliver(fire, from: alice)
        #expect(fixture.stores.messages.reaction(on: "gm7", by: alice.nodeId)?.updatedAt == now + 12, "the next frame still opens")
        #expect(fixture.engine.dropped[.reactionRefused] == 1)
    }

    @Test func aGroupRatchetFrameAfterItsSeedDecryptsAndDelivers() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        try deliverSeed(fixture, author, id: "seed1")
        _ = fixture.engine.drainEvents()
        fixture.deliver(try author.frame(group, id: "gm1", body: "sealed team hi", sentAt: now), from: alice)
        let row = try #require(fixture.stores.messages.message("gm1"))
        #expect(row.body == "sealed team hi" && row.conversationId == group.id)
        #expect(receivedRecords(in: fixture.engine.drainEvents()).map(\.id) == ["gm1"], "announced once its unit committed")
    }

    @Test func aGroupRatchetFrameBeforeItsSeedDropsNoKeyAndStillCustodies() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        fixture.deliver(try author.frame(group, id: "gm-early", body: "too soon", sentAt: now), from: alice)
        #expect(fixture.stores.messages.message("gm-early") == nil && fixture.engine.dropped[.groupRatchetNoKey] == 1)
        #expect(fixture.stores.custody.contains("gm-early"), "delivery-local: still carried for the members who can read it")
    }

    @Test func outOfOrderGroupFramesGapFillAndConsumeSkippedKeys() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        try deliverSeed(fixture, author, id: "seed1")
        let frames = try (0...2).map { try author.frame(group, id: "gm\($0)", body: "msg \($0)", sentAt: now + Int64($0)) }
        for index in [2, 0, 1] {
            fixture.deliver(frames[index], from: alice)
        }
        #expect((0...2).map { fixture.stores.messages.message("gm\($0)")?.body } == ["msg 0", "msg 1", "msg 2"])
        #expect(fixture.stores.groupRatchet.skippedKeys(group.id, from: alice.nodeId, epoch: 1, index: 0).isEmpty)
        #expect(fixture.stores.groupRatchet.skippedKeys(group.id, from: alice.nodeId, epoch: 1, index: 1).isEmpty, "both banked keys spent")
    }

    @Test func aReServedGroupFrameShortCircuitsAtTheExistsGate() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        try deliverSeed(fixture, author, id: "seed1")
        let frame = try author.frame(group, id: "gm-r", body: "once", sentAt: now)
        fixture.deliver(frame, from: alice)
        fixture.advance(SeenSet.defaultWindowMilliseconds + 1)
        fixture.deliver(frame, from: alice)
        #expect(fixture.stores.messages.message("gm-r")?.body == "once")
        #expect(fixture.engine.dropped[.groupRatchetDuplicate] == nil && fixture.engine.dropped[.groupRatchetAeadFail] == nil)
    }

    @Test func aReMintedSeedIsAdoptedAndTheOldEraStillDrains() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        try deliverSeed(fixture, author, id: "seed1")
        let preWipe = try author.frame(group, id: "gm-old", body: "old era", sentAt: now)
        author.wipeAndRemint(at: 60_000)
        try deliverSeed(fixture, author, id: "seed2", sentAt: now + 1)
        fixture.deliver(try author.frame(group, id: "gm-new", body: "new era", sentAt: now + 2), from: alice)
        fixture.deliver(preWipe, from: alice)
        #expect(fixture.stores.messages.message("gm-new")?.body == "new era")
        #expect(fixture.stores.messages.message("gm-old")?.body == "old era", "the old frame on the drain")
        #expect(fixture.recvChains(group.id, from: alice).count == 2)
    }

    @Test func aSeedFromANonMemberAdoptsNothing() throws {
        let (fixture, _) = try rig()
        let other = try AndroidPeer(carol)
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(other, in: group.id)
        try deliverSeed(fixture, author, id: "seed-c")
        #expect(fixture.recvChains(group.id, from: carol).isEmpty)
        #expect(acks(fixture, to: other).isEmpty, "no adoption, so no ack")
    }

    @Test func aGroupRatchetFrameForALeftGroupIsRefusedBeforeDecrypt() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice], left: true)
        let author = GroupFormAuthor(android, in: group.id)
        fixture.deliver(try author.frame(group, id: "gm-left", body: "gone", sentAt: now), from: alice)
        #expect(fixture.stores.messages.message("gm-left") == nil && fixture.engine.dropped[.groupRatchetNoKey] == nil)
    }

    @Test func aGroupAddressedEnvelopeWithoutTheGroupHeaderIsMalformed() throws {
        let (fixture, _) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let enc = EncEnvelope(version: EncEnvelope.Version.ratchet, nonce: [UInt8](repeating: 0, count: 12), ct: [1, 2, 3, 4], keys: [])
        let envelope = RelayEnvelope(
            type: .chat, id: "v2-grouped", senderId: alice.nodeId.string, sentAt: now, group: group, payload: ChatContent(enc: enc).encoded)
        fixture.deliver(try alice.signed(envelope), from: alice)
        #expect(fixture.engine.dropped[.groupRatchetBadHeader] == 1)
    }

    @Test func aV3GroupAddressedEnvelopeIsABadHeaderNeverAGroupFrame() throws {
        let (fixture, _) = try rig()
        let group = fixture.holdGroup(with: [alice])
        for index in 0..<3 {
            let header = GroupRatchetHeader(se: 1, n: index)
            let enc = EncEnvelope(version: EncEnvelope.Version.compactRatchet, nonce: [], ct: [1, 2, 3, 4], keys: [], groupRatchet: header)
            let envelope = RelayEnvelope(
                type: .chat,
                id: "v3-grouped-\(index)",
                senderId: alice.nodeId.string,
                sentAt: now,
                group: group,
                payload: ChatContent(enc: enc).encoded
            )
            fixture.deliver(try alice.signed(envelope), from: alice)
        }
        #expect(fixture.engine.dropped[.ratchetBadHeader] == 3)
        #expect(fixture.engine.dropped[.groupRatchetBadHeader] == nil && fixture.engine.dropped[.groupRatchetNoKey] == nil)
        #expect(fixture.chats(to: alice).isEmpty && fixture.resetsSent(to: alice).isEmpty, "no key request, no reset")
    }

    @Test func threeDistinctUndecryptableGroupFramesTriggerOneRateLimitedKeyRequest() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        func requests() -> [MessageContent] {
            fixture.controls(to: android).filter { $0.ctl == MessageContent.Control.groupKeyRequest }
        }
        fixture.deliver(try author.frame(group, id: "nk1", body: "x", sentAt: now), from: alice)
        fixture.deliver(try author.frame(group, id: "nk2", body: "x", sentAt: now), from: alice)
        #expect(requests().isEmpty, "two distinct frames are not enough")
        fixture.deliver(try author.frame(group, id: "nk3", body: "x", sentAt: now), from: alice)
        let request = try #require(requests().first, "the third fires one")
        #expect(request.gk == GroupKeyPayload(groupId: group.id) && requests().count == 1)
        for index in 4...6 {
            fixture.deliver(try author.frame(group, id: "nk\(index)", body: "x", sentAt: now), from: alice)
        }
        #expect(requests().count == 1, "inside the floor nothing more")
        #expect(fixture.engine.groupCounts.groupKeyRequestsSent == 1)
        #expect(
            fixture.stores.custody.contains(try #require(fixture.chats(to: alice).first).envelope.id), "originated: carried in our custody")
    }

    @Test func ancientUndecryptableFramesNeverBurnTheKeyRequestBudget() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        let ancient = now - GroupRatchetSessions.requestMaxFrameAgeMilliseconds - 1
        for index in 0..<4 {
            // Past the age window on our clock: custody refuses it as dead on arrival, and the open still meets it.
            fixture.deliver(try author.frame(group, id: "old\(index)", body: "x", sentAt: ancient), from: alice)
        }
        #expect(fixture.chats(to: alice).isEmpty)
        #expect((fixture.engine.dropped[.groupRatchetNoKey] ?? 0) >= 4)
    }

    /// Kotlin's `aKeyRequestCtlInvokesTheRedistributionLambda` (`:6926`): the answer re-seals our current seeds, which needs a
    /// send chain, P6b's. Here a request commits the chain's advance and nothing else, and is never a row.
    @Test func aKeyRequestCtlCommitsTheChainsAdvanceAndNothingElseUntilP6b() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let request = MessageContent(body: "", ctl: MessageContent.Control.groupKeyRequest, gk: GroupKeyPayload(groupId: group.id))
        fixture.deliver(try android.dm(request, to: me, prekey: try fixture.ourPrekey(), id: "req1", sentAt: now), from: android)
        #expect(fixture.stores.messages.message("req1") == nil && fixture.ratchetRecords(of: alice).session != nil, "committed, no row")
        #expect(fixture.controls(to: android).allSatisfy { $0.ctl == MessageContent.Control.profile }, "only our init's answer went")
        #expect(fixture.stores.groupRatchet.holdings(of: group.id) == .empty)
    }
}

/// The key request's seal when it cannot go (`maybeRequestGroupKey`, `InboundPipeline.kt:1702-1712`): toward a member whose
/// profile carries no ratchet nothing is sealed, and a store that fails sends nothing and stamps no floor, so the next
/// frame asks again.
@Suite struct MeshEngineGroupKeyRequestTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private var now: Int64 { EngineFixture.start }

    private func unreadable(_ fixture: EngineFixture, _ author: GroupFormAuthor, _ group: GroupInfo, count: Int, from first: Int) throws {
        for index in first..<(first + count) {
            fixture.deliver(try author.frame(group, id: "nk\(index)", body: "x", sentAt: now), from: author.android.peer)
        }
    }

    @Test func aMemberWithoutTheRatchetIsNeverAsked() throws {
        let fixture = try EngineFixture.ratcheting(me)
        fixture.deliver(try alice.profile(publishedAt: now, capabilities: 0xF), from: alice)
        let group = fixture.holdGroup(with: [alice])
        try unreadable(fixture, GroupFormAuthor(try AndroidPeer(alice), in: group.id), group, count: 3, from: 0)
        #expect(fixture.transport.written(.chat).isEmpty && fixture.engine.groupCounts.groupKeyRequestsSent == 0)
        let refused = "mesh no key request for group \(group.id) to \(alice.nodeId): nothing to seal it with"
        #expect(fixture.log.all.contains { $0.contains(refused) })
    }

    @Test(arguments: StoreKind.allCases)
    func aRequestWhoseUnitFailsSendsNothingAndStampsNoFloor(kind: StoreKind) throws {
        let directory = scratchDirectory("request-fails")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingOpens(blobs: directory, failures: ReportedFailures().record)
        let fixture = try EngineFixture.ratcheting(me, stores: stores)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        fixture.transport.clear()
        refusing.refusesWrites = true
        try unreadable(fixture, author, group, count: 3, from: 0)
        refusing.refusesWrites = false
        #expect(fixture.transport.written(.chat).isEmpty && fixture.engine.groupCounts.groupKeyRequestsSent == 0)
        #expect(fixture.engine.groupRatchet.floors(in: group.id, for: alice.nodeId, now: now).lastKeyRequestAt == nil)
        try unreadable(fixture, author, group, count: 1, from: 3)
        #expect(fixture.engine.groupCounts.groupKeyRequestsSent == 1, "the next frame asks again")
    }
}

/// This port's own cases of the group form's receive side (ADR 2026-10.5sk9, phase P6a2): an ack moving the seed outbox,
/// our own frames coming back after a reinstall, and a plaintext that will not decode.
@Suite struct MeshEngineGroupRatchetEdgeTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)

    private var now: Int64 { EngineFixture.start }

    /// The iPhone with the switch on, and Alice pinned as an Android phone with the ratchet and a prekey.
    private func rig() throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    private func deliverSeed(_ fixture: EngineFixture, _ author: GroupFormAuthor, id: String) throws {
        fixture.deliver(try author.seedDm(to: me, prekey: try fixture.ourPrekey(), id: id, sentAt: now), from: author.android)
    }

    /// This port's own: a member's `CTL_GROUP_KEY_ACK` moves our outbox's row inside its DM's unit (`InboundPipeline.kt:1213-1217`),
    /// only ever up, and an ack for a member with no row is ignored.
    @Test func aSeedAckMovesTheOutboxRowUpOnlyAndOneWithNoRowIsIgnored() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        _ = fixture.engine.groupRatchet.markKeySent(2, to: alice.nodeId, in: group.id, now: now)
        let prekey = try fixture.ourPrekey()
        func ack(_ epoch: Int, id: String, in groupId: String = group.id) throws -> TestFrame {
            let content = MessageContent(
                body: "", ctl: MessageContent.Control.groupKeyAck, gk: GroupKeyPayload(groupId: groupId, ackEpoch: epoch))
            return try android.dm(content, to: me, prekey: prekey, id: id, sentAt: now)
        }
        fixture.deliver(try ack(2, id: "ack-2"), from: android)
        #expect(fixture.stores.groupRatchet.keySend(group.id, member: alice.nodeId)?.ackedEpoch == 2)
        fixture.deliver(try ack(1, id: "ack-1"), from: android)
        #expect(fixture.stores.groupRatchet.keySend(group.id, member: alice.nodeId)?.ackedEpoch == 2, "never lowered")
        fixture.deliver(try ack(3, id: "ack-x", in: "g-unknown"), from: android)
        #expect(fixture.stores.groupRatchet.keySend("g-unknown", member: alice.nodeId) == nil)
        #expect(fixture.stores.messages.message("ack-2") == nil, "machinery, never a row")
    }

    /// This port's own: our own group-form frame, which custody serves back after a reinstall, opens nothing we hold and asks
    /// nobody for a key, however many come back.
    @Test func ourOwnGroupFramesComingBackAskNobodyForAKey() throws {
        let (fixture, _) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let ownAuthor = GroupFormAuthor(try AndroidPeer(me), in: group.id)
        for index in 0..<4 {
            fixture.deliver(try ownAuthor.frame(group, id: "own\(index)", body: "mine", sentAt: now), from: alice)
        }
        #expect(fixture.engine.dropped[.groupRatchetNoKey] == 4)
        #expect(fixture.transport.written(.chat).isEmpty, "no request, to ourselves or anyone")
        #expect(fixture.engine.groupRatchet.floors(in: group.id, for: me.nodeId, now: now).undecryptableIds == 0, "never evidence")
    }

    /// A group frame whose plaintext will not decode drops before its commit, the chain index unspent, as Kotlin drops it
    /// on the peek (`InboundPipeline.kt:1621-1629`).
    @Test func aGroupFrameThatWillNotDecodeLeavesTheChainWhereItWas() throws {
        let (fixture, android) = try rig()
        let group = fixture.holdGroup(with: [alice])
        let author = GroupFormAuthor(android, in: group.id)
        try deliverSeed(fixture, author, id: "seed1")
        fixture.deliver(try author.frame(group, id: "gm-junk", sealing: [0x01], sentAt: now), from: alice)
        #expect(fixture.engine.dropped[.cannotOpen] == 1 && fixture.stores.messages.message("gm-junk") == nil)
        #expect(fixture.recvChains(group.id, from: alice).first?.next == 0, "nothing spent")
    }
}
