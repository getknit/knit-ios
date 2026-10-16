import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// What a sealed ctl and a plain DM's inline acks apply on receive, in the open's own unit, with the switch on (ADR
/// 2026-10.5sk9, phase P5a): knit-next's `InboundPipelineTest` cases for sealed receipts and reactions, ported by name
/// (`InboundPipelineTest.kt:5762-6544`); sealed profiles are `MeshEngineRatchetProfileTests`'. A ctl is never a row, a
/// notification or an acknowledgement, and a sealed receipt purges nothing (ADR 2026-09.p6nb, amended).
@Suite struct MeshEngineRatchetControlTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    /// The longest RGI emoji sequence, 35 bytes of UTF-8 (`LONGEST_RGI`, `InboundPipelineTest.kt:7503`).
    private static let longestRGI = "\u{1F469}\u{1F3FD}\u{200D}\u{2764}\u{FE0F}\u{200D}\u{1F48B}\u{200D}\u{1F468}\u{1F3FC}"

    /// The iPhone with the switch on, Alice pinned (at `version`, with her prekey unless told otherwise), and Carol.
    private func rig(version: Int64? = nil, prekey withPrekey: Bool = true) throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        let profile = try alice.profile(
            name: "Ann",
            version: version,
            publishedAt: now,
            capabilities: AndroidPeer.capabilities,
            prekey: withPrekey ? android.prekey.info : nil
        )
        fixture.deliver(profile, from: alice)
        try fixture.pin(carol)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    private var now: Int64 { EngineFixture.start }

    /// A canonical frame id, which the compact layout carries as 16 raw bytes.
    private func canonicalId(_ seed: UInt64) -> String {
        var generator = SeededGenerator(seed: seed)
        return FrameId.generate(using: &generator)
    }

    /// One of our DMs to `peer`, sent as this build sends one (v1), held in our custody: what the forged-ack guard reads.
    private func ourDM(_ fixture: EngineFixture, to peer: TestPeer) throws -> String {
        let record = try #require(fixture.engine.sendDirectMessage("hi", to: peer.nodeId))
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return record.id
    }

    private func control(_ ctl: Int, ack: String? = nil, acks: [String]? = nil, rp: ReactionContent? = nil) -> MessageContent {
        MessageContent(body: "", ctl: ctl, ack: ack, rp: rp, acks: acks)
    }

    @Test func aSealedDmReceiptFlipsTheTickWithoutPurgingCustody() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let out = try ourDM(fixture, to: alice)
        let receipt = control(MessageContent.Control.receipt, ack: out)
        fixture.deliver(try android.dm(receipt, to: me, prekey: prekey, id: "ctl-r1", sentAt: now), from: android)
        #expect(fixture.stores.messages.message(out)?.delivered == true)
        #expect(deliveredIds(in: fixture.engine.drainEvents()) == [out])
        #expect(fixture.stores.custody.contains(out), "a carrier cannot read a sealed receipt, so nobody purges")
        #expect(fixture.stores.messages.message("ctl-r1") == nil)
        #expect(fixture.transport.written(.receipt).isEmpty, "no acknowledgement of an acknowledgement")
    }

    @Test func aSealedReceiptFromANonRecipientIsIgnored() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let toCarol = try ourDM(fixture, to: carol)
        let receipt = control(MessageContent.Control.receipt, ack: toCarol)
        fixture.deliver(try android.dm(receipt, to: me, prekey: prekey, id: "ctl-r2", sentAt: now), from: android)
        #expect(fixture.stores.messages.message(toCarol)?.delivered == false)
        #expect(deliveredIds(in: fixture.engine.drainEvents()).isEmpty)
    }

    @Test func aBatchedSealedTickFlipsEveryListedId() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let first = try #require(fixture.engine.postToRoom("a")).id
        let second = try #require(fixture.engine.postToRoom("b")).id
        let toCarol = try ourDM(fixture, to: carol)
        let receipt = control(MessageContent.Control.receipt, acks: [first, second, toCarol])
        fixture.deliver(try android.dm(receipt, to: me, prekey: prekey, id: "tick-b1", sentAt: now), from: android)
        #expect(fixture.stores.messages.message(first)?.delivered == true)
        #expect(fixture.stores.messages.message(second)?.delivered == true)
        #expect(fixture.stores.messages.message(toCarol)?.delivered == false, "a DM addressed to someone else never flips")
        #expect(fixture.stores.messages.message("tick-b1") == nil)
    }

    @Test func aSealedTickForAGroupMessageStillFlipsTheTick() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let group = try #require(fixture.engine.createGroup(with: [alice.nodeId]))
        let message = try #require(fixture.engine.sendGroupMessage("hi all", to: group.id)).id
        let receipt = control(MessageContent.Control.receipt, ack: message)
        fixture.deliver(try android.dm(receipt, to: me, prekey: prekey, id: "ctl-g1", sentAt: now), from: android)
        #expect(fixture.stores.messages.message(message)?.delivered == true)
    }

    @Test func aReceiptAcknowledgesAtMostItsBoundEachIdOnce() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let out = try ourDM(fixture, to: alice)
        // The id once, then 200 others: only the first 128 distinct ids are read (`MAX_RECEIPT_ACKS`).
        let receipt = control(MessageContent.Control.receipt, ack: out, acks: [out] + (0..<200).map { "other-\($0)" })
        fixture.deliver(try android.dm(receipt, to: me, prekey: prekey, id: "ctl-many", sentAt: now), from: android)
        #expect(deliveredIds(in: fixture.engine.drainEvents()) == [out], "flipped once")
    }

    @Test func aPlainDmCarryingInlineAcksFlipsThoseTicksUnderTheForgedAckGuard() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let out = try ourDM(fixture, to: alice)
        let toCarol = try ourDM(fixture, to: carol)
        let reply = MessageContent(body: "thanks", acks: [out, toCarol])
        let frame = try android.dm(reply, to: me, prekey: prekey, id: "reply-1", sentAt: now)
        fixture.deliver(frame, from: android)
        #expect(fixture.stores.messages.message("reply-1")?.body == "thanks")
        #expect(fixture.stores.messages.message(out)?.delivered == true)
        #expect(fixture.stores.messages.message(toCarol)?.delivered == false)
        #expect(deliveredIds(in: fixture.engine.drainEvents()) == [out])
        #expect(fixture.acknowledged(by: android) == ["reply-1"])
        // A copy re-served later stops at the exists-gate, so nothing re-applies.
        fixture.deliverPastRouter(frame, from: alice)
        #expect(deliveredIds(in: fixture.engine.drainEvents()).isEmpty)
    }

    @Test func aV3DmDecryptsWithItsCompactContentAndItsInlineAcks() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let first = try ourDM(fixture, to: alice)
        let second = try ourDM(fixture, to: alice)
        let id = "v3-acks"
        let frame = try android.dm(
            MessageContent(body: "compact hello", acks: [first, second]), to: me, prekey: prekey, id: id, sentAt: now, v3: true)
        fixture.deliver(frame, from: android)
        #expect(fixture.stores.messages.message(id)?.body == "compact hello")
        #expect(Set(deliveredIds(in: fixture.engine.drainEvents())) == [first, second])
        #expect(fixture.acknowledged(by: android) == [id], "the receipt back, sealed since P5d")
    }

    @Test func aSealedDmReactionAppliesAndRetractsWithTheFramesSentAtAsTheLwwClock() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let add = control(MessageContent.Control.reaction, rp: ReactionContent(messageId: "m1", emoji: "👍"))
        fixture.deliver(try android.dm(add, to: me, prekey: prekey, id: "ctl-x1", sentAt: now + 7), from: android)
        let added = fixture.stores.messages.reaction(on: "m1", by: alice.nodeId)
        #expect(added == ReactionRecord(messageId: "m1", reactor: alice.nodeId, emoji: "👍", updatedAt: now + 7))
        let retract = control(MessageContent.Control.reaction, rp: ReactionContent(messageId: "m1"))
        fixture.deliver(try android.dm(retract, to: me, prekey: prekey, id: "ctl-x2", sentAt: now + 9), from: android)
        let retracted = fixture.stores.messages.reaction(on: "m1", by: alice.nodeId)
        #expect(retracted == ReactionRecord(messageId: "m1", reactor: alice.nodeId, emoji: nil, updatedAt: now + 9))
        #expect(fixture.stores.messages.message("ctl-x1") == nil)
        #expect(fixture.transport.written(.receipt).isEmpty)
        #expect(receivedRecords(in: fixture.engine.drainEvents()).isEmpty)
    }

    @Test func aSealedReactionToAMessageWeHoldIsAnnounced() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let out = try ourDM(fixture, to: alice)
        let add = control(MessageContent.Control.reaction, rp: ReactionContent(messageId: out, emoji: "❤️"))
        fixture.deliver(try android.dm(add, to: me, prekey: prekey, id: "ctl-x3", sentAt: now), from: android)
        let announced = fixture.engine.drainEvents().contains { event in
            guard case .reacted(let reaction) = event else {
                return false
            }
            return reaction.messageId == out && reaction.reactor == alice.nodeId
        }
        #expect(announced)
    }

    @Test func anOversizedSealedDmReactionAdvancesTheChainAndAppliesNothing() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let oversized = control(
            MessageContent.Control.reaction, rp: ReactionContent(messageId: "m1", emoji: String(repeating: "👍", count: 17)))
        fixture.deliver(try android.dm(oversized, to: me, prekey: prekey, id: "ctl-o1", sentAt: now + 7), from: android)
        let fine = control(MessageContent.Control.reaction, rp: ReactionContent(messageId: "m1", emoji: "👍"))
        fixture.deliver(try android.dm(fine, to: me, prekey: prekey, id: "ctl-o2", sentAt: now + 9), from: android)
        #expect(fixture.stores.messages.reaction(on: "m1", by: alice.nodeId)?.updatedAt == now + 9)
        #expect(fixture.engine.dropped[.reactionRefused] == 1)
        #expect(fixture.ratchetRecords(of: alice).recvEpochs.map(\.next) == [2], "the refused one still spent its index")
    }

    @Test func aSealedV3ReactionWithTheLongestRgiSequenceApplies() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let target = canonicalId(11)
        let reaction = control(MessageContent.Control.reaction, rp: ReactionContent(messageId: target, emoji: Self.longestRGI))
        fixture.deliver(try android.dm(reaction, to: me, prekey: prekey, id: "ctl-v3l", sentAt: now + 7, v3: true), from: android)
        #expect(fixture.stores.messages.reaction(on: target, by: alice.nodeId)?.emoji == Self.longestRGI)
        #expect(fixture.engine.dropped[.reactionRefused] == nil)
    }

    @Test func aCtlWithoutItsPayloadAdvancesTheChainAndAppliesNothing() throws {
        let (fixture, android) = try rig(version: 10)
        let prekey = try fixture.ourPrekey()
        let before = try #require(fixture.stores.peers.peer(alice.nodeId))
        for (index, ctl) in [MessageContent.Control.reaction, MessageContent.Control.profile].enumerated() {
            let empty = MessageContent(body: "", ctl: ctl)
            fixture.deliver(
                try android.dm(empty, to: me, prekey: prekey, id: "ctl-empty-\(index)", sentAt: now + Int64(index)), from: android)
        }
        #expect(fixture.ratchetRecords(of: alice).recvEpochs.map(\.next) == [2])
        #expect(fixture.stores.peers.peer(alice.nodeId) == before)
        #expect(fixture.engine.drainEvents().isEmpty)
        #expect(fixture.engine.dropped.isEmpty)
    }
}
