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
/// holds what came after, and, since our receipts are sealed (phase P5d) and purge nothing, the DMs the peer's custody
/// still holds from before that opened: the peer's opener, for a node that answered it. That opener breaks the pair
/// whether it comes before the reset or after it, and both orderings are pinned as known issues that block the flip
/// (`.agents/memory/roadmap.md`). The group case, `aRestoredNodeReMintsItsGroupChainAndTheMembersFollow`, is P6's. The P5b
/// blobs review adds a custody check after the re-seal and a crash stand-in over the database.
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
        // first, it comes after the third failure has reset the pair, and the race takes it by node id, so a peer whose
        // id is the smaller drags the reinstalled node back onto the root the pair left while the peer adopts the reset
        // (the P5d crypto owner's finding; ADR 2026-10.5sk9's P5a limits name the same hole for a reset). Each still reads
        // the other under the root it keeps draining, for two days.
        let racedTheOpener = index == 1 && peers[0].nodeId < peers[1].nodeId
        withKnownIssue("a stale opener served after a reinstall's reset wins the init race (P5d finding)") {
            #expect(lab[index].ratchetRecords(of: peers[other]).session?.root != root, "a new session, not the old one")
        } when: {
            racedTheOpener
        }

        try send(lab, index, other, "after")
        try send(lab, other, index, "after too")
        // A responder also gets its peer's opener back, the DM custody now keeps for its day (above).
        #expect(lab.thread(index, with: other).count == (index == 1 ? 6 : 5), "the three, what came after, and the opener")
        #expect(Set(lab.thread(index, with: other)).isSubset(of: Set(lab.thread(other, with: index))))
        withKnownIssue("a stale opener served after a reinstall's reset wins the init race (P5d finding)") {
            #expect(lab.sessionsAgree(0, 1), "\(lab.describe(0, 1))")
        } when: {
            racedTheOpener
        }
        #expect(lab[other].ratchetRecords(of: peers[index]).session?.lastResetSentAt == 0, "the peer never reset back")
        lab.advance(Self.minute)
        lab.expectCustodyAgrees(0, 1, resealed: away, from: other, to: index)
    }

    /// The reinstall's other ordering (the P5d crypto review's first finding), pinned as a known issue as the race above is,
    /// in both node-id orders: node `index` answered the peer's opener and then reinstalled, after a short history and with
    /// nothing sent while it was away, so the back-fill brings the opener before any failure could reset the pair. Only
    /// that ordering is asserted outside the pin. What the node makes of the opener is today's mechanism, which any fix
    /// changes: it takes the old root back with the prekey its Keychain kept, a fresh responder with no epoch of its own,
    /// and its next seal mints its first epoch again under a new key. The peer still holds that epoch on that root, so it
    /// reads the node on the old chain, below the cursor as duplicates, never counted, and at or past it as failures, and
    /// its own frames fail at the node too. The oracle still sees one root and one era. The pair heals only through a
    /// reset at either side's third failure, after silent drops, and only the reset's receiver re-seals. In the lab's case
    /// the node's receipt for the opener and its first DM drop as duplicates, and its second fails; the peer's two DMs then
    /// give the node its third failure first, so the node resets and reads them re-sealed, while nothing re-seals the
    /// node's own two, which the peer never reads. The pin is the fix's oracle (``expectHealed(_:_:sent:answered:)``).
    @Test(arguments: [0, 1])
    func aReinstalledResponderGetsItsOpenerBackFirstAndItsPeerReadsWhatItSendsNext(reinstalled index: Int) throws {
        let history = try reinstalledAfterAShortHistory(index)
        let lab = history.lab
        let ahead = try framesToTheNode(ahead: history.opener, in: history.backFill, of: index)
        #expect(ahead < 3, "so it reached the node before any reset could")

        let sent = try (1...2).map { try send(lab, index, 1 - index, "after \($0)") }
        let answered = try (1...2).map { try send(lab, 1 - index, index, "and back \($0)") }
        lab.advance(Self.minute)
        withKnownIssue("a reinstalled responder's opener served first re-mints its first epoch on the old root (P5d finding)") {
            expectHealed(lab, index, sent: sent, answered: answered)
        }
    }

    /// The same ordering with a room post between (the P5d crypto re-review's first finding), in both node-id orders: the
    /// peer posted in the room after its opener, so the back-fill, profiles first and then newest first, brings the post
    /// ahead of the opener. The node delivers it and owes the peer a tick, which it seals at once over the link
    /// (`sealLiveTick`), and with no session held that seal starts one with a plain init, so when the opener lands the
    /// node holds its own unanswered init and meets the opener in the race. Only that ordering is asserted outside the
    /// pin. Today, when the node's id is the smaller, its init wins the race at the node, the peer takes it as a
    /// replacement, and the pair heals with no reset, which the oracle pins plainly. When the node's id is the larger,
    /// the peer's remnant guard refuses the init and reads its frames read-only, the opener's old root wins the race at
    /// the node, and the pair breaks as in the case above: that order is the known issue. A fix's second half guarded by
    /// "while no session is held" never fires here, since the tick's init is held (`.agents/memory/roadmap.md`). The pin
    /// is the same oracle as the case above.
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
        let nodeIsTheLarger = lab[index].me.nodeId > lab[1 - index].me.nodeId
        withKnownIssue("a reinstalled responder's tick init meets the peer's opener in the race and loses (P5d finding)") {
            expectHealed(lab, index, sent: sent, answered: answered)
        } when: {
            nodeIsTheLarger
        }
    }

    /// A pair after a short history, its node reinstalled and linked again.
    private struct ShortHistory {
        /// The two engines.
        let lab: EngineLab
        /// The peer's opener, the DM its init rode.
        let opener: String
        /// What the peer wrote to the node at the link-up: its back-fill.
        let backFill: [Written]
    }

    /// Node `1 - index`'s opener to node `index` and node `index`'s answer, then `prelude`, then node `index` reinstalled, a
    /// fresh database with the Keychain's identity and prekeys kept, and linked again.
    private func reinstalledAfterAShortHistory(_ index: Int, prelude: ((EngineLab) throws -> Void)? = nil) throws -> ShortHistory {
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

        lab.advance(Self.minute)
        lab.unlink(0, 1)
        let wall = lab[index].clock.wallMilliseconds()
        lab.replace(index, with: try EngineFixture.ratcheting(peers[index], keychain: keychains[index], wall: wall, seed: 21))
        let written = lab[other].transport.written.count
        lab.link(0, 1)
        let backFill = lab[other].transport.written.dropFirst(written).filter { $0.to == peers[index].nodeId }
        return ShortHistory(lab: lab, opener: opener, backFill: Array(backFill))
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

    /// The fix's oracle for a reinstalled responder's opener (`.agents/memory/roadmap.md`): node `index`'s DMs `sent` read at
    /// the peer and the peer's `answered` at the node, the sessions agree, the node sends at most the one flagged reset a fix
    /// may send, counted by id, as the race above counts, and the peer sends none.
    private func expectHealed(_ lab: EngineLab, _ index: Int, sent: [String], answered: [String]) {
        let other = 1 - index
        let theirs = lab.thread(other, with: index)
        let mine = lab.thread(index, with: other)
        #expect(sent.allSatisfy { id in theirs.contains { $0.hasPrefix(id) } }, "the peer reads the node's DMs: \(theirs)")
        #expect(answered.allSatisfy { id in mine.contains { $0.hasPrefix(id) } }, "and the node the peer's: \(mine)")
        #expect(lab.sessionsAgree(0, 1), "\(lab.describe(0, 1))")
        let resets = lab[index].resetsSent(to: lab[other].me)
        let flagged = resets.allSatisfy { frame in
            let flags = (try? ChatContent(decoding: frame.envelope.payload))?.enc?.ratchet?.flags ?? 0
            return flags & RatchetHeader.resetFlag != 0
        }
        #expect(Set(resets.map(\.envelope.id)).count <= 1 && flagged, "at most the one flagged reset a fix may send")
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
