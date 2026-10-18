import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// knit-next ADR 2026-10.9wvr on two engines of this port with the switch on: `SessionLabTest`'s cases of `09cacf5b`,
/// under their Kotlin names (`SessionLabTest.kt` at `4f3cd995`), the field's shape of 2026-10-16. Alice reacts three times
/// a day after the pair last spoke; the three are the first frames of a fresh epoch of hers, based on Bob's newest, and
/// every copy is lost on the way. Bob's epoch has aged out too, so the pair talks on through epochs that never touch that
/// one, until Bob's 16-row cap retires the epoch the three were sealed against. Bob restarts (the sweep runs, the router's
/// dedup goes) and Alice's custody re-serves the three: each fails as `EPOCH_GONE` on a key retention took, in the era Bob
/// still holds, behind epochs Alice has sealed against since. Before the rule, three distinct ids re-rooted a session
/// that was working.
///
/// `bobInitiates` picks the half of the era gate Bob judges them on. Both pass these in-era frames as live, which is the
/// point: the rule this pins is the one that narrows the field's case, not the 48 h escape that widened it.
@Suite struct RatchetRetiredEpochLabTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private static let dayAndAMinute: Int64 = 86_400_000 + 60_000
    /// The turnarounds that take one side's epochs past the 16-row cap, and a margin.
    private static let maxCapTurns = 20

    /// Whether `item` is a DM-form chat from `sender` sealed in its send epoch `epoch`.
    private static func sealed(_ item: EngineLab.Carried, from sender: NodeId, inEpoch epoch: Int) -> Bool {
        guard case .frame(let written) = item, written.envelope.type == .chat,
            ExactKey(written.envelope.senderId) == ExactKey(sender.string),
            let header = (try? ChatContent(decoding: written.envelope.payload))?.enc?.ratchet
        else {
            return false
        }
        return header.se == epoch
    }

    /// Turnarounds until Bob's send epoch is past the cap from `base`, and how many it took.
    private func talkPastTheCap(_ lab: EngineLab, base: Int) throws -> Int {
        var turn = 0
        while try #require(lab[1].ratchetRecords(of: alice).session).sendEpoch < base + RatchetRetention.maxLocalEpochs {
            _ = try #require(lab[0].engine.sendDirectMessage("alice, turn \(turn)", to: bob.nodeId))
            lab.carry()
            _ = try #require(lab[1].engine.sendDirectMessage("bob, turn \(turn)", to: alice.nodeId))
            lab.carry()
            turn += 1
            guard turn <= Self.maxCapTurns else {
                Issue.record("bob's epochs never climbed past the cap")
                return turn
            }
        }
        return turn
    }

    private func framesSealedAgainstARetiredEpoch(bobInitiates: Bool) throws {
        let keychain = KeptSecretStore(bob.keys.storedForm)
        let lab = EngineLab([
            try EngineFixture.ratcheting(alice, seed: 11), try EngineFixture.ratcheting(bob, keychain: keychain, seed: 12),
        ])
        lab.link(0, 1)
        let (first, second) = bobInitiates ? (1, 0) : (0, 1)
        let hello = try #require(lab[first].engine.sendDirectMessage("hello", to: lab[second].me.nodeId)).id
        lab.carry()
        let hi = try #require(lab[second].engine.sendDirectMessage("hi", to: lab[first].me.nodeId)).id
        lab.carry()
        lab.expectConverged(0, 1, atLeast: 2, "greeted")
        #expect(lab[1].ratchetRecords(of: alice).session?.weAreInitiator == bobInitiates, "precondition: bob's half of the era gate")
        let target = bobInitiates ? hello : hi

        // A day apart: Alice's epoch ages out, so her next seal opens a fresh one, based on Bob's newest, which he will
        // never see a frame of; and Bob's ages out too, so his next opens one that never touches it. Unlinked, the three
        // reactions are lost on the air, and Alice's custody keeps them.
        lab.unlink(0, 1)
        lab.advance(Self.dayAndAMinute)
        let epochBefore = try #require(lab[0].ratchetRecords(of: bob).session).sendEpoch
        for emoji in ["\u{1F44D}", "\u{2764}\u{FE0F}", "\u{1F602}"] {
            _ = try #require(lab[0].engine.react(to: target, with: emoji))
        }
        let sealed = try #require(lab[0].ratchetRecords(of: bob).session)
        let doomedEpoch = sealed.sendEpoch
        let base = sealed.sendEpochBaseEpoch
        #expect(doomedEpoch == epochBefore + 1, "precondition: the reactions opened a fresh epoch of Alice's")

        // Back in range, the link-up's back-fill loses the three again; everything else crosses.
        lab.link(0, 1, holding: [(from: 0, to: 1)])
        lab.release(from: 0, to: 1) { held in held.filter { !Self.sealed($0, from: alice.nodeId, inEpoch: doomedEpoch) } }
        _ = try #require(lab[1].engine.sendDirectMessage("a day later", to: alice.nodeId))
        lab.carry()
        let turn = try talkPastTheCap(lab, base: base)
        #expect(lab[1].engine.dropped[.ratchetEpochGone] == nil, "no copy of the three reached bob")

        // Bob restarts over the stores he had: the start's sweep runs and the router forgets every id.
        let wall = lab[1].clock.wallMilliseconds()
        lab.replace(1, with: try EngineFixture.ratcheting(bob, stores: lab[1].stores, keychain: keychain, wall: wall, seed: 22))
        let held = try #require(lab[1].ratchetRecords(of: alice).session)
        #expect(lab[1].ratchetRecords(of: alice).localEpochs.allSatisfy { $0.epoch > base }, "the cap retired the three's base")
        #expect(held.highestPeAcked > base, "precondition: alice has sealed past epoch \(base)")

        // Alice's custody re-serves the three at the link-up, and each fails on a key retention took.
        lab.link(0, 1)
        #expect(lab[1].engine.dropped[.ratchetEpochGone] == 3)
        _ = try #require(lab[0].engine.sendDirectMessage("after the restart", to: bob.nodeId))
        lab.carry()
        lab.expectConverged(0, 1, atLeast: 4 + 2 * turn, "after the re-serve")
        let after = try #require(lab[1].ratchetRecords(of: alice).session)
        #expect(lab[1].resetsSent(to: alice).isEmpty && after.lastResetSentAt == held.lastResetSentAt, "bob never reset")
        #expect(after.root == held.root && after.confirmed, "the same root on bob, still confirmed")
    }

    @Test func framesSealedAgainstAnEpochTheCapRetiredNeverResetAWorkingSession() throws {
        try framesSealedAgainstARetiredEpoch(bobInitiates: false)
    }

    @Test func framesSealedAgainstAnEpochTheCapRetiredNeverResetTheInitiatorsSession() throws {
        try framesSealedAgainstARetiredEpoch(bobInitiates: true)
    }
}
