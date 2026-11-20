import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// P4a's two-engine lab over ``FakeSpool`` (ADR 2026-11.adrq): the DM cases of knit-next's `InternetPlaneLabTest`
/// (`mesh/lab/InternetPlaneLabTest.kt` at `0832b8462`) through ``SpoolPlane`` and ``MeshEngine/receiveFromSpool(_:relay:)``.
/// Its group, commons, attachment and Knit Anywhere cases are not this port's (spool.md, "What this port speaks").
@Suite struct SpoolEngineLabTests {
    static let alice = TestPeer(seed: 1)
    static let bob = TestPeer(seed: 2)
    static let carol = TestPeer(seed: 3)
    static let minute: Int64 = 60_000

    /// Alice (0) and Bob (1), ratcheting, linked by radio until a DM each way and its receipts confirmed the session, then
    /// apart; Carol (2), when asked for, pinned by Bob alone and never linked. Every node carries the spool's relay.
    static func greeted(
        withCarol: Bool = false, spool: FakeSpool? = nil, bobStores: MeshStores = .inMemory(), crossings: Bool = false
    ) throws -> SpoolLab {
        var fixtures = [try EngineFixture.ratcheting(alice, seed: 11), try EngineFixture.ratcheting(bob, stores: bobStores, seed: 12)]
        if withCarol {
            fixtures.append(try EngineFixture.ratcheting(carol, seed: 13))
        }
        let lab = SpoolLab(fixtures, spool: spool, crossings: crossings)
        lab.radio.link(0, 1)
        try send(lab, 0, 1, "hello")
        try send(lab, 1, 0, "hi")
        lab.advance(minute)
        try send(lab, 0, 1, "again")
        try send(lab, 1, 0, "and again")
        lab.advance(minute)
        #expect(lab.radio.sessionsAgree(0, 1) && lab.radio.bothHoldSessions(0, 1), "the session confirmed over radio")
        lab.radio.unlink(0, 1)
        return lab
    }

    /// Node `from` sends `text` to node `to` and answers its id.
    @discardableResult
    static func send(_ lab: SpoolLab, _ from: Int, _ to: Int, _ text: String) throws -> String {
        let record = try #require(lab[from].engine.sendDirectMessage(text, to: lab[to].me.nodeId))
        lab.pump()
        return record.id
    }

    /// Connects every node in `nodes` and runs the heal until it settles.
    static func online(_ lab: SpoolLab, _ nodes: [Int]) {
        for node in nodes {
            lab.connect(node)
        }
        lab.run(6)
    }

    @Test func textGoesBothWaysOverTheRelayAndTheScopesConverge() throws {
        let lab = try Self.greeted()
        Self.online(lab, [0, 1])
        #expect(lab.scopes(0).count == 1 && lab.scopes(1).count == 1, "one live scope each")
        #expect(lab.scopes(0).first?.id == lab.scopes(1).first?.id, "both derive the one scope")
        let toBob = try Self.send(lab, 0, 1, "over the relay")
        let toAlice = try Self.send(lab, 1, 0, "and back")
        lab.run(12)
        #expect(lab[1].stores.messages.message(toBob)?.body == "over the relay", "bob has alice's text")
        #expect(lab[0].stores.messages.message(toAlice)?.body == "and back", "alice has bob's text")
        #expect(lab.pairIds(0, with: 1) == lab.pairIds(1, with: 0), "both custodies hold the pair's same live ids")
        let scope = try #require(lab.scopes(0).first)
        for node in [0, 1] {
            #expect(lab.heal(node)?.localFold(scope.id) == lab.spoolDigest(scope.id), "node \(node)'s fold is the spool's digest")
        }
        lab.forgetSent(0)
        lab.forgetSent(1)
        lab.advance(ScopeHeal.tickMilliseconds)
        #expect(lab.lists(0) == 0 && lab.lists(1) == 0, "a converged scope lists nothing at the next tick")
        let blobs = lab.opened(scope)
        #expect(!blobs.isEmpty)
        for blob in blobs {
            let signer = blob.envelope.senderId == Self.alice.nodeId.string ? Self.alice : Self.bob
            #expect(signer.keys.bundle.isValidSignature(blob.sig, for: blob.envelope.encoded), "a signed frame")
            #expect(blob.envelope.type != .receipt, "no cleartext receipt rides the scope")
        }
    }

