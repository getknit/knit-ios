import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// knit-next's `RestoreLabTest` (`mesh/lab/RestoreLabTest.kt`, at `cbf2a487`) on two engines of this port with the switch
/// on (ADR 2026-10.5sk9, phase P5b). Android's restore keeps the history and sends its peers a reset at once
/// (`MeshManager.finishRestore`); this port's nearest event is a reinstall, which keeps the Keychain's identity and
/// prekeys, loses the database, and sends no resets of its own (ADR 2026-09.tkww; ADR 2026-10.5sk9). The peer's frames
/// then fail as `NO_SESSION`, the heuristic resets at the third, and the peer seals its unacked DMs again under the new
/// session. So the first case sends three DMs while the node is away where Kotlin's sends two, and the reinstalled thread
/// holds what came after. Since our receipts are sealed (phase P5d) and purge nothing, the peer's custody still holds,
/// for its day, the opener of a node that answered it: the DM the peer's init rode. That opener broke the pair whether it
/// came before the reset or after it (ADR 2026-10.5sk9's P5d limits) until the node kept the inits it answered beside its
/// prekeys and reset at once on one of them (ADR 2026-10.wcex). Each ordering is now asserted plainly, in both node-id
/// orders: the node sends exactly one flagged reset, the peer none, and each side reads the other's DMs and receipts. The
/// group case, `aRestoredNodeReMintsItsGroupChainAndTheMembersFollow`, is P6's. The P5b blobs review adds a custody check
/// after the re-seal and a crash stand-in over the database.
@Suite struct RatchetRestoreLabTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private static let minute: Int64 = 60_000

    @discardableResult
    private func send(_ lab: EngineLab, _ from: Int, _ to: Int, _ text: String) throws -> String {
        let record = try #require(lab[from].engine.sendDirectMessage(text, to: lab[to].me.nodeId))
        lab.carry()
        return record.id
    }

    /// Node `index`, reinstalled while node `1 - index` keeps sending under the session it held, comes back, gets what was
    /// sent while it was away, and the pair carries on under a new session. Run for either side, so each reinstalls once.
    @Test(arguments: [0, 1])
    func aReinstalledNodeGetsWhatWasSentWhileItWasAwayAndCarriesOnUnderANewSession(reinstalled index: Int) throws {
        let peers = [alice, bob]
        let keychains = peers.map { KeptSecretStore($0.keys.storedForm) }
        let lab = EngineLab([
            try EngineFixture.ratcheting(alice, keychain: keychains[0], seed: 11),
            try EngineFixture.ratcheting(bob, keychain: keychains[1], seed: 12),
        ])
        let other = 1 - index
        lab.link(0, 1)
        try send(lab, 0, 1, "before")
        try send(lab, 1, 0, "before too")
        lab.expectConverged(0, 1, atLeast: 2, "before")
        let root = try #require(lab[0].ratchetRecords(of: bob).session).root

        lab.advance(Self.minute)
        lab.unlink(0, 1)
        let wall = lab[other].clock.wallMilliseconds()
        lab.replace(index, with: try EngineFixture.ratcheting(peers[index], keychain: keychains[index], wall: wall, seed: 21))
        // The peer goes on under the session it holds while the node is away: three, for the node's heuristic.
        let away = try (1...3).map { try send(lab, other, index, "while you were away \($0)") }

        lab.link(0, 1)
        #expect(Set(lab[index].resetsSent(to: peers[other]).map(\.envelope.id)).count == 1, "the third NO_SESSION reset the pair")
        let read = lab.thread(index, with: other)
        #expect(away.allSatisfy { id in read.contains { $0.hasPrefix(id) } }, "the peer sealed them again, and they open: \(read)")
        // Since P5d our receipt is sealed and purges nothing, so the peer's custody keeps its opener, the DM its init rode,
        // for the day, and serves it back to the node that answered it and then lost its database: Bob, here. Served newest
        // first, it comes after the third failure has reset the pair. It raced the reset by node id and, from a peer whose id
        // is the smaller, dragged the node back onto the root the pair left (the P5d crypto owner's finding). The node now
        // knows its init for one it answered, which races nothing (ADR 2026-10.wcex).
        #expect(lab[index].ratchetRecords(of: peers[other]).session?.root != root, "a new session, not the old one")

        try send(lab, index, other, "after")
        try send(lab, other, index, "after too")
        // A responder's opener comes back too, unread here: the session it rode is the one the reinstall lost. A copy past
        // the router's window can still read read-only (``aLateReServeOfTheOpenerReadsReadOnlyAndMovesNothing(reinstalled:)``).
        #expect(lab.thread(index, with: other).count == 5, "the three and what came after")
        #expect(Set(lab.thread(index, with: other)).isSubset(of: Set(lab.thread(other, with: index))))
        #expect(lab.sessionsAgree(0, 1), "\(lab.describe(0, 1))")
        #expect(lab[other].ratchetRecords(of: peers[index]).session?.lastResetSentAt == 0, "the peer never reset back")
        lab.advance(Self.minute)
        lab.expectCustodyAgrees(0, 1, resealed: away, from: other, to: index)
    }

    /// The reinstall's other ordering (the P5d crypto review's first finding), in both node-id orders: node `index` answered
    /// the peer's opener and then reinstalled, after a short history and with nothing sent while it was away, so the
    /// back-fill brings the opener before any third failure could reset the pair. Before the fix the node took the old root
    /// back with the prekey its Keychain kept, a fresh responder with no epoch of its own, and minted its first epoch again
    /// under a new key: the peer dropped its next frames as duplicates or failed them on the old chain, and the pair healed
    /// only through a heuristic reset, after silent drops, with the node's own DMs lost. Now the node knows the opener's init
    /// for one it answered, which establishes nothing, and since it holds no session it resets at once; the flag exempts
    /// the reset from the peer's remnant guard in either order, and the peer adopts it and re-seals (ADR 2026-10.wcex).
    @Test(arguments: [0, 1])
    func aReinstalledResponderGetsItsOpenerBackFirstAndItsPeerReadsWhatItSendsNext(reinstalled index: Int) throws {
        let history = try reinstalledAfterAShortHistory(index)
        let lab = history.lab
        let ahead = try framesToTheNode(ahead: history.opener, in: history.backFill, of: index)
        #expect(ahead < 3, "so it reached the node before any reset could")
        #expect(Set(lab[index].resetsSent(to: lab[1 - index].me).map(\.envelope.id)).count == 1, "the opener's arrival reset the pair")

        let sent = try (1...2).map { try send(lab, index, 1 - index, "after \($0)") }
        let answered = try (1...2).map { try send(lab, 1 - index, index, "and back \($0)") }
        lab.advance(Self.minute)
        expectHealed(lab, index, sent: sent, answered: answered, opener: history.opener)
    }

    /// The same ordering with a room post between (the P5d crypto re-review's first finding), in both node-id orders: the
    /// peer posted in the room after its opener, so the back-fill, profiles first and then newest first, brings the post
    /// ahead of the opener. The node delivers it and owes the peer a tick, which it seals at once over the link
    /// (`sealLiveTick`), and with no session held that seal starts one with a plain init, so when the opener lands the
    /// node holds its own unanswered init. When the node's id was the larger, the peer's remnant guard refused that init and
    /// the opener's old root won the race at the node. Now the opener races nothing, and the reset's guard covers this
    /// state, our own init unanswered with no reset since it, so the node marks that init with the flag at once, and the
    /// peer adopts it in either order (``RatchetResetPolicy/resetsOnAnsweredInit(_:)``, ADR 2026-10.wcex's option (i)).
    @Test(arguments: [0, 1])
    func aReinstalledResponderTicksItsPeersRoomPostBeforeTheOpenerLands(reinstalled index: Int) throws {
        let history = try reinstalledAfterAShortHistory(index) { lab in
            _ = try #require(lab[1 - index].engine.postToRoom("after the opener"))
            lab.carry()
        }
        let lab = history.lab
        let backFill = history.backFill
        let post = try #require(backFill.firstIndex { $0.envelope.isRoomPost }, "the back-fill brought the peer's room post")
        let opened = try #require(backFill.firstIndex { ExactKey($0.envelope.id) == ExactKey(history.opener) })
        #expect(post < opened, "ahead of the opener")
        let ahead = try framesToTheNode(ahead: history.opener, in: backFill, of: index)
        #expect(ahead < 3, "which still reached the node before any reset could")

        let sent = try (1...2).map { try send(lab, index, 1 - index, "after \($0)") }
        let answered = try (1...2).map { try send(lab, 1 - index, index, "and back \($0)") }
        lab.advance(Self.minute)
        expectHealed(lab, index, sent: sent, answered: answered, opener: history.opener)
    }

    /// The reinstall's first ordering for a responder, in both node-id orders: node `index` answered the peer's opener,
    /// reinstalled, and the peer sent three DMs while it was away, so the back-fill, newest first, brings their three
    /// failures and the node's heuristic reset ahead of the opener. The opener then met the node's unanswered reset in the
    /// race, by node id alone, and from a peer whose id is the smaller took the old root back while the peer adopted the
    /// reset: the split seen live on 2026-10-18 (ADR 2026-10.5sk9's live runs). Now the opener races nothing, and since our
    /// reset has gone, no second one follows (ADR 2026-10.wcex).
    @Test(arguments: [0, 1])
    func aReinstalledResponderGetsItsOpenerBackAfterItsResetAndStaysOnTheNewRoot(reinstalled index: Int) throws {
        let history = try reinstalledAfterAShortHistory(index, prelude: nil) { lab in
            try (1...3).map { try send(lab, 1 - index, index, "while you were away \($0)") }
        }
        let lab = history.lab
        let ahead = try framesToTheNode(ahead: history.opener, in: history.backFill, of: index)
        #expect(ahead >= 3, "so the node's heuristic reset the pair before the opener landed")
        let read = lab.thread(index, with: 1 - index)
        #expect(history.away.allSatisfy { id in read.contains { $0.hasPrefix(id) } }, "the peer sealed them again: \(read)")

        let sent = try (1...2).map { try send(lab, index, 1 - index, "after \($0)") }
        let answered = try (1...2).map { try send(lab, 1 - index, index, "and back \($0)") }
        lab.advance(Self.minute)
        expectHealed(lab, index, sent: sent, answered: answered + history.away, opener: history.opener)
    }

    /// The crypto review's C3: with the node's id the smaller, once the peer has confirmed the node's re-root the node's
    /// session is the remnant guard's state, a confirmed initiator with no peer init anchored. A copy of the opener served
    /// again past the router's ten minutes then opens read-only under the old root, as the late race loser's DM (#83):
    /// delivered, never answered, and nothing about the session moves (ADR 2026-10.wcex's limits).
    @Test func aLateReServeOfTheOpenerReadsReadOnlyAndMovesNothing() throws {
        let index = alice.nodeId < bob.nodeId ? 0 : 1
        let other = 1 - index
        let history = try reinstalledAfterAShortHistory(index)
        let lab = history.lab
        lab.advance(Self.minute)
        let held = try #require(lab[index].ratchetRecords(of: lab[other].me).session)
        #expect(held.confirmed && held.weAreInitiator && held.peerInitEphPub == nil, "the remnant guard's state")
        #expect(!lab.thread(index, with: other).contains { $0.hasPrefix(history.opener) })

        lab.advance(11 * Self.minute)
        let served = try #require(history.backFill.first { $0.envelope.id == history.opener })
        let written = lab[index].transport.written(.chat).count
        lab[index].engine.receive(InboundFrame(wire: served.wire, envelope: served.envelope, from: lab[other].me.nodeId))
        lab.carry()
        #expect(lab.thread(index, with: other).contains { $0.hasPrefix(history.opener) }, "read read-only, and delivered")
        let peer = ExactKey(lab[other].me.nodeId.string)
        let after = lab[index].transport.written(.chat).dropFirst(written).filter { $0.envelope.recipientId.map(ExactKey.init) == peer }
        #expect(after.count == 1, "one sealed receipt for it, and no answer to its init: \(after.map(\.envelope.id))")
        let now = try #require(lab[index].ratchetRecords(of: lab[other].me).session)
        #expect(now.root == held.root && now.establishedAt == held.establishedAt && now.peerInitEphPub == nil, "nothing moved")
        #expect(lab.sessionsAgree(0, 1), "\(lab.describe(0, 1))")
        #expect(Set(lab[index].resetsSent(to: lab[other].me).map(\.envelope.id)).count == 1, "no second reset")
    }

    /// A pair after a short history, its node reinstalled and linked again.
    private struct ShortHistory {
        /// The two engines.
        let lab: EngineLab
        /// The peer's opener, the DM its init rode.
        let opener: String
        /// What the peer wrote to the node at the link-up: its back-fill.
        let backFill: [Written]
        /// What the peer sent the node while it was away.
        let away: [String]
    }

    /// Node `1 - index`'s opener to node `index` and node `index`'s answer, then `prelude`, then node `index` reinstalled, a
    /// fresh database with the Keychain's identity and prekeys kept, then `away`, and linked again.
    private func reinstalledAfterAShortHistory(
        _ index: Int, prelude: ((EngineLab) throws -> Void)? = nil, away: ((EngineLab) throws -> [String])? = nil
    ) throws -> ShortHistory {
        let peers = [alice, bob]
        let other = 1 - index
        let keychains = peers.map { KeptSecretStore($0.keys.storedForm) }
        let lab = EngineLab([
            try EngineFixture.ratcheting(alice, keychain: keychains[0], seed: 11),
            try EngineFixture.ratcheting(bob, keychain: keychains[1], seed: 12),
        ])
        lab.link(0, 1)
        let opener = try send(lab, other, index, "the opener")
        try send(lab, index, other, "the answer")
        try prelude?(lab)
        lab.expectConverged(0, 1, atLeast: 2, "before")
        let kept = try #require(lab[index].engine.prekeyRing?.answeredInits)
        #expect(kept.map(\.peer) == [peers[other].nodeId], "the node kept the init it answered beside its prekeys")

        lab.advance(Self.minute)
        lab.unlink(0, 1)
        let wall = lab[index].clock.wallMilliseconds()
        lab.replace(index, with: try EngineFixture.ratcheting(peers[index], keychain: keychains[index], wall: wall, seed: 21))
        #expect(lab[index].engine.prekeyRing?.answeredInits == kept, "and the reinstall found it there")
        let sentAway = try away?(lab) ?? []
        let written = lab[other].transport.written.count
        lab.link(0, 1)
        let backFill = lab[other].transport.written.dropFirst(written).filter { $0.to == peers[index].nodeId }
        return ShortHistory(lab: lab, opener: opener, backFill: Array(backFill), away: sentAway)
    }

    /// How many of the peer's frames to node `index` the back-fill carried ahead of the opener. Fewer than three, and the
    /// opener reached the node before any third failure could reset the pair, whatever the node makes of either.
    private func framesToTheNode(ahead opener: String, in backFill: [Written], of index: Int) throws -> Int {
        let node = ExactKey([alice, bob][index].nodeId.string)
        let peer = ExactKey([alice, bob][1 - index].nodeId.string)
        let toTheNode = backFill.filter { frame in
            ExactKey(frame.envelope.recipientId ?? "") == node && ExactKey(frame.envelope.senderId) == peer
        }
        return try #require(toTheNode.firstIndex { ExactKey($0.envelope.id) == ExactKey(opener) }, "the back-fill brought the opener")
    }

    /// The fix's oracle for a reinstalled responder's opener (`.agents/memory/roadmap.md`; ADR 2026-10.wcex): node `index`'s
    /// DMs `sent` read at the peer, and every receipt for them read at the node; the peer's `answered` read at the node; the
    /// sessions agree; the node sends exactly one reset, flagged, counted by id, as the race above counts, and the peer
    /// sends none; and the stale `opener` is unread at the node. A later re-serve of it past the router's window can read
    /// read-only (``aLateReServeOfTheOpenerReadsReadOnlyAndMovesNothing()``); here none comes.
    private func expectHealed(_ lab: EngineLab, _ index: Int, sent: [String], answered: [String], opener: String) {
        let other = 1 - index
        let theirs = lab.thread(other, with: index)
        let mine = lab.thread(index, with: other)
        #expect(sent.allSatisfy { id in theirs.contains { $0.hasPrefix(id) } }, "the peer reads the node's DMs: \(theirs)")
        let ticked = sent.filter { lab[index].stores.messages.message($0)?.delivered == true }
        #expect(ticked == sent, "and the node reads every receipt for them: \(ticked) of \(sent)")
        #expect(answered.allSatisfy { id in mine.contains { $0.hasPrefix(id) } }, "and the node the peer's: \(mine)")
        #expect(!mine.contains { $0.hasPrefix(opener) }, "the opener rode the lost session, and is unread")
        #expect(lab.sessionsAgree(0, 1), "\(lab.describe(0, 1))")
        let resets = lab[index].resetsSent(to: lab[other].me)
        let flagged = resets.allSatisfy { frame in
            let flags = (try? ChatContent(decoding: frame.envelope.payload))?.enc?.ratchet?.flags ?? 0
            return flags & RatchetHeader.resetFlag != 0
        }
        #expect(Set(resets.map(\.envelope.id)).count == 1 && flagged, "exactly one flagged reset from the node")
        #expect(Set(lab[other].resetsSent(to: lab[index].me).map(\.envelope.id)).isEmpty, "and none from the peer")
    }

    /// The blobs review's crash stand-in, over the database: Alice's DM to Bob commits in its send unit while they are
    /// apart, so its one send reaches nobody, and her engine dies before anything else happens. The engine that replaces it
    /// over the same stores never signs it again: at the next link, Bob's digest lacks the id, Alice's custody serves the
    /// bytes it took in the unit, and Bob reads the DM from that one copy.
    @Test func aDMWhoseUnitCommittedBeforeACrashGoesFromCustodyAtTheNextLink() throws {
        let directory = scratchDirectory("crash-stand-in")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, _) = try StoreKind.sql.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let keychain = KeptSecretStore(alice.keys.storedForm)
        let lab = EngineLab([
            try EngineFixture.ratcheting(alice, stores: stores, keychain: keychain, seed: 11),
            try EngineFixture.ratcheting(bob, seed: 12),
        ])
        lab.link(0, 1)
        try send(lab, 0, 1, "before")
        try send(lab, 1, 0, "before too")
        lab.expectConverged(0, 1, atLeast: 2, "before")

        lab.unlink(0, 1)
        let id = try send(lab, 0, 1, "committed, then a crash")
        let custodied = try #require(stores.custody.frame(id, now: lab[0].clock.wallMilliseconds()), "custody took it in the unit")
        #expect(stores.messages.message(id)?.pendingKey == false, "and the row no longer waits")
        let wall = lab[0].clock.wallMilliseconds()
        lab.replace(0, with: try EngineFixture.ratcheting(alice, stores: stores, keychain: keychain, wall: wall, seed: 21))

        lab.link(0, 1)
        #expect(lab.thread(1, with: 0).contains { $0.hasPrefix(id) }, "Bob reads it")
        let carried = lab.chats(from: 0, to: 1, id: id)
        #expect(carried.count == 1 && carried.first?.wire.signed == custodied.signed, "the one copy is custody's bytes")
        lab.advance(Self.minute)
        let mine = Set(lab.liveIds(0))
        #expect(!mine.isEmpty && mine == Set(lab.liveIds(1)), "the same ids in both custodies")
    }

    /// #131: a file Bob sent that Alice cannot open goes again on her reset, sealed from its row, and the copy names the
    /// file and gives its size. This build sends no file of its own, so Bob's row is the one Android's `sendChat` leaves.
    @Test func aFileThatGoesAgainOnAResetKeepsItsNameAndSize() throws {
        let lab = EngineLab([try EngineFixture.ratcheting(alice, seed: 11), try EngineFixture.ratcheting(bob, seed: 12)])
        lab.link(0, 1)
        try send(lab, 0, 1, "before")
        try send(lab, 1, 0, "before too")
        let blob = BlobHash(of: Array("%PDF-1.7 quarterly figures".utf8))
        let file = MessageAttachment(
            hash: blob,
            mime: "application/pdf",
            key: Base64.encode([UInt8](repeating: 9, count: 32)),
            name: "quarterly-report.pdf",
            size: 1_400_000
        )
        let sentAt = lab[1].clock.wallMilliseconds()
        let report = MessageRecord(
            id: "the-report",
            senderId: bob.nodeId,
            recipientId: alice.nodeId,
            conversationId: alice.nodeId.string,
            body: "the report",
            sentAt: sentAt,
            attachment: file
        )
        lab[1].stores.messages.save(report)

        lab.advance(Self.minute)
        guard case .sent = lab[0].engine.sendRatchetReset(to: bob.nodeId) else {
            Issue.record("alice's reset went out")
            return
        }
        lab.carry()
        let row = try #require(lab[0].stores.messages.message("the-report"), "alice holds the file DM")
        #expect(row.attachment?.name == "quarterly-report.pdf", "the re-sealed copy named the file")
        #expect(row.attachment?.size == 1_400_000, "and gave its size")
        #expect(row.attachment?.mime == "application/pdf" && row.attachment?.hash == blob)
    }
}
