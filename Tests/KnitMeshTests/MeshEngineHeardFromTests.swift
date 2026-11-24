import KnitCrypto
import KnitStore
import KnitSync
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// When each peer was last heard, on one engine (knit-next ADR 2026-10.k8ge): which verified frames are noted, and the
/// bank on the 60 s timer and at stop. The fixture's wall and monotonic clocks are far apart, so a stamp taken from the
/// wrong one shows.
@Suite struct MeshEngineHeardFromTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private static let hour: Int64 = 3_600_000
    private static let bank: Int64 = 60_000

    /// Alice's engine with Bob pinned, then seven hours on, so a stamp from now is past the gate from the pin's.
    private func pinnedBob(stores: MeshStores = .inMemory()) throws -> EngineFixture {
        let fixture = EngineFixture(alice, stores: stores)
        try fixture.pin(bob)
        fixture.advance(7 * Self.hour)
        _ = fixture.engine.drainEvents()
        return fixture
    }

    private func lastSeen(_ fixture: EngineFixture, _ peer: TestPeer) -> Int64? {
        fixture.stores.peers.peer(peer.nodeId)?.lastSeenAt
    }

    private func heard(_ fixture: EngineFixture) -> [NodeId: Int64] {
        fixture.engine.heardFrom.heard
    }

    private func post(from peer: TestPeer, _ label: String, sentAt: Int64) throws -> TestFrame {
        try peer.roomPost(label, id: frameIdOf(label), sentAt: sentAt)
    }

    @Test func aPinIsNeverBornQuietAndItsProfileIsNotBuffered() throws {
        let fixture = EngineFixture(alice)
        let publishedAt = fixture.clock.wallMilliseconds() - 5000
        fixture.deliver(try bob.profile(publishedAt: publishedAt), from: bob)
        #expect(lastSeen(fixture, bob) == publishedAt, "the profile that pins stamps its new row")
        #expect(heard(fixture).isEmpty, "no row when it verified: the buffer took nothing")
    }

    @Test func theNewestStampLandsOnTheTimerWithOneEvent() throws {
        let fixture = try pinnedBob()
        let now = fixture.clock.wallMilliseconds()
        let pinnedAt = try #require(lastSeen(fixture, bob))
        fixture.deliver(try post(from: bob, "post-1", sentAt: now - 1000), from: bob)
        fixture.deliver(try post(from: bob, "post-2", sentAt: now - 5000), from: bob)
        #expect(heard(fixture) == [bob.nodeId: now - 1000])
        #expect(lastSeen(fixture, bob) == pinnedAt, "nothing is written before the bank")
        let monotonic = fixture.clock.monotonicMilliseconds()
        let deadline = try #require(fixture.engine.nextDeadline)
        #expect(deadline <= monotonic + Self.bank, "the timer names the bank")
        #expect(fixture.engine.timers?.seenBank ?? 0 > monotonic, "on the monotonic clock")
        fixture.advance(Self.bank)
        #expect(lastSeen(fixture, bob) == now - 1000)
        #expect(fixture.engine.drainEvents().filter { if case .peersHeard = $0 { true } else { false } } == [.peersHeard([bob.nodeId])])
        #expect(heard(fixture).isEmpty)
    }

    @Test func aStampInsideTheGateCostsNoWriteAndNoEvent() throws {
        let fixture = try pinnedBob()
        fixture.deliver(try post(from: bob, "post-1", sentAt: fixture.clock.wallMilliseconds()), from: bob)
        fixture.advance(Self.bank)
        let banked = lastSeen(fixture, bob)
        _ = fixture.engine.drainEvents()
        fixture.advance(Self.hour)
        fixture.deliver(try post(from: bob, "post-2", sentAt: fixture.clock.wallMilliseconds()), from: bob)
        fixture.advance(Self.bank)
        #expect(lastSeen(fixture, bob) == banked)
        #expect(!fixture.engine.drainEvents().contains { if case .peersHeard = $0 { true } else { false } })
    }

    @Test func oneEventCarriesExactlyTheRowsThatChanged() throws {
        let fixture = try pinnedBob()
        try fixture.pin(carol)
        // Primes the bank's memory with both rows as they stand.
        fixture.deliver(try post(from: bob, "post-0", sentAt: 0), from: bob)
        fixture.advance(Self.bank)
        _ = fixture.engine.drainEvents()
        fixture.advance(7 * Self.hour)
        let now = fixture.clock.wallMilliseconds()
        // Carol's new profile raises her row directly; her post is then due by the bank's memory and refused by the row.
        fixture.deliver(try carol.profile(publishedAt: now), from: carol)
        fixture.deliver(try post(from: carol, "carol-1", sentAt: now), from: carol)
        fixture.deliver(try post(from: bob, "bob-1", sentAt: now), from: bob)
        _ = fixture.engine.drainEvents()
        fixture.advance(Self.bank)
        let events = fixture.engine.drainEvents().filter { if case .peersHeard = $0 { true } else { false } }
        #expect(events == [.peersHeard([bob.nodeId])])
        #expect(lastSeen(fixture, carol) == now && lastSeen(fixture, bob) == now)
    }

    @Test func nothingIsNotedPastTheTrustBoundary() throws {
        let fixture = try pinnedBob()
        let pinnedAt = lastSeen(fixture, bob)
        let now = fixture.clock.wallMilliseconds()
        // A pinned sender's chat whose signature does not verify.
        var forged = try post(from: bob, "forged", sentAt: now)
        forged.wire.sig[0] ^= 1
        fixture.deliver(forged, from: bob)
        // A profile under Bob's id carrying, and signed by, Carol's key: it derives to another node.
        let content = ProfileContent(name: "Bob", status: "", pubKey: carol.keys.bundle.encoded, version: now)
        let envelope = RelayEnvelope(
            type: .profile, id: "profile-\(bob.nodeId)-\(now)", senderId: bob.nodeId.string, sentAt: now, payload: content.encoded)
        fixture.deliver(try carol.signed(envelope), from: carol)
        // A signed frame from a sender with no pinned key: parked, not heard.
        let dave = TestPeer(seed: 4)
        fixture.deliver(try post(from: dave, "dave-1", sentAt: now), from: dave)
        #expect(fixture.engine.dropped[.badSignature] == 1 && fixture.engine.dropped[.keyMismatch] == 1)
        #expect(fixture.engine.footprint.parked == 1)
        #expect(heard(fixture).isEmpty)
        fixture.advance(Self.bank)
        #expect(lastSeen(fixture, bob) == pinnedAt)
        #expect(fixture.stores.peers.peer(dave.nodeId) == nil)
    }

    @Test func aStampAtEitherEndNeverTrapsAndNeverLowersTheRow() throws {
        let fixture = try pinnedBob()
        let pinnedAt = try #require(lastSeen(fixture, bob))
        fixture.deliver(try post(from: bob, "ancient", sentAt: .min), from: bob)
        #expect(heard(fixture) == [bob.nodeId: 0], "floored at 0")
        fixture.advance(Self.bank)
        #expect(lastSeen(fixture, bob) == pinnedAt, "older than the row: never lowers it")
        let now = fixture.clock.wallMilliseconds()
        fixture.deliver(try post(from: bob, "future", sentAt: .max), from: bob)
        #expect(heard(fixture) == [bob.nodeId: now], "capped at the wall clock, not the monotonic one")
        fixture.advance(Self.bank)
        #expect(lastSeen(fixture, bob) == now)
        #expect(try #require(lastSeen(fixture, bob)) >= 0)
    }

    @Test func aFloodOfFreshIdentitiesNeverCrowdsOutAPinnedPeer() throws {
        let fixture = try pinnedBob()
        let now = fixture.clock.wallMilliseconds()
        for seed in 0..<1100 {
            fixture.deliver(try TestPeer(seed: 10_000 + seed).profile(publishedAt: now), from: carol)
        }
        fixture.deliver(try post(from: bob, "honest", sentAt: now), from: bob)
        #expect(heard(fixture) == [bob.nodeId: now], "a profile that pins is not buffered; the honest stamp is")
        fixture.advance(Self.bank)
        #expect(lastSeen(fixture, bob) == now)
    }

    @Test func ourOwnFrameEchoedBackIsNoPeerHeard() throws {
        let fixture = try pinnedBob()
        fixture.deliver(try post(from: alice, "mine", sentAt: fixture.clock.wallMilliseconds()), from: bob)
        fixture.deliver(try alice.profile(publishedAt: fixture.clock.wallMilliseconds()), from: bob)
        #expect(heard(fixture).isEmpty)
    }

    @Test func aSpoolPulledFrameStampsItsSenderAndOurOwnDoesNot() throws {
        // Bob's engine with Alice pinned, as the spool's door tests have it.
        let fixture = EngineFixture(bob)
        try fixture.pin(alice)
        fixture.advance(7 * Self.hour)
        let now = fixture.clock.wallMilliseconds()
        let relay = SpoolRelayHandle(number: 1)
        let own = ScopeFixture.dm(1, from: bob, to: alice, sentAt: now)
        let ownCandidate = try SpoolCandidates.candidate(own, for: bob, with: alice, now: now)
        _ = fixture.engine.receiveFromSpool(ownCandidate, relay: relay)
        #expect(heard(fixture).isEmpty, "our own DM served back verifies against our key and is not heard")
        let theirs = ScopeFixture.dm(2, from: alice, to: bob, sentAt: now - 2000)
        let candidate = try SpoolCandidates.candidate(theirs, for: bob, with: alice, now: now)
        _ = fixture.engine.receiveFromSpool(candidate, relay: relay)
        #expect(heard(fixture) == [alice.nodeId: now - 2000])
        fixture.advance(Self.bank)
        #expect(lastSeen(fixture, alice) == now - 2000)
    }

    @Test func aFailedWriteKeepsTheStampsForTheNextBank() throws {
        let base = MeshStores.inMemory()
        let peers = FailingPeerMarks(base.peers)
        let fixture = try pinnedBob(stores: base.replacing(peers: peers))
        let now = fixture.clock.wallMilliseconds()
        fixture.deliver(try post(from: bob, "post-1", sentAt: now), from: bob)
        let pinnedAt = lastSeen(fixture, bob)
        peers.failsMarks = true
        fixture.advance(Self.bank)
        #expect(lastSeen(fixture, bob) == pinnedAt)
        #expect(heard(fixture) == [bob.nodeId: now], "back in the buffer")
        #expect(!fixture.engine.drainEvents().contains { if case .peersHeard = $0 { true } else { false } })
        peers.failsMarks = false
        fixture.advance(Self.bank)
        #expect(lastSeen(fixture, bob) == now)
        #expect(fixture.engine.drainEvents().contains(.peersHeard([bob.nodeId])))
    }

    @Test func theMeshBanksAtStop() async throws {
        let fixture = EngineFixture(alice, started: false)
        fixture.stores.peers.upsert(
            PeerRecord(nodeId: bob.nodeId, name: "Bob", status: "", publicKey: bob.keys.bundle.encoded, updatedAt: 1))
        let mesh = Mesh(
            identity: alice.keys,
            deviceTag: nil,
            stores: fixture.stores,
            radio: FakeRadio(advertisesServiceData: false),
            clock: fixture.clock,
            random: SeededGenerator(seed: 7)
        )
        await mesh.start()
        let now = fixture.clock.wallMilliseconds()
        let frame = try post(from: bob, "post-1", sentAt: now)
        await mesh.receiveForTest(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: bob.nodeId))
        #expect(lastSeen(fixture, bob) == 0, "no timer has fired")
        await mesh.stop()
        #expect(lastSeen(fixture, bob) == now)
    }
}

