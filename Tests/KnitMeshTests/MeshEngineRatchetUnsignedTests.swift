import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The unsigned v3 live-link tick and the switch (ADR 2026-10.5sk9, phase P5a): with the ratchet on, a `relay = false`
/// DM-form chat to us from a pinned peer is admitted unsigned, ahead of the exists-gate, and must open as a v3 receipt
/// before anything commits; it is never carried, never relayed and never counted toward a reset
/// (`InboundPipelineTest.kt:5868-5999`). With the switch off nothing of the ratchet's opens, and nothing is stored or sent.
@Suite struct MeshEngineRatchetUnsignedTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private let bob = TestPeer(seed: 3)

    private func rig() throws -> (EngineFixture, AndroidPeer) {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        try fixture.pin(bob)
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

    /// One of our DMs to `peer`, as this build sends one.
    private func ourDM(_ fixture: EngineFixture, to peer: TestPeer) throws -> String {
        let record = try #require(fixture.engine.sendDirectMessage("hi", to: peer.nodeId))
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        return record.id
    }

    private func tick(acking id: String) -> MessageContent {
        MessageContent(body: "", ctl: MessageContent.Control.receipt, ack: id)
    }

    /// `frame` with its ciphertext replaced by garbage under the same header: a forgery that fails the AEAD
    /// (`forged`, `InboundPipelineTest.kt:5847-5866`).
    private func forged(_ envelope: inout EncEnvelope) {
        envelope.ct = (0..<envelope.ct.count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
    }

    @Test func anUnsignedV3TickFromAPinnedPeerAppliesTheReceipt() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        fixture.link(bob)
        let out = try ourDM(fixture, to: alice)
        let frame = try android.dm(
            tick(acking: out), to: me, prekey: prekey, id: "tick-1", sentAt: now, v3: true, signed: false, relay: false)
        fixture.deliver(frame, from: android)
        fixture.advance(1000)
        #expect(fixture.stores.messages.message(out)?.delivered == true)
        #expect(fixture.engine.dropped[.unsigned] == nil && fixture.engine.dropped[.badSignature] == nil)
        #expect(fixture.stores.messages.message("tick-1") == nil)
        #expect(!fixture.stores.custody.contains("tick-1"), "point to point, so never carried")
        #expect(fixture.transport.written(.chat).isEmpty && fixture.transport.written(.receipt).isEmpty, "never acknowledged or relayed")
    }

    @Test func theUnsignedDoorRefusesEveryOtherShape() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let out = try ourDM(fixture, to: alice)

        // Flooded: the signature is what every relay and carrier needs.
        let flooded = try android.dm(
            tick(acking: out), to: me, prekey: prekey, id: "u-relay", sentAt: now, v3: true, signed: false, relay: true)
        fixture.deliver(flooded, from: android)
        #expect(fixture.engine.dropped[.unsigned] == 1)
        #expect(!fixture.stores.custody.contains("u-relay"))

        // Addressed to someone else: not our tick, and not our session.
        let foreign = try android.dm(
            tick(acking: out), to: me, prekey: prekey, id: "u-foreign", sentAt: now, v3: true, signed: false, relay: false)
        var readdressed = foreign.envelope
        readdressed.recipientId = bob.nodeId.string
        fixture.deliver(
            TestFrame(wire: WireEnvelope(relay: false, sig: [], signed: readdressed.encoded), envelope: readdressed), from: android)
        #expect(fixture.engine.dropped[.unsigned] == 2)

        // v2: the right shape at the door, the wrong scheme behind it.
        let v2 = try android.dm(tick(acking: out), to: me, prekey: prekey, id: "u-v2", sentAt: now, signed: false, relay: false)
        fixture.deliver(v2, from: android)
        #expect(fixture.engine.dropped[.unsigned] == 3)

        // A DM in the clear.
        let clear = RelayEnvelope(
            type: .chat,
            id: "u-clear",
            senderId: alice.nodeId.string,
            sentAt: now,
            recipientId: me.nodeId.string,
            payload: ChatContent(body: "hello").encoded
        )
        fixture.deliver(TestFrame(wire: WireEnvelope(relay: false, sig: [], signed: clear.encoded), envelope: clear), from: android)
        #expect(fixture.engine.dropped[.unsigned] == 4)
        #expect(fixture.stores.messages.message("u-clear") == nil)

        // A plain v3 DM with its signature stripped opens, and is refused anyway, before its unit commits: the index stays
        // unspent, so the signed copy, past the router's window, still opens.
        let plain = try android.dm(MessageContent(body: "a real message"), to: me, prekey: prekey, id: "u-plain", sentAt: now, v3: true)
        let stripped = TestFrame(wire: WireEnvelope(relay: false, sig: [], signed: plain.envelope.encoded), envelope: plain.envelope)
        // Our DM above started a session of ours (phase P5b): the refused open must leave it as it was.
        let held = fixture.ratchetRecords(of: alice)
        fixture.deliver(stripped, from: android)
        #expect(fixture.engine.dropped[.unsigned] == 5)
        #expect(fixture.stores.messages.message("u-plain") == nil)
        #expect(fixture.ratchetRecords(of: alice) == held, "nothing committed")
        fixture.advance(SeenSet.defaultWindowMilliseconds + 1000)
        fixture.deliver(plain, from: android)
        #expect(fixture.stores.messages.message("u-plain")?.body == "a real message")

        #expect(fixture.stores.messages.message(out)?.delivered == false)
        #expect(fixture.resetsSent(to: alice).isEmpty)
    }

    @Test func forgedUnsignedFramesFeedNeitherTheResetHeuristicNorTheExistsGate() throws {
        let (fixture, android) = try rig()
        let prekey = try fixture.ourPrekey()
        let real = canonicalId(1)
        fixture.deliver(try android.dm("hello", to: me, prekey: prekey, id: real, sentAt: now, v3: true), from: android)
        #expect(fixture.stores.messages.message(real)?.body == "hello")
        #expect(fixture.acknowledged == [real])

        for index in 0..<RatchetResetPolicy.distinctFrames {
            let frame = try android.dm(
                tick(acking: real),
                to: me,
                prekey: prekey,
                id: "forged-\(index)",
                sentAt: now,
                v3: true,
                signed: false,
                relay: false,
                edit: forged
            )
            fixture.deliver(frame, from: android)
        }
        #expect(fixture.engine.dropped[.ratchetAeadFail] == 3, "counted under their reason")
        #expect(fixture.resetsSent(to: alice).isEmpty, "forgeries anyone can mint never buy a reset")
        #expect(fixture.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 0)

        // A forgery naming a DM we hold must not make us acknowledge it again: the unsigned door skips the exists-gate.
        let oracle = try android.dm(
            tick(acking: real), to: me, prekey: prekey, id: real, sentAt: now, v3: true, signed: false, relay: false, edit: forged)
        fixture.deliverPastRouter(oracle, from: alice)
        #expect(fixture.acknowledged == [real])

        fixture.deliver(try android.dm("still here", to: me, prekey: prekey, id: "real-2", sentAt: now + 1, v3: true), from: android)
        #expect(fixture.stores.messages.message("real-2")?.body == "still here", "the genuine session is unharmed")

        // An unsigned tick from someone never pinned is a missing key, parked for it, not an unsigned refusal.
        let stranger = try AndroidPeer(TestPeer(seed: 9))
        let orphan = try stranger.dm(
            tick(acking: real), to: me, prekey: prekey, id: "orphan", sentAt: now, v3: true, signed: false, relay: false)
        fixture.deliver(orphan, from: stranger)
        #expect(fixture.engine.dropped[.noSenderKey] == 1)
        #expect(fixture.engine.dropped[.unsigned] == nil)
    }

    @Test func withTheSwitchOffV2AndV3DropUnopenedAndNothingIsStoredOrSent() throws {
        let fixture = EngineFixture(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        _ = fixture.engine.drainEvents()
        fixture.transport.clear()
        // A prekey of ours a peer could have pinned while the switch was on: the frames are the real thing.
        let ours = try SignedPrekey.mint(id: 1, signedBy: me.keys, createdAt: 0)
        let prekey = try #require(PeerPrekey(verifying: ours.info, signedBy: me.keys.bundle))
        fixture.deliver(try android.dm("v2", to: me, prekey: prekey, id: "off-2", sentAt: now), from: android)
        fixture.deliver(try android.dm("v3", to: me, prekey: prekey, id: "off-3", sentAt: now + 1, v3: true), from: android)
        let out = try #require(fixture.engine.sendDirectMessage("hi", to: alice.nodeId)).id
        fixture.transport.clear()
        fixture.deliver(
            try android.dm(
                tick(acking: out), to: me, prekey: prekey, id: "off-tick", sentAt: now + 2, v3: true, signed: false, relay: false),
            from: android)
        #expect(fixture.engine.dropped[.cannotOpen] == 2)
        #expect(fixture.engine.dropped[.unsigned] == 1, "the door is shut")
        #expect(fixture.stores.messages.message("off-2") == nil && fixture.stores.messages.message("off-3") == nil)
        #expect(fixture.stores.messages.message(out)?.delivered == false)
        #expect(fixture.ratchetRecords(of: alice) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
        #expect(fixture.transport.written.isEmpty, "no receipt, no reset")
        #expect(fixture.stores.custody.contains("off-2") && fixture.stores.custody.contains("off-3"), "still carried")
    }
}
