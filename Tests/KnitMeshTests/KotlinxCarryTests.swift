import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The carry gate, the link and the ratchet's open follow Android's kotlinx decode with no engine change (knit-ios #14):
/// a frame Android's `canCarry` refuses stays out of custody and the digest here, one it carries is carried here, a link
/// frame `decodeWire` refuses goes no further than the link, and a sealed plaintext Android drops before its commit drops
/// here before ours.
@Suite struct KotlinxCarryTests {
    private let me = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private var now: Int64 { EngineFixture.start }

    /// A definite-length map of text keys and raw values, for values the encoder never writes, such as `BF FF`.
    private func map(_ entries: [(String, [UInt8])]) -> [UInt8] {
        #expect(entries.count < 24, "a one-byte map header")
        var bytes: [UInt8] = [0xA0 | UInt8(entries.count)]
        for (key, value) in entries {
            bytes += CBOR.text(key).encoded + value
        }
        return bytes
    }

    /// Bob's signed frame around exactly `signed`, decoded as the link decodes it.
    private func frame(signed: [UInt8], from peer: TestPeer) throws -> TestFrame {
        TestFrame(
            wire: WireEnvelope(sig: try peer.keys.signature(for: signed), signed: signed), envelope: try RelayEnvelope(decoding: signed))
    }

    /// A room post from Bob whose payload is exactly `payload`.
    private func roomPost(_ label: String, payload: [UInt8]) throws -> TestFrame {
        try bob.signed(RelayEnvelope(type: .chat, id: frameIdOf(label), senderId: bob.nodeId.string, sentAt: now, payload: payload))
    }

    private func rig() throws -> EngineFixture {
        let fixture = EngineFixture(me)
        fixture.link(bob)
        try fixture.pin(bob)
        return fixture
    }

    @Test func aRoomPostIsCarriedExactlyWhenAndroidWouldCarryIt() throws {
        let fixture = try rig()
        let honest = GoldenVectors.bytes("chatContentVideo")
        let video = try CBOR.decode(honest)
        guard case .map(let entries) = video else {
            Issue.record("not a map")
            return
        }
        func with(_ key: String, _ value: CBOR) -> [UInt8] {
            CBOR.map(entries.map { $0.key == .text(key) ? CBOR.Entry(key: $0.key, value: value) : $0 }).encoded
        }
        let wideWidth = try #require(video[key: "video"]).replacing("width", with: .unsigned(.max))
        let carried: [(String, [UInt8])] = [
            ("wide-width", with("video", wideWidth)),
            ("honest-video", honest),
            ("marked-reply", map([("body", CBOR.text("hi").encoded), ("replyTo", [0xA0])])),
        ]
        let refused: [(String, [UInt8])] = [
            ("wrong-video", with("video", .text("clip"))),
            ("long-empty-reply", map([("body", CBOR.text("hi").encoded), ("replyTo", [0xBF, 0xFF])])),
        ]
        for (label, payload) in carried + refused {
            fixture.deliver(try roomPost(label, payload: payload), from: bob)
        }
        let live = fixture.stores.custody.liveIds(now: now)
        for (label, _) in carried {
            #expect(
                fixture.stores.custody.contains(frameIdOf(label)) && live.contains(frameIdOf(label)), "\(label) carried and in the digest")
        }
        for (label, _) in refused {
            #expect(!fixture.stores.custody.contains(frameIdOf(label)) && !live.contains(frameIdOf(label)), "\(label) neither")
        }
    }

    /// `group: A0` is no roster, as kotlinx reads the null mark, so the frame is a room post, held on the room's TTL.
    @Test func anEnvelopeWhoseGroupIsTheNullMarkIsARoomPost() throws {
        let fixture = try rig()
        let signed = map([
            ("type", CBOR.text("chat").encoded), ("id", CBOR.text(frameIdOf("marked-group")).encoded),
            ("senderId", CBOR.text(bob.nodeId.string).encoded), ("sentAt", CBOR(now).encoded), ("group", [0xA0]),
            ("payload", CBOR.bytes(ChatContent(body: "hi").encoded).encoded),
        ])
        let post = try frame(signed: signed, from: bob)
        #expect(post.envelope.isRoomPost)
        fixture.deliver(post, from: bob)
        let ttl = CustodyLimits().roomChatTTLMilliseconds
        #expect(fixture.stores.custody.liveIds(now: now + ttl).contains(frameIdOf("marked-group")))
        #expect(!fixture.stores.custody.liveIds(now: now + ttl + 1).contains(frameIdOf("marked-group")), "the room's TTL, not a DM's")
        #expect(fixture.stores.messages.message(frameIdOf("marked-group"))?.body == "hi")
    }

    /// `decodeWire` refuses a negative `ttl` or `hops` (`Wire.kt:1071-1076`), so the link drops the record before the
    /// crossing and the seen set, and the honest copy of the same signed bytes on the same link still gets through.
    @Test func aNegativeTtlStopsAtTheLinkAndTheHonestCopyStillArrives() throws {
        let rig = LinkRig(local: LinkRig.high)
        let channel = ChannelID(100)
        _ = rig.accept(LinkRig.low, on: channel)
        let honest = LinkRig.signedFrame(frameIdOf("ttl"))
        func record(ttl: CBOR) -> [UInt8] {
            let wire = CBOR.map([
                CBOR.Entry(key: .text("ttl"), value: ttl), CBOR.Entry(key: .text("sig"), value: .bytes(honest.sig)),
                CBOR.Entry(key: .text("signed"), value: .bytes(honest.signed)),
            ])
            return LinkRecord(.frame, payload: wire.encoded).encoded ?? []
        }
        let crossings = rig.links.crossingCount
        #expect(rig.handle(.received(channel, record(ttl: .unsigned(0xFFFF_FFFF)))).isEmpty)
        #expect(rig.handle(.received(channel, record(ttl: CBOR(Int64(-1))))).isEmpty)
        #expect(rig.links.undecodableFrames == 2)
        #expect(rig.links.crossingCount == crossings, "no crossing recorded")
        let events = rig.handle(.received(channel, LinkRig.frameRecord(honest)))
        let envelope = try RelayEnvelope(decoding: honest.signed)
        #expect(events == [.frame(InboundFrame(wire: honest, envelope: envelope, from: LinkRig.low))])
        #expect(rig.links.crossingCount == crossings + 1)
    }
}

