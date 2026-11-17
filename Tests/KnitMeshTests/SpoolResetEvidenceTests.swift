import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Spool frames feed no reset evidence (ADR 2026-11.adrq, P4a): a spool re-serves a scope's tail for 48 h, to every cold
/// launch, so its failures would buy a reset the radios never asked for. The same frames off a link are the control.
@Suite struct SpoolResetEvidenceTests {
    private let me = TestPeer(seed: 2)
    private let alice = TestPeer(seed: 1)
    private static let hour: Int64 = 3_600_000
    private let relay = SpoolRelayHandle(number: 1)

    /// Three signed frames from `android` the session we hold cannot read, AEAD-failing.
    private func unreadable(_ fixture: EngineFixture, from android: AndroidPeer, tag: String, sentAt: Int64) throws -> [TestFrame] {
        let prekey = try fixture.ourPrekey()
        let steady: (inout EncEnvelope) -> Void = { $0.ratchet = $0.ratchet?.steady }
        return try (0..<3).map { index in
            let id = frameIdOf("\(tag)-\(index)")
            return try android.dm(MessageContent(body: "unreadable"), to: me, prekey: prekey, id: id, sentAt: sentAt, edit: steady)
        }
    }

    @Test func threeFailingFramesFromASpoolSealNoResetWhereARadioLinksThreeDo() throws {
        let fixture = try EngineFixture.ratcheting(me)
        let android = try AndroidPeer(alice)
        try fixture.pin(android)
        let now = fixture.clock.wallMilliseconds()
        for frame in try unreadable(fixture, from: android, tag: "spool", sentAt: now) {
            let candidate = try SpoolCandidates.candidate(frame, for: me, with: alice, now: now)
            #expect(fixture.engine.receiveFromSpool(candidate, relay: relay) == .delivered(keptLive: true))
        }
        #expect(fixture.resetsSent(to: alice).isEmpty, "no reset from a spool's failures")
        #expect(fixture.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 0, "nothing counted")
        // The control: the same failures off a link.
        try fixture.deliverUnreadable(from: android, tag: "radio", sentAt: now)
        #expect(fixture.resetsSent(to: alice).count == 1, "a radio link's three buy a reset")
    }

    @Test func aColdLaunchAfterOurResetRePullsTheOldErasControlFramesAndSealsNoReset() throws {
        let stores = MeshStores.inMemory()
        let keychain = KeptSecretStore(me.keys.storedForm)
        let first = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain)
        let android = try AndroidPeer(alice)
        try first.pin(android)
        let start = first.clock.wallMilliseconds()
        try first.deliverUnreadable(from: android, tag: "before", sentAt: start)
        #expect(first.resetsSent(to: alice).count == 1, "our reset")
        let tail = try unreadable(first, from: android, tag: "tail", sentAt: start + 1)
        // A cold launch two days on: a fresh engine's memory over the same stores, the spool serving the old era's tail.
        let wall = start + 50 * Self.hour
        let second = try EngineFixture.ratcheting(me, stores: stores, keychain: keychain, wall: wall)
        for frame in tail {
            let candidate = try SpoolCandidates.candidate(frame, for: me, with: alice, now: wall)
            _ = second.engine.receiveFromSpool(candidate, relay: relay)
        }
        #expect(second.resetsSent(to: alice).isEmpty, "no reset from the re-pulled tail")
        #expect(second.engine.ratchet.floors(for: alice.nodeId).undecryptableIds == 0)
    }

    @Test func aSpoolRouteKeepsItsSourceThroughTheReplayAndTheRules() {
        let spool = RatchetInbound.Route(source: .spool, signed: true, origin: .firstVerdict)
        let link = RatchetInbound.Route(hop: alice.nodeId, signed: true, origin: .firstVerdict)
        let custody = RatchetInbound.Route(hop: nil, signed: true, origin: .startReplay)
        #expect(spool.hop == nil && spool.isSpool && link.hop == alice.nodeId && !link.isSpool && custody.source == .custody)
        for failure in RatchetResetPolicy.triggeringFailures {
            #expect(!RatchetInbound.countsTowardReset(failure, route: spool))
            #expect(RatchetInbound.countsTowardReset(failure, route: link))
        }
        var replay = RatchetReplay()
        let envelope = RelayEnvelope(type: .chat, id: frameIdOf("kept"), senderId: alice.nodeId.string, sentAt: 0, payload: [])
        replay.keep(envelope, route: spool)
        #expect(replay.take().map(\.route) == [spool], "the source survives the replay")
    }

    /// `resolvedStale` skips its reset for a spool's frame: a reinstalled peer, its session lost and the init it answered
    /// kept in its keychain (``RatchetAnsweredInitLabTests``' setup, ADR 2026-10.wcex), meets the opener again. Off a link
    /// the opener seals a reset at once; from a spool it seals none.
    @Test func aStaleFrameFromASpoolSealsNoResetWhereALinksCopyDoes() throws {
        let iphone = alice
        let peer = me
        let keychain = KeptSecretStore(peer.keys.storedForm)
        let lab = EngineLab([
            try EngineFixture.ratcheting(iphone, seed: 11), try EngineFixture.ratcheting(peer, keychain: keychain, seed: 12),
        ])
        lab.link(0, 1)
        let opener = try #require(lab[0].engine.sendDirectMessage("hello", to: peer.nodeId)).id
        lab.carry()
        _ = try #require(lab[1].engine.sendDirectMessage("hi", to: iphone.nodeId))
        lab.carry()
        let written = try #require(lab.chats(from: 0, to: 1, id: opener).first)
        let frame = TestFrame(wire: written.wire, envelope: written.envelope)
        let iphoneProfile = try #require(
            lab[0].stores.custody.liveFrames(now: lab[0].clock.wallMilliseconds()).first { carried in
                carried.envelope.type == .profile && carried.envelope.senderId == iphone.nodeId.string
            })
        let profile = TestFrame(
            wire: WireEnvelope(sig: iphoneProfile.sig, signed: iphoneProfile.signed), envelope: iphoneProfile.envelope)
        let wall = lab[1].clock.wallMilliseconds() + 5 * 60_000
        func reinstalled(seed: UInt64) throws -> EngineFixture {
            let fixture = try EngineFixture.ratcheting(peer, keychain: keychain, wall: wall, seed: seed)
            fixture.deliver(profile, from: iphone)
            return fixture
        }
        let fromSpool = try reinstalled(seed: 21)
        let candidate = try SpoolCandidates.candidate(frame, for: peer, with: iphone, now: wall)
        _ = fromSpool.engine.receiveFromSpool(candidate, relay: relay)
        #expect(fromSpool.resetsSent(to: iphone).isEmpty, "no reset from a spool's stale frame")
        let fromLink = try reinstalled(seed: 22)
        fromLink.deliver(frame, from: iphone)
        #expect(fromLink.resetsSent(to: iphone).count == 1, "the link's copy seals one at once")
    }
}
