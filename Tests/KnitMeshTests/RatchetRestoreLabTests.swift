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
/// holds only what came after. The group case, `aRestoredNodeReMintsItsGroupChainAndTheMembersFollow`, is P6's. The P5b
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
        #expect(lab[index].ratchetRecords(of: peers[other]).session?.root != root, "a new session, not the old one")

        try send(lab, index, other, "after")
        try send(lab, other, index, "after too")
        #expect(lab.thread(index, with: other).count == 5, "the three, and what came after")
        #expect(Set(lab.thread(index, with: other)).isSubset(of: Set(lab.thread(other, with: index))))
        #expect(lab.sessionsAgree(0, 1), "\(lab.describe(0, 1))")
        #expect(lab[other].ratchetRecords(of: peers[index]).session?.lastResetSentAt == 0, "the peer never reset back")
        lab.advance(Self.minute)
        lab.expectCustodyAgrees(0, 1, resealed: away, from: other, to: index)
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
