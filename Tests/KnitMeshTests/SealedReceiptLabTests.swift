import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// Our sealed receipts and inline acks between engines of this port with the ratchet's switch on (ADR 2026-10.5sk9, phase
/// P5d), on links a test makes and breaks (``EngineLab``): Bob (0), Carol (1), a carrier without the switch, and Alice (2).
/// A DM's receipt is a sealed `CTL_RECEIPT` that the author's own open reads, flipping its tick, and that purges nothing, so
/// every custody keeps the DM to its TTL and the digests still agree. A room tick waiting for a ride toward its author
/// crosses on a frame sealed to that author anyway: the receipt for that author's DM, or our next DM to it. Since phase
/// P5e the recipient also answers the init Bob's first DM carries, once, with its sealed profile, which these counts set
/// aside: it is no receipt.
@Suite struct SealedReceiptLabTests {
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let alice = TestPeer(seed: 1)

    /// The line, every pair acquainted, then Bob and Alice apart: what they send each other crosses Carol.
    private func line() throws -> EngineLab {
        let lab = EngineLab([
            try EngineFixture.ratcheting(bob, seed: 21), EngineFixture(carol, seed: 22), try EngineFixture.ratcheting(alice, seed: 23),
        ])
        lab.link(0, 1)
        lab.link(1, 2)
        lab.link(0, 2)
        lab.unlink(0, 2)
        return lab
    }

    /// Carries what was just written, then moves the line on past a relay's jitter twice: what one end floods reaches the
    /// other through Carol, and the answer comes back.
    private func cross(_ lab: EngineLab) {
        lab.carry()
        let jitter = lab[1].engine.configuration.router.jitterWindowMilliseconds
        lab.advance(jitter)
        lab.advance(jitter)
    }

    /// The DM-form chats node `from` wrote toward node `to` that are no message of its own and no answer to an init: its
    /// sealed receipts and ticks.
    private func sealed(from: Int, to: Int, in lab: EngineLab) -> [Written] {
        let peer = lab[to].me.nodeId.string
        let answers = lab[from].answerIds
        return EngineFixture.once(lab[from].transport.written(.chat)).filter { written in
            written.envelope.senderId == lab[from].me.nodeId.string && written.envelope.recipientId == peer
                && lab[from].stores.messages.message(written.envelope.id) == nil && !answers.contains(ExactKey(written.envelope.id))
        }
    }

    /// How many frames node `index` wrote under `id`, copies included.
    private func writesOf(_ id: String, by index: Int, in lab: EngineLab) -> Int {
        lab[index].transport.written.filter { ExactKey($0.envelope.id) == ExactKey(id) }.count
    }

    @Test func aSealedReceiptFlipsItsTickAtTheAuthorAndEveryCustodyKeepsTheDM() throws {
        let lab = try line()
        let dm = try #require(lab[0].engine.sendDirectMessage("hello", to: alice.nodeId))
        cross(lab)
        #expect(lab[2].stores.messages.message(dm.id)?.body == "hello", "Alice has it, through Carol")
        #expect(lab[0].stores.messages.message(dm.id)?.delivered == true, "Bob's own open of her sealed receipt flips his tick")
        #expect(lab[2].transport.written(.receipt).isEmpty, "never a cleartext receipt")
        let receipt = try #require(sealed(from: 2, to: 0, in: lab).first)
        #expect(sealed(from: 2, to: 0, in: lab).count == 1)
        #expect(
            lab[2].engine.answers.introsAnswered == 1 && lab[0].ratchetRecords(of: alice).session?.confirmed == true,
            "her answer confirmed Bob")
        for node in 0...2 {
            #expect(lab[node].stores.custody.contains(dm.id), "node \(node) keeps the DM: the receipt purges nothing")
            #expect(lab[node].stores.custody.contains(receipt.envelope.id), "and carries the receipt")
        }
        lab.advance(lab[0].engine.configuration.reofferMilliseconds)
        #expect(Set(lab.liveIds(0)) == Set(lab.liveIds(1)) && Set(lab.liveIds(1)) == Set(lab.liveIds(2)), "the digests agree")