    @Test func aDoubleTickComesBackThroughTheScope() throws {
        let lab = try Self.greeted()
        Self.online(lab, [0, 1])
        let toBob = try Self.send(lab, 0, 1, "tick me")
        lab.run(12)
        #expect(lab[0].stores.messages.message(toBob)?.delivered == true, "alice's row is marked delivered")
        #expect(lab.pairIds(0, with: 1).contains(toBob) && lab.pairIds(1, with: 0).contains(toBob), "alice's DM in both custodies")
        let receipts = lab.pairIds(1, with: 0).subtracting(lab.pairIds(0, with: 1))
        #expect(receipts.isEmpty, "the sealed receipt is in both custodies")
        let bobsOwn = lab[1].stores.custody.liveFrames(now: lab[1].clock.wallMilliseconds()).filter { frame in
            frame.envelope.senderId == Self.bob.nodeId.string && frame.envelope.type == .chat
        }
        #expect(!bobsOwn.isEmpty, "bob's sealed receipt is carried")
    }

    @Test func aRotatedPrekeyReachesAPeerOnlyTheRelayReaches() throws {
        let lab = try Self.greeted()
        Self.online(lab, [0, 1])
        let first = try #require(lab[1].stores.peers.peer(Self.alice.nodeId)?.prekey?.id)
        let rotating = lab[0].engine
        var ring = try #require(rotating.prekeyRing)
        _ = try ring.rotate(now: lab[0].clock.wallMilliseconds())
        rotating.prekeyRing = ring
        rotating.updateProfile(name: "Rotated", status: "rotated", openToChat: true)
        rotating.syncPrekey(atStart: false)
        lab.pump()
        lab.run(6)
        let pinned = try #require(lab[1].stores.peers.peer(Self.alice.nodeId)?.prekey?.id)
        #expect(pinned > first, "bob pinned alice's rotated prekey from the relay alone")
    }

    /// Radio and spool both carry one DM, in `spoolFirst`'s order: Bob keeps one row and one event, and Carol, behind Bob
    /// on the radio, gets exactly one copy.
    private func bothCarry(spoolFirst: Bool) throws {
        // The links skip what crossed them, as `LinkManager` does: a round of Bob's answer to Carol, cut fresh, may serve the
        // DM before the router's relay goes, and the link then carries one of the two (the `custody-carry-policy` contract,
        // §2).
        let lab = try Self.greeted(withCarol: true, crossings: true)
        Self.online(lab, [0])
        lab.radio.link(1, 2)
        lab.radio.link(0, 1, holding: [(from: 0, to: 1)])
        if !spoolFirst {
            lab.radio.release(from: 0, to: 1)
        }
        _ = lab[1].engine.drainEvents()
        let id = try Self.send(lab, 0, 1, "both ways")
        lab.run(3)
        if spoolFirst {
            lab.connect(1)
            lab.run(6)
            #expect(lab[1].stores.messages.message(id) != nil, "the spool's copy came first")
            lab.radio.release(from: 0, to: 1)
        } else {
            #expect(lab[1].stores.messages.message(id) != nil, "the radio's copy came first")
            lab.connect(1)
            lab.run(6)
        }
        lab.advance(1000)
        let received = lab[1].engine.drainEvents().count { event in
            if case .received(let record, _) = event { ExactKey(record.id) == ExactKey(id) } else { false }
        }
        #expect(received == 1, "one event")
        #expect(lab.radio.thread(1, with: 0).count { $0.hasPrefix(id) } == 1, "one row")
        let toCarol = lab.radio.delivered(of: id, from: 1, to: 2, since: 0)
        #expect(toCarol == 1, "carol heard exactly one copy")
        #expect(lab.heal(1)?.counts.quarantined == 0 && lab.heal(1)?.counts.accounted == 0, "delivered and kept")
    }

    @Test func aFrameTheRadioBringsFirstIsDeliveredOnceAndRelayedOnce() throws {
        try bothCarry(spoolFirst: false)
    }

    @Test func aFrameTheRelayDeliversFirstIsStillRelayedToTheCarrierBehindUs() throws {
        try bothCarry(spoolFirst: true)
    }
}
