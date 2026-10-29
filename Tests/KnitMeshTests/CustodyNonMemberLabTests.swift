import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A non-member's custody across engines of this port (knit-next ADR 2026-10.hr9f, #176, #235): Kotlin's
/// `CustodyQuotaLabTest.aNonMemberBackFilledAGroupDropsTheDmTheMembersEvicted` at knit-next `9f53dc34f`, on links a test
/// makes and breaks (``EngineLab``).
@Suite struct CustodyNonMemberLabTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 5)
    private let carol = TestPeer(seed: 6)
    private var hop: Int64 { Router.Configuration().jitterWindowMilliseconds + 1 }

    /// Lets every flood cross the lab: a hop for each node it may have to cross.
    private func settle(_ lab: EngineLab) {
        for _ in 0..<3 {
            lab.advance(hop)
        }
    }

    /// The links of the meeting's triangle, each direction by node index.
    private static let triangle = [(0, 1), (1, 0), (1, 2), (2, 1), (0, 2), (2, 0)]

    /// How many times node `from` wrote `id` over its link to node `to` since its `since`th write: addressed to `to`, or a
    /// flood, which reaches every node it is linked to. The meeting's links stay up from `since` on.
    private func copies(of id: String, from: Int, to: Int, since: [Int], in lab: EngineLab) -> Int {
        let peer = lab[to].me.nodeId
        return lab[from].transport.written.dropFirst(since[from]).filter { written in
            ExactKey(written.envelope.id) == ExactKey(id) && (written.to == nil || written.to == peer)
        }.count
    }

    /// Five frames per sender everywhere. Carol, outside Alice and Bob's group, takes Alice's DM to Bob, and Bob's sealed
    /// receipt for it, and is cut; Alice then posts six times to the group, so Alice's and Bob's buckets keep her newest five
    /// and drop the DM. Carol holds it still. Answers the lab and the DM's id.
    private func membersEvictedTheDm(crossings: Bool = false) throws -> (EngineLab, dm: String) {
        let limits = CustodyLimits(maxPerSender: 5)
        let lab = EngineLab(
            try [alice, bob, carol].enumerated().map { index, peer in
                try EngineFixture.ratcheting(peer, stores: .inMemory(custodyLimits: limits), seed: UInt64(61 + index))
            },
            crossings: crossings)
        lab.link(0, 1)
        lab.link(1, 2)
        settle(lab)
        let group = try #require(lab[0].engine.createGroup(with: [bob.nodeId])).id
        settle(lab)

        // Bob relays the DM on to Carol: she custodies it, and his sealed receipt for it, before the cut.
        let dm = try #require(lab[0].engine.sendDirectMessage("d", to: bob.nodeId)).id
        settle(lab)
        #expect(lab[1].stores.messages.message(dm)?.body == "d")
        #expect(lab.liveIds(2).contains(dm), "carol custodies the DM")
        lab.advance(lab[0].engine.configuration.reofferMilliseconds)
        #expect(Set(lab.liveIds(1)) == Set(lab.liveIds(2)), "bob and carol agree before the cut")
        lab.unlink(1, 2)

        let posts = try (1...6).map { index in
            let id = try #require(lab[0].engine.sendGroupMessage("post \(index)", to: group)).id
            settle(lab)
            return id
        }
        #expect(lab[1].stores.messages.messages(in: group).filter { $0.kind == .message }.count == 6)
        for member in 0...1 {
            let held = Set(lab.liveIds(member))
            #expect(!held.contains(dm), "node \(member): its quota evicted the DM")
            #expect(Set(posts.dropFirst()).isSubset(of: held) && !held.contains(posts[0]), "node \(member): the newest five posts")
        }
        #expect(lab.liveIds(2).contains(dm), "carol, cut before the posts, still holds the DM")
        #expect(posts.allSatisfy { !lab.liveIds(2).contains($0) }, "and none of the posts")
        return (lab, dm)
    }

    /// When the three meet, the members back-fill Carol the posts, her own bucket evicts the DM, and she sends it over each
    /// of her links at most once: the meeting's diff, before the posts land. Served to members only, she never got the
    /// posts, her digest listed the DM at every exchange, she served it at each one, and custody never agreed.
    ///
    /// The lab models no `LinkCrossings`, so the meeting falls inside the routers' seen window, where Alice and Bob take
    /// Carol's copy as the duplicate it is and relay nothing; past the window nobody holds the DM to serve it.
    @Test func aNonMemberBackFilledAGroupDropsTheDmTheMembersEvicted() throws {
        let (lab, dm) = try membersEvictedTheDm()

        // The meeting: a triangle, inside every router's seen window for the DM.
        let since = (0...2).map { lab[$0].transport.written.count }
        lab.link(1, 2)
        lab.link(0, 2)
        settle(lab)
        lab.advance(lab[0].engine.configuration.reofferMilliseconds)
        expectConverged(lab, dm: dm, since: since, "at the meeting")

        // Past the seen window and two re-offers, each digest is answered again, and nothing moves.
        lab.advance(SeenSetWindow.milliseconds)
        lab.advance(lab[0].engine.configuration.reofferMilliseconds)
        lab.advance(lab[0].engine.configuration.reofferMilliseconds)
        expectConverged(lab, dm: dm, since: since, "past the window")
    }

    /// The same meeting past every router's seen window for the DM, #235's shape (blobs-reviewer's follow-up to ADR
    /// 2026-10.hr9f). Carol's served copy now reaches Bob, its recipient, as a fresh frame: he stores it, his bucket evicts
    /// it in the same write, and his exists-gate answers it, since he holds its row. About eleven minutes after his receipt
    /// for it, that is inside the receipt's 15-minute floor, under the root he still holds, with the receipt in his
    /// custody, so he seals no second one (ADR 2026-10.8hn6), where before the floor he sealed one per such copy.
    ///
    /// The lab models each link's `LinkCrossings` here, as the radio has it, and counts what each link wrote, as Kotlin's
    /// `CustodyQuotaLabTest.copiesTo` counts its lab's `transport.sent`. Past the window the copy loops the triangle once:
    /// Carol serves Bob, Bob relays it to Alice, Alice to Carol, and Carol's router relays it to Bob again (hops 3). That
    /// last write is one the link drops, since the frame already crossed it, as `LinkManager.send` does, so each directed
    /// link writes the DM at most once. Then two more crossing windows pass, with re-offers between, so a node that still
    /// held the DM would serve it again once each crossing lapsed (the members-only serve rule before ADR 2026-10.hr9f):
    /// the bound, the live ids and the DM held nowhere are checked again there.
    @Test func aNonMemberMeetingPastTheSeenWindowDrawsNoSecondReceiptFromTheRecipient() throws {
        let (lab, dm) = try membersEvictedTheDm(crossings: true)
        let receipt = try #require(lab[1].engine.reAcks.entry(dm), "bob filed his receipt for the DM")
        let skipped = lab[1].engine.receipts.receiptsReAckSkipped

        lab.advance(SeenSetWindow.milliseconds)
        let since = (0...2).map { lab[$0].transport.written.count }
        lab.link(1, 2)
        lab.link(0, 2)
        settle(lab)
        lab.advance(lab[0].engine.configuration.reofferMilliseconds)
        #expect(lab.delivered(of: dm, from: 2, to: 1, since: since[2]) == 1, "carol served bob")
        expectWrittenOnce(lab, dm: dm, since: since, "at the meeting")
        #expect(lab[1].engine.receipts.receiptsReAckSkipped > skipped, "bob's exists-gate met carol's copy")
        #expect(lab[1].engine.reAcks.entry(dm) == receipt, "and answered it with the receipt he holds: no second one")
        #expect(lab[1].stores.messages.messages(in: alice.nodeId.string).count == 1, "delivered once")

        // Two more crossing windows, which are the routers' seen windows too, with a re-offer each minute.
        let reoffer = lab[0].engine.configuration.reofferMilliseconds
        for _ in 0..<(2 * SeenSetWindow.milliseconds / reoffer + 1) {
            lab.advance(reoffer)
        }
        expectWrittenOnce(lab, dm: dm, since: since, "two crossing windows on")
        #expect(lab[1].engine.reAcks.entry(dm) == receipt, "and still no second receipt")
    }

    /// The link-level oracle: no link of the meeting wrote the DM more than once, the three custodies hold the same live
    /// ids, and the DM is held nowhere.
    private func expectWrittenOnce(
        _ lab: EngineLab, dm: String, since: [Int], _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for (from, to) in Self.triangle {
            let sent = lab.delivered(of: dm, from: from, to: to, since: since[from])
            #expect(sent <= 1, "\(comment): node \(from)'s link wrote the DM to node \(to) \(sent) times", sourceLocation: sourceLocation)
        }
        let held = (0...2).map { Set(lab.liveIds($0)) }
        #expect(held[0] == held[1] && held[1] == held[2], "\(comment): the same live ids everywhere", sourceLocation: sourceLocation)
        #expect(held.allSatisfy { !$0.contains(dm) }, "\(comment): the evicted DM is held nowhere", sourceLocation: sourceLocation)
    }

    /// The oracle: no node wrote the DM over any link of the meeting more than once, the three custodies hold the same live
    /// ids, and the DM is held nowhere.
    private func expectConverged(
        _ lab: EngineLab, dm: String, since: [Int], _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for (from, to) in Self.triangle {
            let sent = copies(of: dm, from: from, to: to, since: since, in: lab)
            #expect(sent <= 1, "\(comment): node \(from) wrote the DM toward node \(to) \(sent) times", sourceLocation: sourceLocation)
        }
        let held = (0...2).map { Set(lab.liveIds($0)) }
        #expect(held[0] == held[1] && held[1] == held[2], "\(comment): the same live ids everywhere", sourceLocation: sourceLocation)
        #expect(held.allSatisfy { !$0.contains(dm) }, "\(comment): the evicted DM is held nowhere", sourceLocation: sourceLocation)
    }
}
