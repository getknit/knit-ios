import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// DM-form v2 and v3 frames received through the engine with the ratchet's switch on (ADR 2026-10.5sk9, phase P5a):
/// knit-next's `InboundPipelineTest` receive-side ratchet cases, ported by name (`InboundPipelineTest.kt:4797-5460`).
/// Android is ``AndroidPeer``, which seals with a `RatchetSessions` of its own. Where Kotlin's rig delivers to the pipeline
/// past the router, these do the same (``deliverPastRouter(_:_:from:)``).
@Suite struct MeshEngineRatchetInboundTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)

    /// The iPhone with the switch on, Alice pinned with her prekey, and nothing recorded yet.
    private func rig() throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return (fixture, android)
    }

    private var now: Int64 { EngineFixture.start }

    @Test func aV2InitDmDecryptsPersistsAndEstablishesTheSession() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        fixture.deliver(try android.dm("ratchet hello", to: me, prekey: prekey, id: "v2-1", sentAt: now), from: android)
        #expect(fixture.stores.messages.message("v2-1")?.body == "ratchet hello")
        let session = try #require(fixture.ratchetRecords(of: alice).session)
        #expect(session.confirmed && !session.weAreInitiator)
        #expect(fixture.ratchetRecords(of: alice).recvEpochs.map(\.next) == [1])
        #expect(receivedRecords(in: fixture.engine.drainEvents()).map(\.id) == ["v2-1"])
        #expect(fixture.acknowledged == ["v2-1"], "the DM's receipt goes out, in the clear until P5c seals it")

        fixture.deliver(try android.dm("still here", to: me, prekey: prekey, id: "v2-2", sentAt: now + 1), from: android)
        #expect(fixture.stores.messages.message("v2-2")?.body == "still here")
        #expect(fixture.ratchetRecords(of: alice).recvEpochs.map(\.next) == [2])
    }

    @Test func v2OutOfOrderDeliveryDrainsThroughSkippedKeys() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let first = try android.dm("first", to: me, prekey: prekey, id: "v2-m0", sentAt: now)
        let second = try android.dm("second", to: me, prekey: prekey, id: "v2-m1", sentAt: now + 1)
        fixture.deliver(second, from: android)
        #expect(fixture.ratchetRecords(of: alice).skippedKeys.map(\.index) == [0])
        fixture.deliver(first, from: android)
        #expect(fixture.stores.messages.message("v2-m1")?.body == "second")
        #expect(fixture.stores.messages.message("v2-m0")?.body == "first")
        #expect(fixture.ratchetRecords(of: alice).skippedKeys.isEmpty, "the key stored for the gap, spent and gone")
    }

    @Test func aReServedV2FrameShortCircuitsBeforeTheRatchetAndStillAcks() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let frame = try android.dm("once", to: me, prekey: prekey, id: "v2-r", sentAt: now)
        fixture.deliver(frame, from: android)
        // With the ratchet's rows gone, a copy that reached the engine would fail as NO_SESSION: the exists-gate answers
        // before any crypto runs.
        fixture.stores.ratchet.deletePeer(alice.nodeId)
        fixture.deliverPastRouter(frame, from: alice)
        #expect(fixture.stores.messages.message("v2-r")?.body == "once")
        #expect(fixture.acknowledged == ["v2-r", "v2-r"], "each copy is acknowledged")
        #expect(fixture.engine.dropped[.ratchetNoSession] == nil)
        #expect(fixture.engine.dropped[.cannotOpen] == nil)
    }

    @Test func aV2EnvelopeWithoutItsHeaderIsBadHeaderNotACrash() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let frame = try android.dm(MessageContent(body: "hi"), to: me, prekey: prekey, id: "v2-bad", sentAt: now) { $0.ratchet = nil }
        fixture.deliver(frame, from: android)
        #expect(fixture.engine.dropped[.ratchetBadHeader] == 1)
        #expect(fixture.stores.messages.message("v2-bad") == nil)
    }

    @Test func aDmAddressedEnvelopeWithOnlyAGroupHeaderIsMalformed() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let frame = try android.dm(MessageContent(body: "hi"), to: me, prekey: prekey, id: "gdm", sentAt: now) { envelope in
            envelope.ratchet = nil
            envelope.groupRatchet = GroupRatchetHeader(se: 1, n: 0)
        }
        fixture.deliver(frame, from: android)
        #expect(fixture.engine.dropped[.ratchetBadHeader] == 1, "a stray `g` does not make a DM a group frame")
        #expect(fixture.stores.messages.message("gdm") == nil)
    }

    @Test func aV2FrameWithoutInitToAFreshDeviceIsNoSession() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let orphan = try android.dm(MessageContent(body: "lost"), to: me, prekey: prekey, id: "v2-orphan", sentAt: now) { envelope in
            envelope.ratchet = envelope.ratchet?.steady
        }
        fixture.deliver(orphan, from: android)
        #expect(fixture.engine.dropped[.ratchetNoSession] == 1)
        #expect(fixture.stores.messages.message("v2-orphan") == nil)
        #expect(fixture.ratchetRecords(of: alice).session == nil)
    }

    @Test func aMisshapenNonceIsABadHeaderNeverAResetTrigger() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let content = MessageContent(body: "x")
        let frames = [
            try android.dm(content, to: me, prekey: prekey, id: "v3-with-nonce", sentAt: now, v3: true) { envelope in
                envelope.nonce = [UInt8](repeating: 0, count: 12)
            },
            try android.dm(content, to: me, prekey: prekey, id: "v2-without-nonce", sentAt: now) { $0.nonce = [] },
            try android.dm(content, to: me, prekey: prekey, id: "v2-short-nonce", sentAt: now) { $0.nonce = [1, 2, 3] },
        ]
        for frame in frames {
            fixture.deliver(frame, from: android)
        }
        #expect(fixture.engine.dropped[.ratchetBadHeader] == 3)
        #expect(fixture.engine.dropped[.ratchetAeadFail] == nil, "an empty v2 nonce is never read as v3")
        #expect(fixture.resetsSent(to: alice).isEmpty)
        #expect(fixture.stores.messages.messages(in: alice.nodeId.string).isEmpty)
        #expect(fixture.ratchetRecords(of: alice).session == nil, "nothing committed")
    }

    @Test func aCtlFrameAdvancesTheChainButNeverPersistsNotifiesOrAcks() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let reset = MessageContent(body: "", ctl: MessageContent.Control.sessionReset)
        fixture.deliver(try android.dm(reset, to: me, prekey: prekey, id: "v2-ctl", sentAt: now), from: android)
        #expect(fixture.stores.messages.message("v2-ctl") == nil)
        #expect(fixture.transport.written(.receipt).isEmpty)
        #expect(receivedRecords(in: fixture.engine.drainEvents()).isEmpty)
        #expect(fixture.ratchetRecords(of: alice).recvEpochs.map(\.next) == [1], "the control frame's step is not a hole")
    }

    @Test func anUnknownCtlCodeAdvancesTheChainAndDoesNothing() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        // The group form's codes, until P6, take the same path as a code nobody has minted.
        for (index, ctl) in [99, MessageContent.Control.groupKey, MessageContent.Control.groupKeyAck].enumerated() {
            let content = MessageContent(body: "", ctl: ctl)
            fixture.deliver(try android.dm(content, to: me, prekey: prekey, id: "ctl-u\(index)", sentAt: now + Int64(index)), from: android)
        }
        fixture.deliver(try android.dm("still alive", to: me, prekey: prekey, id: "dm-after", sentAt: now + 9), from: android)
        #expect(fixture.stores.messages.message("dm-after")?.body == "still alive")
        #expect(fixture.stores.messages.messages(in: alice.nodeId.string).map(\.id) == ["dm-after"])
        #expect(fixture.ratchetRecords(of: alice).recvEpochs.map(\.next) == [4])
        #expect(fixture.acknowledged == ["dm-after"])
    }

    @Test func aBlockedPeersSealedCtlDiesAtTheBlockedGate() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        fixture.engine.block(alice.nodeId)
        let reaction = MessageContent(body: "", ctl: MessageContent.Control.reaction, rp: ReactionContent(messageId: "m1", emoji: "👍"))
        fixture.deliver(try android.dm(reaction, to: me, prekey: prekey, id: "ctl-b1", sentAt: now), from: android)
        #expect(fixture.stores.messages.reaction(on: "m1", by: alice.nodeId) == nil)
        #expect(fixture.ratchetRecords(of: alice).session == nil, "never opened, so no chain moved")
        #expect(fixture.engine.dropped[.blocked] == 1)
    }

    @Test func aV3DmOpensWithItsCompactContent() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let frame = try android.dm("compact hello", to: me, prekey: prekey, id: "v3-1", sentAt: now, v3: true)
        let enc = try #require(try ChatContent(decoding: frame.envelope.payload).enc)
        #expect(enc.version == EncEnvelope.Version.compactRatchet && enc.nonce.isEmpty)
        fixture.deliver(frame, from: android)
        #expect(fixture.stores.messages.message("v3-1")?.body == "compact hello")
        #expect(fixture.acknowledged == ["v3-1"])
    }

    @Test func aPlaintextThatOpensAndWillNotDecodeCommitsNothing() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        // A v2 plaintext that is no `MessageContent`: Kotlin drops it as DECRYPT_FAILED before its commit (`:1043-1047`).
        let aad = MessageCrypto.header(id: "junk", senderId: alice.nodeId.string, sentAt: now, thread: me.nodeId.string)
        let answer = android.sessions.sealDm(to: me.keys.bundle, prekey: prekey, plaintext: [0xFF, 0x00], aad: aad, now: now)
        guard case .settled(.sealed(let envelope)) = answer else {
            Issue.record("the seal: \(answer)")
            return
        }
        let relay = RelayEnvelope(
            type: .chat,
            id: "junk",
            senderId: alice.nodeId.string,
            sentAt: now,
            recipientId: me.nodeId.string,
            payload: ChatContent(enc: envelope).encoded
        )
        fixture.deliver(try alice.signed(relay), from: alice)
        #expect(fixture.engine.dropped[.cannotOpen] == 1)
        #expect(fixture.ratchetRecords(of: alice).session == nil, "nothing committed, so the index stays unspent")
        #expect(fixture.transport.written.isEmpty)
    }
}

extension EngineFixture {
    /// Hands the engine a frame from `peer` past the router's dedup, as Kotlin's pipeline rig does, or as a copy past the
    /// router's ten minutes would arrive.
    func deliverPastRouter(_ frame: TestFrame, from peer: TestPeer) {
        engine.deliver(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: peer.nodeId))
    }
}

extension RatchetHeader {
    /// This header as a peer that holds the session settled sends it: no init, and based on our first epoch, the frames a
    /// fresh device or one in another era cannot open (`InboundPipelineTest.kt:4884-4887`, `:5115-5118`).
    var steady: Self {
        var header = self
        header.initial = nil
        header.pe = 1
        return header
    }

    /// This header with its index moved on by `step`: the keys still resolve, and the tag refuses, as a root the pair no
    /// longer shares does (`InboundPipelineTest.kt:4911-4917`).
    func skipping(_ step: Int) -> Self {
        var header = self
        header.n += step
        return header
    }
}
