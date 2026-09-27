import KnitCrypto
import KnitMesh
import KnitStore
import KnitWire
import Testing

/// A carrier hands a newcomer the backlog of someone the newcomer has never met, after the carrier's custody has
/// lost that author's profile and its process has restarted (knit-next's `StrangerBacklogLabTest`, ADR
/// 2026-09.g64k). Before the carrier kept the signed frame each pin came from, no copy of the author's key was
/// left anywhere: the newcomer refused every post, its key request found nobody who could answer, and the backlog
/// stayed unreadable to it for its whole TTL. The Pixel 3 held 81 such frames in the A4 run.
@Suite struct MeshEngineBacklogTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    /// Alice's backlog: one more than her profile leaves room for in the quota below.
    private static let posts = 12
    /// Tight enough that Alice's posts evict her profile, the oldest frame of hers, as 200 does in the field. Every
    /// node runs the same quota, so the custody sets can still converge.
    private static let limits = CustodyLimits(maxPerSender: posts)

    /// Bob pins Alice and carries her posts until his quota evicts her profile, then restarts on the same stores:
    /// no copy of her key is in his custody or his memory, only the proof his pin keeps.
    private func restartedCarrier() throws -> EngineFixture {
        let stores = MeshStores.inMemory(custodyLimits: Self.limits)
        let before = EngineFixture(bob, stores: stores)
        try before.pin(alice)
        for n in 0..<Self.posts {
            before.deliver(try alice.roomPost("Post \(n)", id: "alice-\(n)", sentAt: EngineFixture.start + 1 + Int64(n)), from: alice)
        }
        let aliceProfiles = stores.custody.liveFrames(now: EngineFixture.start).filter { frame in
            frame.envelope.type == .profile && frame.envelope.senderId == alice.nodeId.string
        }
        #expect(aliceProfiles.isEmpty, "the quota evicted Alice's profile")
        return EngineFixture(bob, stores: stores)
    }

    /// Carries what each engine writes to the other until both fall quiet, as a live link between them would.
    /// `lost` is asked about each frame and drops the ones it answers true for. Answers what crossed from the carrier.
    @discardableResult
    private func exchange(_ carrier: EngineFixture, _ newcomer: EngineFixture, lost: (Written) -> Bool = { _ in false }) -> [Written] {
        var crossed: [Written] = []
        var quiet = false
        while !quiet {
            quiet = true
            for (from, to) in [(carrier, newcomer), (newcomer, carrier)] {
                let written = from.transport.written.filter { $0.to == nil || $0.to == to.me.nodeId }
                let digests = from.transport.digests.filter { $0.to == to.me.nodeId }
                from.transport.clear()
                for frame in written where !lost(frame) {
                    quiet = false
                    if from.me == carrier.me {
                        crossed.append(frame)
                    }
                    to.engine.receive(InboundFrame(wire: frame.wire, envelope: frame.envelope, from: from.me.nodeId))
                }
                for digest in digests {
                    quiet = false
                    to.engine.receiveDigest(digest.ids, from: from.me.nodeId)
                }
            }
        }
        return crossed
    }

    private func linked(_ carrier: EngineFixture, _ newcomer: EngineFixture) {
        carrier.link(newcomer.me)
        newcomer.link(carrier.me)
    }

    private func alicesPosts(held fixture: EngineFixture) -> Set<String> {
        Set(fixture.stores.messages.messages(in: Conversations.nearby).filter { $0.senderId == alice.nodeId }.map(\.id))
    }

    private func expectShortNothing(_ newcomer: EngineFixture, of carrier: EngineFixture) {
        let carried = Set(carrier.stores.custody.liveIds(now: EngineFixture.start))
        let short = carried.subtracting(newcomer.stores.custody.liveIds(now: EngineFixture.start))
        #expect(short.isEmpty, "Carol is short \(short.sorted()) of Bob's custody")
    }

    @Test func aRestartedCarrierServesTheAuthorsKeyAheadOfTheirBacklog() throws {
        let carrier = try restartedCarrier()
        let newcomer = EngineFixture(carol, stores: .inMemory(custodyLimits: Self.limits))
        linked(carrier, newcomer)
        let crossed = exchange(carrier, newcomer)

        let ofAlice = crossed.filter { $0.envelope.senderId == alice.nodeId.string }
        #expect(ofAlice.first?.envelope.type == .profile, "her key first")
        #expect(ofAlice.first?.wire.relay == false, "point to point, never flooded")
        #expect(alicesPosts(held: newcomer).count == Self.posts)
        #expect(newcomer.engine.dropped[.noSenderKey] == nil, "Carol refused nothing for want of a key")
        #expect(newcomer.transport.written(.keyRequest).isEmpty, "and asked nobody for one")
        expectShortNothing(newcomer, of: carrier)
    }

    @Test func aRestartedCarrierAnswersTheKeyRequestForABacklogItServed() throws {
        let carrier = try restartedCarrier()
        let newcomer = EngineFixture(carol, stores: .inMemory(custodyLimits: Self.limits))
        linked(carrier, newcomer)
        var keysLost = 0
        exchange(carrier, newcomer) { frame in
            let keyAhead = frame.envelope.type == .profile && frame.envelope.senderId == alice.nodeId.string && keysLost == 0
            if keyAhead {
                keysLost += 1
            }
            return keyAhead
        }

        #expect(keysLost == 1, "the key sent ahead was lost")
        #expect(newcomer.engine.dropped[.noSenderKey, default: 0] > 0, "so Carol refused and parked Alice's posts")
        #expect(alicesPosts(held: newcomer).count == Self.posts, "then her key request brought the key, and the posts replayed")
        expectShortNothing(newcomer, of: carrier)
    }

    @Test func aPinKeptBeforeItsProofSendsNoKeyAhead() throws {
        // A pin from before the proof was kept, as on a phone upgraded to it: the backlog goes, and its reader asks.
        let stores = MeshStores.inMemory()
        stores.peers.upsert(PeerRecord(nodeId: alice.nodeId, name: "", status: "", publicKey: alice.keys.bundle.encoded, updatedAt: 1))
        let post = try alice.roomPost("Before", id: "alice-0", sentAt: EngineFixture.start)
        let carried = CarriedFrame(envelope: post.envelope, sig: post.wire.sig, signed: post.wire.signed)
        #expect(stores.custody.store(carried, origin: .relayed, now: EngineFixture.start))
        let fixture = EngineFixture(bob, stores: stores)
        fixture.link(carol)
        fixture.transport.clear()
        fixture.engine.receiveDigest([], from: carol.nodeId)
        #expect(fixture.transport.written.filter { $0.envelope.senderId == alice.nodeId.string }.map(\.envelope.id) == ["alice-0"])
    }
}
