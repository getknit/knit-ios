import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A race and then a restore, on two engines (knit-next ADR 2026-10.4mjm, #49; ADR 2026-10.5sk9's P9a amendment). knit-next's
/// own trace restores the race's loser; this port's restore keeps the Keychain and with it the inits the loser answered
/// (ADR 2026-10.wcex), so the loser's restored engine already reads the winner's re-served init as one it answered and
/// converges with or without the reclaim. The trace this port can fail restores the winner instead, Android-style: the
/// identity and prekeys from a backup taken before the race, and no answered init. Mirrors knit-next's
/// `RestoreLabTest.aRestoredRaceLoserWhoMeetsTheWinnersOldInitFirstMovesBackOntoItsReset` from the other side.
extension RatchetRestoreLabTests {
    /// Node `from` sends `text` to node `to`, and answers its id.
    private func dm(_ lab: EngineLab, _ from: Int, _ to: Int, _ text: String) throws -> String {
        let record = try #require(lab[from].engine.sendDirectMessage(text, to: lab[to].me.nodeId))
        lab.carry()
        return record.id
    }

    /// Both open a session at once, apart. The stayer hears the restored node's opener; the restored node hears only the
    /// stayer's, everything else the stayer wrote it lost on the air. Ten minutes on, the restored node comes back from a
    /// backup taken before the race, an Android restore: identity and prekeys, no session and no answered init. Linked again,
    /// the stayer's custody brings back its own opener, the abandoned init when the stayer lost, and the restored node
    /// establishes from it as its responder and answers, past the five-minute margin.
    ///
    /// With the restored node the smaller id, the stayer lost the race and holds its own init draining, stamped: the answer
    /// moves it back onto that init, and the pair meets on one root. With the reclaim forced off it stays on the winner's
    /// root, which the restore lost, and the threads part. With the restored node the larger id, the stayer won and stays on
    /// its own init, which the restored node takes up: a no-regression pin, which nothing here can fail.
    @Test(arguments: [true, false])
    func aRaceAndThenTheWinnersRestoreFromABackupMeetOnOneRoot(restoredIsSmaller: Bool) throws {
        let peers = [TestPeer(seed: 1), TestPeer(seed: 2)]
        let keychains = peers.map { KeptSecretStore($0.keys.storedForm) }
        let lab = EngineLab([
            try EngineFixture.ratcheting(peers[0], keychain: keychains[0], seed: 11),
            try EngineFixture.ratcheting(peers[1], keychain: keychains[1], seed: 12),
        ])
        lab.link(0, 1)
        let smaller = peers[0].nodeId < peers[1].nodeId ? 0 : 1
        let restored = restoredIsSmaller ? smaller : 1 - smaller
        let stayer = 1 - restored
        let backup = keychains[restored].contents

        lab.hold(from: 0, to: 1)
        lab.hold(from: 1, to: 0)
        _ = try dm(lab, restored, stayer, "the restored node opens")
        let opener = try dm(lab, stayer, restored, "the stayer opens")
        lab.release(from: restored, to: stayer)
        lab.release(from: stayer, to: restored) { items in items.filter { $0.id == opener } }
        let raced = try #require(lab[stayer].ratchetRecords(of: peers[restored]).session)
        #expect((raced.prevRootOwnInitAt != nil) == restoredIsSmaller, "the stayer stamped its own init only when it lost")

        lab.unlink(0, 1)
        lab.advance(10 * 60_000)
        let wall = lab[stayer].clock.wallMilliseconds()
        lab.replace(restored, with: try EngineFixture.ratcheting(peers[restored], keychain: KeptSecretStore(backup), wall: wall, seed: 21))
        #expect(lab[restored].engine.prekeyRing?.answeredInits.isEmpty == true, "an Android restore keeps no answered init")
        lab.link(0, 1, holding: [(from: stayer, to: restored)])
        let node = ExactKey(peers[restored].nodeId.string)
        lab.release(from: stayer, to: restored) { items in
            // Profiles and the opener; the stayer's other frames to the node went to the engine the restore replaced.
            items.filter { item in
                guard case .frame(let written) = item, ExactKey(written.envelope.recipientId ?? "") == node else {
                    return true
                }
                return ExactKey(written.envelope.id) == ExactKey(opener)
            }
        }
        #expect(lab.thread(restored, with: stayer).contains { $0.hasPrefix(opener) }, "the restored node read the opener")

        // The restored node's own opener went with the database the restore lost, so the threads are compared from here on.
        let after = try dm(lab, restored, stayer, "after the restore")
        #expect(lab.thread(stayer, with: restored).contains { $0.hasPrefix(after) }, "the stayer read the restored node")
        #expect(lab.bothHoldSessions(0, 1) && lab.sessionsAgree(0, 1), "one root, one era: \(lab.describe(0, 1))")
        #expect(lab[stayer].engine.answers.ratchetSwappedBack == (restoredIsSmaller ? 1 : 0))
        let met = lab[stayer].ratchetRecords(of: peers[restored]).session?.root
        #expect(met == (restoredIsSmaller ? raced.prevRoot : raced.root), "on the stayer's own init, the one the restore took up")
        if restoredIsSmaller {
            let back = try dm(lab, stayer, restored, "and back")
            #expect(lab.thread(restored, with: stayer).contains { $0.hasPrefix(back) }, "and the restored node the stayer")
        }
        // With the restored node the larger id, it re-derived the root it had adopted as a fresh responder, its epochs minted
        // again, and the stayer's base still names one the restore lost: the stayer's next frame is EPOCH_GONE until a reset.
        // That is the restore's, not the reclaim's: this port's reinstall keeps the answered init and resets at once (ADR
        // 2026-10.wcex), and Android's restore resets at once (`MeshManager.finishRestore`); the pin covers the reclaim alone.
        #expect(lab[0].resetsSent(to: peers[1]).isEmpty && lab[1].resetsSent(to: peers[0]).isEmpty, "no reset on either side")
    }
}