extension Mesh {
    /// Hands the engine one frame off a link, as the link manager would.
    func receiveForTest(_ frame: InboundFrame) {
        engine.receive(frame)
    }
}

/// A peer store whose `markSeen` fails when told to, answering `nil` as SQL's fallback would, and forwards the rest.
final class FailingPeerMarks: PeerStore {
    let held: any PeerStore
    private let failing = Lock(false)

    init(_ held: any PeerStore) {
        self.held = held
    }

    var failsMarks: Bool {
        get { failing.withLock { $0 } }
        set { failing.withLock { $0 = newValue } }
    }

    func markSeen(_ stamps: [NodeId: Int64], gate: Int64) -> Set<NodeId>? {
        failsMarks ? nil : held.markSeen(stamps, gate: gate)
    }

    func peer(_ nodeId: NodeId) -> PeerRecord? { held.peer(nodeId) }
    func upsert(_ peer: PeerRecord) { held.upsert(peer) }
    func verifiedNodeIds() -> Set<NodeId> { held.verifiedNodeIds() }
    func allPeers() -> [PeerRecord] { held.allPeers() }
    func recordProfileFrame(_ frame: WireEnvelope, of nodeId: NodeId, sentAt: Int64) {
        held.recordProfileFrame(frame, of: nodeId, sentAt: sentAt)
    }
    func profileFrame(of nodeId: NodeId) -> WireEnvelope? { held.profileFrame(of: nodeId) }
    func deleteProfileFrames(longerThan maxSignedBytes: Int) -> Int { held.deleteProfileFrames(longerThan: maxSignedBytes) }
    func lastSeenStamps() -> [NodeId: Int64] { held.lastSeenStamps() }
}
