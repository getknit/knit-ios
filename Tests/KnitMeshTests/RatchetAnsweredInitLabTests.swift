import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A reinstalled responder behind a carrier, in both node-id orders (ADR 2026-10.wcex): `RatchetResealReachTests`' line, the
/// iPhone (0), a carrier (1) and a peer (2), each linked only to its neighbours, with the peer reinstalled minutes after the
/// greeting rather than a day. That suite waits out custody's day because, within it, the carrier serves the reinstalled
/// peer the iPhone's opener, which broke the pair; this one takes the opener as it comes. The peer knows its init for one
/// it answered before it lost the session, so the opener establishes nothing, and since the peer holds no session it sends
/// its flagged reset at once, which the iPhone adopts in either order and answers with its re-seal.
@Suite struct RatchetAnsweredInitLabTests {
    private let one = TestPeer(seed: 1)
    private let two = TestPeer(seed: 2)
    private let carrier = TestPeer(seed: 3)
    private static let minute: Int64 = 60_000
    /// Longer than any relay's jitter, so a flood crosses a hop in one step.
    private static let hop: Int64 = 200

    /// Node `from` sends `text` to node `to`, the floods crossing the carrier, and answers its id.
    @discardableResult
    private func send(_ lab: EngineLab, _ from: Int, _ to: Int, _ text: String) throws -> String {
        let record = try #require(lab[from].engine.sendDirectMessage(text, to: lab[to].me.nodeId))
        lab.advance(Self.hop)
        lab.advance(Self.hop)
        return record.id
    }

    @Test(arguments: [false, true])
    func aReinstalledResponderBehindACarrierResetsOnItsOpenerAndThePairCarriesOn(peerIsTheSmaller: Bool) throws {
        let (smaller, larger) = one.nodeId < two.nodeId ? (one, two) : (two, one)
        let (iphone, peer) = peerIsTheSmaller ? (larger, smaller) : (smaller, larger)
        let keychain = KeptSecretStore(peer.keys.storedForm)
        let lab = EngineLab([
            try EngineFixture.ratcheting(iphone, seed: 11),
            try EngineFixture.ratcheting(carrier, seed: 13),
            try EngineFixture.ratcheting(peer, keychain: keychain, seed: 12),
        ])
        lab.link(0, 1)
        lab.link(1, 2)
        lab.advance(Self.hop)
        let opener = try send(lab, 0, 2, "hello")
        try send(lab, 2, 0, "hi")
        // A short greeting: too few of the iPhone's frames for the reinstalled peer's heuristic, so only the opener resets.
        lab.expectConverged(0, 2, atLeast: 2, "greeted through the carrier")
        #expect(lab[2].engine.prekeyRing?.answeredInits.map(\.peer) == [iphone.nodeId], "the peer kept the init it answered")

        // Minutes later, not a day: the carrier still holds the greeting, the opener among it.
        lab.advance(5 * Self.minute)
        let wall = lab[2].clock.wallMilliseconds()
        lab.replace(2, with: try EngineFixture.ratcheting(peer, keychain: keychain, wall: wall, seed: 22))
        lab.link(1, 2)
        lab.advance(Self.hop)
        lab.advance(Self.hop)
        #expect(lab[2].stores.peers.peer(iphone.nodeId) != nil, "the reinstalled peer pinned the iPhone again, from the carrier")
        #expect(!lab.thread(2, with: 0).contains { $0.hasPrefix(opener) }, "the opener rode the lost session, and is unread")
        let resets = Set(lab[2].resetsSent(to: iphone).map(\.envelope.id))
        #expect(resets.count == 1, "the opener's arrival reset the pair, once")

        let sent = try (1...2).map { try send(lab, 2, 0, "after \($0)") }
        let answered = try (1...2).map { try send(lab, 0, 2, "and back \($0)") }
        lab.advance(Self.minute)
        let theirs = lab.thread(0, with: 2)
        let mine = lab.thread(2, with: 0)
        #expect(sent.allSatisfy { id in theirs.contains { $0.hasPrefix(id) } }, "the iPhone reads the peer's DMs: \(theirs)")
        #expect(sent.allSatisfy { lab[2].stores.messages.message($0)?.delivered == true }, "and the peer every receipt for them")
        #expect(answered.allSatisfy { id in mine.contains { $0.hasPrefix(id) } }, "and the peer the iPhone's: \(mine)")
        #expect(lab.sessionsAgree(0, 2), "\(lab.describe(0, 2))")
        #expect(Set(lab[2].resetsSent(to: iphone).map(\.envelope.id)) == resets, "no second reset from the peer")
        #expect(lab[0].resetsSent(to: peer).isEmpty, "and none from the iPhone")
    }