/// The ratchet's half: what used to fail the shell's decode now decodes, and the open answers as Android's does.
@Suite struct KotlinxRatchetTests {
    private let me = TestPeer(seed: 1)
    private let alice = TestPeer(seed: 2)
    private var now: Int64 { EngineFixture.start }

    /// `se = 1A FFFFFFFF` reads as −1, so the shell decodes and the frame is carried, as Android carries it; the open
    /// refuses the header as `BAD_HEADER`, which is never evidence toward a reset.
    @Test func aWrappedEpochIsCarriedAndABadHeader() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let prekey = try fixture.ourPrekey()
        let id = frameIdOf("wrapped-se")
        let sealed = try android.dm(MessageContent(body: "hi"), to: me, prekey: prekey, id: id, sentAt: now)
        let shell = try CBOR.decode(sealed.envelope.payload)
        let enc = try #require(shell[key: "enc"])
        let header = try #require(enc[key: "r"]).replacing("se", with: .unsigned(0xFFFF_FFFF))
        let payload = shell.replacing("enc", with: enc.replacing("r", with: header)).encoded
        var envelope = sealed.envelope
        envelope.payload = payload
        #expect(try ChatContent(decoding: payload).enc?.ratchet?.se == -1)
        fixture.deliver(try alice.signed(envelope), from: android)
        #expect(fixture.stores.custody.contains(id), "carried, as Android's canCarry carries it")
        #expect(fixture.engine.dropped[.ratchetBadHeader] == 1)
        #expect(fixture.engine.dropped[.ratchetAeadFail] == nil)
        #expect(fixture.resetsSent(to: alice).isEmpty)
        #expect(fixture.ratchetRecords(of: alice).session == nil)
    }

    /// A v3 plaintext whose label 16 has the wrong type fails to decode once it opens, as kotlinx's `compactCbor` fails it,
    /// so it drops as `cannotOpen` before the commit, and the honest frame sealed at the same index still opens.
    @Test func aWrongTypedVideoLabelLeavesTheIndexUnspent() throws {
        let fixture = try EngineFixture.ratcheting(me)
        // Two copies of one Android phone whose seals draw the same keys, so both seal their first frame at the same index
        // under the same init.
        let pair = try RatchetCrypto.KeyPair(privateKey: fixtureBytes(32, seed: 300))
        let prekeyPair = try RatchetCrypto.KeyPair(privateKey: fixtureBytes(32, seed: 201))
        let signedPrekey = try SignedPrekey.mint(id: 1, signedBy: alice.keys, createdAt: 0) { prekeyPair }
        let first = AndroidPeer(alice, prekey: signedPrekey, engine: RatchetEngine { pair })
        let twin = AndroidPeer(alice, prekey: signedPrekey, engine: RatchetEngine { pair })
        try fixture.pin(first)
        let prekey = try fixture.ourPrekey()
        let bad: [UInt8] = [0xA2, 0x01, 0x62, 0x68, 0x69, 0x10, 0x61, 0x78]
        let honest = try #require(MessageContentV2.encode(MessageContent(body: "hi")))
        let junk = try seal(bad, by: first, id: frameIdOf("v3-junk"), prekey: prekey)
        let good = try seal(honest, by: twin, id: frameIdOf("v3-good"), prekey: prekey)
        #expect(junk.header.n == good.header.n && junk.header.se == good.header.se)
        fixture.deliver(junk.frame, from: alice)
        #expect(fixture.engine.dropped[.cannotOpen] == 1)
        #expect(fixture.stores.messages.message(frameIdOf("v3-junk")) == nil)
        #expect(fixture.ratchetRecords(of: alice).session == nil, "nothing committed, so the index stays unspent")
        fixture.deliver(good.frame, from: alice)
        #expect(fixture.stores.messages.message(frameIdOf("v3-good"))?.body == "hi")
    }

    private func seal(
        _ plaintext: [UInt8], by android: AndroidPeer, id: String, prekey: PeerPrekey
    ) throws -> (frame: TestFrame, header: RatchetHeader) {
        let aad = MessageCrypto.header(id: id, senderId: alice.nodeId.string, sentAt: now, thread: me.nodeId.string)
        let answer = android.sessions.sealDm(to: me.keys.bundle, prekey: prekey, plaintext: plaintext, aad: aad, now: now, v3: true)
        guard case .settled(.sealed(let envelope, rootTag: _)) = answer, let header = envelope.ratchet else {
            Issue.record("the seal: \(answer)")
            throw Unsealed()
        }
        let relay = RelayEnvelope(
            type: .chat,
            id: id,
            senderId: alice.nodeId.string,
            sentAt: now,
            recipientId: me.nodeId.string,
            payload: ChatContent(enc: envelope).encoded
        )
        return (try alice.signed(relay), header)
    }
}

private struct Unsealed: Error {}

extension CBOR {
    /// The value of the last entry under the text key `name`, when this is a map.
    subscript(key name: String) -> Self? {
        guard case .map(let entries) = self else {
            return nil
        }
        return entries.last { $0.key == .text(name) }?.value
    }

    /// This map with the text key `name` given `value`, or one appended when there is none.
    func replacing(_ name: String, with value: Self) -> Self {
        guard case .map(let entries) = self else {
            return self
        }
        guard entries.contains(where: { $0.key == .text(name) }) else {
            return .map(entries + [Entry(key: .text(name), value: value)])
        }
        return .map(entries.map { $0.key == .text(name) ? Entry(key: $0.key, value: value) : $0 })
    }
}
