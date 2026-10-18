import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// What each side announces through the both-initiate race (#83; ADR 2026-10.5sk9): the other's opener once, as a message,
/// and its receipt for our own, whichever init wins and in either order. `RatchetSessionLabTests` checks the threads and the
/// sessions; this checks the events a screen and a notification hear, which a row written in a unit that did not commit
/// would leave out.
@Suite struct RatchetRaceEventTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)

    private func acquainted() throws -> EngineLab {
        let lab = EngineLab([try EngineFixture.ratcheting(alice, seed: 11), try EngineFixture.ratcheting(bob, seed: 12)])
        lab.link(0, 1)
        _ = lab[0].engine.drainEvents()
        _ = lab[1].engine.drainEvents()
        return lab
    }

    private func received(_ events: [MeshEvent]) -> [String] {
        events.compactMap { if case .received(let record, _) = $0 { record.body } else { nil } }
    }

    private func delivered(_ events: [MeshEvent]) -> [String] {
        events.compactMap { if case .delivered(let id) = $0 { id } else { nil } }
    }

    @Test(arguments: [true, false])
    func bothInitiateAndEachAnnouncesTheOthersOpener(aliceFirst: Bool) throws {
        let lab = try acquainted()
        lab.hold(from: 0, to: 1)
        lab.hold(from: 1, to: 0)
        let aliceOpens = try #require(lab[0].engine.sendDirectMessage("alice opens", to: bob.nodeId))
        lab.carry()
        let bobOpens = try #require(lab[1].engine.sendDirectMessage("bob opens", to: alice.nodeId))
        lab.carry()
        for (from, to) in aliceFirst ? [(0, 1), (1, 0)] : [(1, 0), (0, 1)] {
            lab.release(from: from, to: to)
        }
        let aliceEvents = lab[0].engine.drainEvents()
        let bobEvents = lab[1].engine.drainEvents()
        #expect(received(aliceEvents) == ["bob opens"], "alice announces bob's opener")
        #expect(received(bobEvents) == ["alice opens"], "bob announces alice's opener")
        #expect(delivered(aliceEvents) == [aliceOpens.id], "alice hears bob's receipt")
        #expect(delivered(bobEvents) == [bobOpens.id], "bob hears alice's receipt")
    }

    /// The loser's opener goes first and the winner's crosses it, as when a peer seals ticks for posts it was served while
    /// the other side writes to it.
    @Test func theLosersOpenerAfterTheWinnersTickIsAnnounced() throws {
        let lab = try acquainted()
        let (winner, loser) = alice.nodeId < bob.nodeId ? (0, 1) : (1, 0)
        let loserId = lab[loser].me.nodeId
        let winnerId = lab[winner].me.nodeId
        lab.hold(from: winner, to: loser)
        lab.hold(from: loser, to: winner)
        let opener = try #require(lab[loser].engine.sendDirectMessage("loser opens", to: winnerId))
        lab.carry()
        let winners = try #require(lab[winner].engine.sendDirectMessage("winner opens", to: loserId))
        lab.carry()
        lab.release(from: winner, to: loser)
        lab.release(from: loser, to: winner)
        let winnerEvents = lab[winner].engine.drainEvents()
        let loserEvents = lab[loser].engine.drainEvents()
        #expect(received(winnerEvents) == ["loser opens"], "the winner announces the loser's opener")
        #expect(received(loserEvents) == ["winner opens"])
        #expect(delivered(winnerEvents) == [winners.id], "the winner hears the loser's receipt")
        #expect(delivered(loserEvents) == [opener.id])
    }
}