    /// The blobs review's B1, in both node-id orders: the peer's opener and a second DM both carried its init, and the
    /// second never reached the node before it reinstalled, so the peer holds it unacked. The back-fill brings the opener
    /// first, which resets the pair, then the second DM, which reads as stale under our reset. The peer re-seals it under
    /// the same id once it adopts the reset, and that copy must pass our router at once, not at the second pass eleven
    /// minutes on: every stale frame lets one copy of its id through (ADR 2026-10.wcex).
    @Test(arguments: [0, 1])
    func aSecondDMOnTheOpenersInitIsReSealedAndReadAtOnce(reinstalled index: Int) throws {
        let peers = [one, two]
        let other = 1 - index
        let keychains = peers.map { KeptSecretStore($0.keys.storedForm) }
        let lab = EngineLab([
            try EngineFixture.ratcheting(one, keychain: keychains[0], seed: 11),
            try EngineFixture.ratcheting(two, keychain: keychains[1], seed: 12),
        ])
        lab.link(0, 1)
        // The node's answers wait, so the peer stays its opener's unconfirmed initiator for the second DM.
        lab.hold(from: index, to: other)
        let opener = try send(lab, other, index, "the opener")
        lab.hold(from: other, to: index)
        let second = try send(lab, other, index, "on the same init")
        let chat = try #require(lab.chats(from: other, to: index, id: second).first)
        let initial = try ChatContent(decoding: chat.envelope.payload).enc?.ratchet?.initial
        #expect(initial != nil, "the peer, still unanswered, sealed it on its opener's init")
        lab.release(from: index, to: other)
        lab.unlink(0, 1)
        #expect(!lab.thread(index, with: other).contains { $0.hasPrefix(second) }, "the second never reached the node")

        lab.advance(Self.minute)
        let wall = lab[index].clock.wallMilliseconds()
        lab.replace(index, with: try EngineFixture.ratcheting(peers[index], keychain: keychains[index], wall: wall, seed: 21))
        lab.link(0, 1, holding: [(from: other, to: index)])
        lab.release(from: other, to: index) { items in
            items.filter { $0.id == opener } + items.filter { $0.id != opener }
        }
        lab.advance(Self.minute)
        #expect(Set(lab[index].resetsSent(to: peers[other]).map(\.envelope.id)).count == 1, "the opener reset the pair, once")
        #expect(lab.thread(index, with: other).contains { $0.hasPrefix(second) }, "the second's re-seal read within the minute")
        #expect(lab[other].stores.messages.message(second)?.delivered == true, "and its receipt read at the peer")
        #expect(lab.sessionsAgree(0, 1), "\(lab.describe(0, 1))")
    }

    /// The crypto review's C4: a keep the Keychain refused, after the open's unit committed, is made good at the next
    /// start, in one write, from the anchor the session row holds; a start with nothing missing writes nothing.
    @Test func aStartKeepsTheAnchorAKeychainRefusalLeftUnkept() throws {
        let keychain = KeptSecretStore(two.keys.storedForm)
        let lab = EngineLab([try EngineFixture.ratcheting(one, seed: 11), try EngineFixture.ratcheting(two, keychain: keychain, seed: 12)])
        lab.link(0, 1)
        keychain.refusesWrites = true
        try send(lab, 0, 1, "the opener")
        try send(lab, 1, 0, "the answer")
        keychain.refusesWrites = false
        #expect(lab[1].engine.prekeyRing?.answeredInits.isEmpty == true, "the keep was refused")
        let anchor = try #require(lab[1].ratchetRecords(of: one).session?.peerInitEphPub)

        let stores = lab[1].stores
        let wall = lab[1].clock.wallMilliseconds()
        lab.replace(1, with: try EngineFixture.ratcheting(two, stores: stores, keychain: keychain, wall: wall, seed: 21))
        #expect(lab[1].engine.prekeyRing?.answeredInits.map(\.eph) == [anchor], "the restart kept the session's anchor")
        #expect(try PrekeyRing.load(for: two.keys, from: keychain).answeredInits.map(\.eph) == [anchor])

        let item = keychain.contents
        lab.replace(1, with: try EngineFixture.ratcheting(two, stores: stores, keychain: keychain, wall: wall + 1, seed: 22))
        #expect(keychain.contents == item, "nothing missing, nothing written")
    }

    /// With the switch off, nothing changes on air and nothing is written to the identity's item: an engine keeping a ring
    /// that holds a prekey, as one left by a run with the switch on, takes a ratchet Android's opener against that prekey
    /// exactly as an engine with no ring does, frame for frame, and keeps no answered init.
    @Test func withTheSwitchOffAnOpenerPutsTodaysBytesOnAirAndKeepsNothing() throws {
        let me = one
        let keychain = KeptSecretStore(me.keys.storedForm)
        var ring = try PrekeyRing.load(for: me.keys, from: keychain)
        let prekey = try ring.rotate(now: EngineFixture.start)
        let item = keychain.contents
        let switchedOff = EngineFixture(me, prekeys: ring)
        let today = EngineFixture(me)
        let android = try AndroidPeer(two)
        let pinned = try #require(PeerPrekey(verifying: prekey.info, signedBy: me.keys.bundle))
        let opener = try android.dm("hello", to: me, prekey: pinned, id: fixtureFrameId(7), sentAt: EngineFixture.start)
        for fixture in [switchedOff, today] {
            fixture.deliver(try android.profile(publishedAt: EngineFixture.start), from: two)
            fixture.transport.clear()
            fixture.deliver(opener, from: android)
            fixture.engine.advance()
        }

        let ours = switchedOff.transport.written
        let theirs = today.transport.written
        #expect(ours.map(\.wire) == theirs.map(\.wire) && ours.map(\.to) == theirs.map(\.to), "the same bytes on air")
        #expect(switchedOff.engine.dropped == today.engine.dropped && switchedOff.engine.dropped[.cannotOpen] == 1, "dropped unread")
        #expect(keychain.contents == item, "nothing written to the identity's item")
        #expect(switchedOff.engine.prekeyRing?.answeredInits.isEmpty == true)
        #expect(switchedOff.ratchetRecords(of: two) == RatchetPeerRecords(session: nil, localEpochs: [], recvEpochs: [], skippedKeys: []))
    }
}
