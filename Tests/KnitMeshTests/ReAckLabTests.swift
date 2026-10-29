import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The exists-gate's sealed re-ack, bounded per era, between engines of this port with the ratchet's switch on (knit-next
/// #176, ADR 2026-10.8hn6), on links a test makes and breaks with each link's crossings memo modelled (``EngineLab``):
/// knit-next's `CustodyLabTest.aDeliveredDmBackFilledToItsRecipientPastItsSeenWindowDrawsNoSecondReceipt` and
/// `SessionLabTest.anAuthorsResetDrawsOneFreshReceiptForADmACarrierBackFillsToTheRecipient` (at `afdd37204`). Alice (0) is
/// the DM's recipient, Bob (1) its author, Carol (2) a carrier that holds it, and Dave (3), new, the node whose relay of
/// Carol's copy reaches Alice past her router's window.
@Suite struct ReAckLabTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)

    private func lab() throws -> EngineLab {
        EngineLab(
            [
                try EngineFixture.ratcheting(alice, seed: 41), try EngineFixture.ratcheting(bob, seed: 42),
                try EngineFixture.ratcheting(carol, seed: 43), try EngineFixture.ratcheting(dave, seed: 44),
            ],
            crossings: true)
    }

    /// Carries what was just written, then moves the lab on past a relay's jitter three times: a flood crosses the lab.
    private func cross(_ lab: EngineLab) {
        lab.carry()
        let jitter = lab[0].engine.configuration.router.jitterWindowMilliseconds + 1
        for _ in 0..<3 {
            lab.advance(jitter)
        }
    }

    /// Dave links Alice, his frames from her held so her own copy cannot cross first, then Carol, whose custody serves
    /// him `dm`; his relay reaches Alice. Answers once Alice has met it.
    private func daveBackFills(_ dm: String, in lab: EngineLab) {
        lab.link(3, 0, holding: [(from: 0, to: 3)])
        lab.link(3, 2)
        cross(lab)
        let relayed = lab.carriedFrames.contains { $0.from == 3 && $0.to == 0 && ExactKey($0.id) == ExactKey(dm) }
        #expect(relayed, "Dave relayed Carol's copy to Alice")
    }

    /// Bob's DM to Alice, delivered, its receipt sealed and Bob's tick on, and Carol holding the DM: answers its id.
    private func delivered(_ lab: EngineLab) throws -> String {
        let dm = try #require(lab[1].engine.sendDirectMessage("for alice", to: alice.nodeId)).id
        cross(lab)
        #expect(lab[0].stores.messages.message(dm)?.body == "for alice")
        #expect(lab[2].stores.custody.contains(dm), "Carol holds it")
        return dm
    }

    /// #176's second path: a back-fill fed by two holders hands a delivered DM back to its recipient past her router's
    /// window. Alice, Bob and Carol hold Bob's DM, and Alice's receipt has reached Bob. Eleven minutes on, Dave's relay of
    /// Carol's copy reaches Alice as a fresh flood. Inside the re-arm floor, with her receipt live in her custody and the
    /// root unchanged, she seals nothing more.
    @Test func aDeliveredDmBackFilledToItsRecipientPastItsSeenWindowDrawsNoSecondReceipt() throws {
        let lab = try lab()
        lab.link(0, 1)
        lab.link(1, 2)
        cross(lab)
        let dm = try delivered(lab)
        #expect(lab[1].stores.messages.message(dm)?.delivered == true, "Bob holds the tick")
        let sealed = lab[0].engine.receipts.receiptsSealed
        let receipt = try #require(lab[0].engine.reAcks.entry(dm))

        // Everyone apart, and past Alice's seen window for the DM.
        lab.unlink(0, 1)
        lab.unlink(1, 2)
        lab.advance(SeenSetWindow.milliseconds + 60_000)

        daveBackFills(dm, in: lab)
        lab.release(from: 0, to: 3)
        #expect(lab[0].engine.receipts.receiptsReAckSkipped >= 1, "her exists-gate met Dave's copy and answered it with her receipt")

        lab.link(0, 1)
        lab.link(1, 2)
        cross(lab)
        lab.expectConverged(0, 1, atLeast: 1, "after the back-fill")
        #expect(lab[0].engine.receipts.receiptsSealed == sealed, "Alice sealed one receipt for Bob's DM in all")
        #expect(lab[0].engine.reAcks.entry(dm) == receipt)
    }

    /// The author resets while a carrier back-fills its delivered DM to the recipient. Alice's receipt for Bob's DM is
    /// sealed under their first root and never reaches him: it waits on her held link to Bob, and the cut loses it. Bob
    /// then resets; the re-seal of unacked DMs runs only on the side that adopts a reset (ADR 2026-10.dmgw), and Alice has
    /// none, so nothing sends the DM again but custody: Dave, who lacks it, is fed by Carol and relays it to Alice past her
    /// seen window, well inside her receipt's floor. Her receipt is still live in her custody, so only the root she now
    /// holds tells this copy apart from a same-era re-serve: she seals exactly one receipt, under the new root, and that is
    /// the one that puts the tick on Bob.
    @Test func anAuthorsResetDrawsOneFreshReceiptForADmACarrierBackFillsToTheRecipient() throws {
        let lab = try lab()
        lab.link(0, 1)
        lab.link(1, 2)
        cross(lab)
        // A confirmed session first, so Bob's reset replaces its root rather than re-sending an unanswered init.
        let hello = try #require(lab[0].engine.sendDirectMessage("hello", to: bob.nodeId)).id
        cross(lab)
        #expect(lab[0].stores.messages.message(hello)?.delivered == true)

        // From here, Alice's frames to Bob wait on the link, and the cut below loses them.
        lab.hold(from: 0, to: 1)
        let sealed = lab[0].engine.receipts.receiptsSealed
        let dm = try delivered(lab)
        #expect(lab[0].engine.receipts.receiptsSealed == sealed + 1, "her first receipt, sealed in the first era")
        let firstReceipt = try #require(lab[0].engine.reAcks.entry(dm))
        #expect(lab[1].stores.messages.message(dm)?.delivered == false, "and held from Bob")

        lab.unlink(0, 1)
        lab.unlink(1, 2)
        lab.advance(SeenSetWindow.milliseconds + 60_000)
        guard case .sent(_, reRooted: true) = lab[1].engine.sendRatchetReset(to: alice.nodeId) else {
            Issue.record("Bob's reset went out under a fresh root")
            return
        }

        // Bob's custody brings Alice his reset; her custody would bring him her first receipt, which this link loses.
        lab.link(0, 1, holding: [(from: 0, to: 1)])
        cross(lab)
        let newTag = try #require(lab[0].engine.ratchet.rootTag(of: bob.nodeId))
        #expect(newTag != firstReceipt.rootTag && newTag == lab[1].engine.ratchet.rootTag(of: alice.nodeId), "Alice adopted it")
        #expect(lab[0].engine.receipts.receiptsSealed == sealed + 1, "adopting Bob's reset sealed no receipt")
        #expect(lab[1].stores.messages.message(dm)?.delivered == false, "Bob holds no tick for the DM yet")

        daveBackFills(dm, in: lab)
        #expect(lab[0].engine.receipts.receiptsSealed == sealed + 2, "one receipt in the new era")
        let fresh = try #require(lab[0].engine.reAcks.entry(dm))
        #expect(fresh.rootTag == newTag && fresh.step == 0 && fresh.receiptId != firstReceipt.receiptId)
        lab.release(from: 0, to: 1) { items in
            items.filter { $0.id.map { ExactKey($0) != ExactKey(firstReceipt.receiptId) } ?? true }
        }
        #expect(lab[1].stores.messages.message(dm)?.delivered == true, "the new era's receipt ticks the DM on Bob")
        lab.release(from: 0, to: 3)

        cross(lab)
        lab.expectConverged(0, 1, atLeast: 2, "after the reset")
        #expect(lab[0].engine.receipts.receiptsSealed == sealed + 2, "Alice sealed two receipts in all, one per era")
    }
}