        // Past the router's window and one more re-offer, every digest still lists the DM, so nobody serves it again.
        let writes = (0...2).map { writesOf(dm.id, by: $0, in: lab) }
        lab.advance(SeenSetWindow.milliseconds)
        lab.advance(lab[0].engine.configuration.reofferMilliseconds)
        #expect(sealed(from: 2, to: 0, in: lab).count == 1, "no second receipt")
        #expect((0...2).map { writesOf(dm.id, by: $0, in: lab) } == writes, "and no node wrote the DM again")
    }

    /// Bob's room post reaches Alice through Carol while Bob is away, so its tick waits for a ride; Bob's DM brings one, and
    /// Alice's sealed receipt for it carries the room's tick too. Bob's own open applies both. Later, a second room tick
    /// rides Alice's next DM to Bob, inline, and Bob's open of that DM flips it.
    @Test func roomTicksRideTheSealedReceiptAndTheNextDMToTheirAuthor() throws {
        let lab = try line()
        let post = try #require(lab[0].engine.postToRoom("Hello room"))
        cross(lab)
        #expect(lab[2].engine.ackSync.ridingFor(bob.nodeId) == 1, "Alice owes Bob the room's tick, waiting for a ride")
        let dm = try #require(lab[0].engine.sendDirectMessage("hello", to: alice.nodeId))
        cross(lab)
        #expect(lab[2].engine.ackSync.ridingFor(bob.nodeId) == 0, "it rode the receipt")
        #expect(sealed(from: 2, to: 0, in: lab).count == 1, "one frame for both")
        #expect(lab[0].stores.messages.message(dm.id)?.delivered == true && lab[0].stores.messages.message(post.id)?.delivered == true)

        let later = try #require(lab[0].engine.postToRoom("Anyone?"))
        cross(lab)
        #expect(lab[2].engine.ackSync.ridingFor(bob.nodeId) == 1)
        let reply = try #require(lab[2].engine.sendDirectMessage("here", to: bob.nodeId))
        cross(lab)
        #expect(lab[2].engine.ackSync.ridingFor(bob.nodeId) == 0, "it rode the DM, inline")
        #expect(lab[0].stores.messages.message(reply.id)?.body == "here")
        #expect(lab[0].stores.messages.message(later.id)?.delivered == true, "and Bob's open of the DM flipped it")
        #expect(sealed(from: 2, to: 0, in: lab).count == 1, "with no frame of its own")
    }

    /// The blobs re-review's back-fill pin, at Kotlin's level: a node that lacks a delivered DM and links to two holders
    /// relays the first copy it gets to the other before that holder's own copy crosses. Dave (3), new, links to Alice,
    /// whose frames to him are held, and then to Carol, whose back-fill brings him Bob's DM. Dave relays it to Alice past
    /// her router's window, and Alice, though her custody holds the DM throughout, answers that copy with one more sealed
    /// receipt, as Kotlin's exists-gate does (`InboundPipeline.kt:946-955`; a served frame floods on, `ForwardSync.kt:14-15`).
    /// Released, her own back-fill to Dave brings nothing more, past a window and a re-offer. It drops to one under
    /// knit-next #176's option 1 or 3; option 2 leaves it at two.
    @Test func aBackFillFedByTwoHoldersBuysTheRecipientOneMoreSealedReceipt() throws {
        let dave = TestPeer(seed: 4)
        let lab = EngineLab([
            try EngineFixture.ratcheting(bob, seed: 21), EngineFixture(carol, seed: 22), try EngineFixture.ratcheting(alice, seed: 23),
            EngineFixture(dave, seed: 24),
        ])
        lab.link(0, 1)
        lab.link(1, 2)
        lab.link(0, 2)
        lab.unlink(0, 2)
        let dm = try #require(lab[0].engine.sendDirectMessage("hello", to: alice.nodeId))
        cross(lab)
        #expect((0...2).allSatisfy { lab[$0].stores.custody.contains(dm.id) }, "Bob, Carol and Alice hold it")
        #expect(sealed(from: 2, to: 0, in: lab).count == 1)

        lab.advance(SeenSetWindow.milliseconds)
        lab.link(3, 2, holding: [(from: 2, to: 3)])
        lab.link(3, 1)
        lab.advance(lab[1].engine.configuration.router.jitterWindowMilliseconds)
        #expect(lab[3].stores.custody.contains(dm.id), "Dave took Carol's copy")
        #expect(sealed(from: 2, to: 0, in: lab).count == 2, "and relayed it to Alice, who acknowledged it again")
        #expect(lab[2].stores.custody.contains(dm.id), "though her custody held it throughout")

        lab.release(from: 2, to: 3)
        lab.advance(SeenSetWindow.milliseconds)
        lab.advance(lab[0].engine.configuration.reofferMilliseconds)
        #expect(sealed(from: 2, to: 0, in: lab).count == 2, "her own back-fill to Dave brings nothing more")
        #expect(lab[2].stores.custody.contains(dm.id))
    }

    /// The blobs re-review's two-hop pin, at Kotlin's level: a served copy is a fresh flood, a serve stamps nothing in the
    /// server's seen set, and every node past its router window relays it on, holders included (`MeshEngine.swift:225-237`,
    /// `MeshRouter.kt:113-114`). Dave (3), new, links to Bob, whose frames to him are held, and then to Carol, and never
    /// to Alice. Carol's back-fill brings him Bob's DM; he relays it to Bob, Bob to Carol and Carol to Alice, each past its
    /// window, and Alice, though every custody holds the DM, answers it with one more sealed receipt. Released, Bob's own
    /// back-fill to Dave brings nothing more, past a window and a re-offer. It drops to one under knit-next #176's option 1
    /// or 3; option 2 leaves it at two.
    @Test func aServedCopyReFloodsPastEveryHoldersWindowToARecipientTwoHopsAway() throws {
        let dave = TestPeer(seed: 4)
        let lab = EngineLab([
            try EngineFixture.ratcheting(bob, seed: 21), EngineFixture(carol, seed: 22), try EngineFixture.ratcheting(alice, seed: 23),
            EngineFixture(dave, seed: 24),
        ])
        lab.link(0, 1)
        lab.link(1, 2)
        lab.link(0, 2)
        lab.unlink(0, 2)
        let dm = try #require(lab[0].engine.sendDirectMessage("hello", to: alice.nodeId))
        cross(lab)
        #expect(sealed(from: 2, to: 0, in: lab).count == 1)

        lab.advance(SeenSetWindow.milliseconds)
        lab.link(3, 0, holding: [(from: 0, to: 3)])
        lab.link(3, 1)
        let jitter = lab[1].engine.configuration.router.jitterWindowMilliseconds
        for _ in 0..<3 {
            lab.advance(jitter)
        }
        #expect(sealed(from: 2, to: 0, in: lab).count == 2, "Dave's copy went Dave, Bob, Carol, Alice, and she answered it")
        #expect((0...3).allSatisfy { lab[$0].stores.custody.contains(dm.id) }, "though every custody holds the DM")

        lab.release(from: 0, to: 3)
        lab.advance(SeenSetWindow.milliseconds)
        lab.advance(lab[0].engine.configuration.reofferMilliseconds)
        #expect(sealed(from: 2, to: 0, in: lab).count == 2, "Bob's own back-fill to Dave brings nothing more")
    }

    /// The blobs review's parity pin (`InboundPipeline.kt:946-955`, whose comment names a copy our quotas evicted): our
    /// digest lists a delivered DM only while our custody holds it. Alice keeps two of Bob's frames and Carol and Bob four,
    /// so Bob's two room posts evict his DM from Alice's custody while every other node keeps it. Carol then serves it at
    /// each exchange, Alice's router lets one copy through per window, and her exists-gate answers each with one more
    /// sealed receipt, as Kotlin's does. Once two more posts evict the DM from Carol's custody and Bob's too, nobody serves
    /// it, and Alice sends nothing more.
    @Test func aDMOurQuotaEvictedIsReAckedOncePerRouterWindowUntilEveryCustodyEvictsIt() throws {
        let lab = EngineLab([
            try EngineFixture.ratcheting(bob, stores: .inMemory(custodyLimits: CustodyLimits(maxPerSender: 4)), seed: 21),
            EngineFixture(carol, stores: .inMemory(custodyLimits: CustodyLimits(maxPerSender: 4)), seed: 22),
            try EngineFixture.ratcheting(alice, stores: .inMemory(custodyLimits: CustodyLimits(maxPerSender: 2)), seed: 23),
        ])
        lab.link(0, 1)
        lab.link(1, 2)
        lab.link(0, 2)
        lab.unlink(0, 2)
        let dm = try #require(lab[0].engine.sendDirectMessage("hello", to: alice.nodeId))
        cross(lab)
        #expect(lab[2].stores.messages.message(dm.id)?.body == "hello" && sealed(from: 2, to: 0, in: lab).count == 1)
        for text in ["one", "two"] {
            _ = try #require(lab[0].engine.postToRoom(text))
            cross(lab)
        }
        #expect(!lab[2].stores.custody.contains(dm.id), "Bob's newer posts took Alice's two places for him")
        #expect(lab[1].stores.custody.contains(dm.id) && lab[0].stores.custody.contains(dm.id), "Carol and Bob keep it")

        let reoffer = lab[0].engine.configuration.reofferMilliseconds
        for window in 1...3 {
            for _ in 0..<(SeenSetWindow.milliseconds / reoffer) {
                lab.advance(reoffer)
            }
            #expect(sealed(from: 2, to: 0, in: lab).count == 1 + window, "one more sealed receipt in window \(window)")
        }
        #expect(lab[2].stores.messages.messages(in: bob.nodeId.string).count == 1, "delivered once")

        for text in ["three", "four"] {
            _ = try #require(lab[0].engine.postToRoom(text))
            cross(lab)
        }
        #expect(!lab[1].stores.custody.contains(dm.id) && !lab[0].stores.custody.contains(dm.id), "evicted everywhere now")
        let receipts = sealed(from: 2, to: 0, in: lab).count
        for _ in 0..<(2 * SeenSetWindow.milliseconds / reoffer) {
            lab.advance(reoffer)
        }
        #expect(sealed(from: 2, to: 0, in: lab).count == receipts, "nobody serves it, and Alice sends nothing more")
    }
}
