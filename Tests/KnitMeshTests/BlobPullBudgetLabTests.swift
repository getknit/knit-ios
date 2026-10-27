import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A picture nobody holds, across engines of this port in a line (knit-next ADR 2026-10.2drc, ADR 2026-10.8hek):
/// `StrandedAttachmentLabTest` and `PullBudgetLabTest` in knit-next, on ``EngineLab``. Every link's HELLO claims
/// ``Capabilities/blobHave`` and every engine queries, so each cycle queries, hears NONE and pulls, as the phones do. A
/// pull-through spends a hop of its budget at each ring, and no echo keeps another alive once its root stops.
@Suite struct BlobPullBudgetLabTests {
    /// A DM's author outside the lab, whom nobody can reach.
    private let author = TestPeer(seed: 9)
    private let photo = BlobHash(of: Array("a picture nobody in the lab holds".utf8))
    private let capable = Capabilities.local.union(.blobHave)
    private let ttl = BlobExchange.wantMilliseconds
    private let step: Int64 = 5000

    /// `count` engines that query holders, none linked yet. The sweep runs each minute, as Kotlin's lab sweeps each step,
    /// so a want ends the minute its TTL does.
    private func lab(_ count: Int) -> EngineLab {
        let configuration = MeshConfiguration(sweepMilliseconds: 60_000, queriesBlobHolders: true)
        return EngineLab(
            (0..<count).map { EngineFixture(TestPeer(seed: 11 + $0), configuration: configuration, seed: UInt64(41 + $0)) })
    }

    /// Links each node to the next.
    private func line(_ lab: EngineLab, _ count: Int) {
        for index in 0..<(count - 1) {
            lab.link(index, index + 1, capabilities: capable)
        }
    }

    /// A DM from the author to node `index`, sent at `sentAt` on the frame's clock, naming the photo.
    private func dm(_ lab: EngineLab, to index: Int, sentAt: Int64) {
        lab[index].stores.conversations.accept(author.nodeId.string)
        lab[index].stores.messages.save(
            MessageRecord(
                id: frameIdOf("m-root"),
                senderId: author.nodeId,
                recipientId: lab[index].me.nodeId,
                conversationId: author.nodeId.string,
                body: "",
                sentAt: sentAt,
                attachment: MessageAttachment(hash: photo)
            ))
    }

    /// The `pull` of every ask for the photo node `from` sent node `to`, in order: `nil` for an ask with no field.
    private func pulls(_ lab: EngineLab, from: Int, to: Int) -> [Int?] {
        let peer = lab[to].me.nodeId
        return lab[from].transport.written(.blobRequest).filter { $0.to == peer }.compactMap { written -> Int?? in
            guard case .map(let entries) = try? CBOR.decode(written.envelope.payload),
                entries.contains(where: { $0.key == .text("hash") && $0.value == .text(photo.string) })
            else {
                return nil
            }
            return .some(entries.first { $0.key == .text("pull") }?.value.int64.map { Int($0) })
        }
    }

    /// The queries node `from` sent node `to`.
    private func queries(_ lab: EngineLab, from: Int, to: Int) -> Int {
        lab[from].transport.written(.blobHave).count { $0.to == lab[to].me.nodeId }
    }

    /// The nodes that want the photo now.
    private func wanting(_ lab: EngineLab, _ count: Int) -> [Int] {
        (0..<count).filter { lab[$0].engine.blobExchange.isWanted(photo) }
    }

    /// Moves the lab on in 5 s steps for `milliseconds`, or until `done` holds, and answers how long it ran.
    @discardableResult
    private func run(_ lab: EngineLab, for milliseconds: Int64, until done: () -> Bool = { false }) -> Int64 {
        var ran: Int64 = 0
        while ran < milliseconds, !done() {
            lab.advance(step)
            ran += step
        }
        return ran
    }

    @Test func eachRingSpendsAHopOfTheBudgetAndTheLastOneOnlyQueries() {
        // `eachRingSpendsAHopOfTheBudgetAndTheLastOneOnlyQueries`: 0 — 1 — 2 — 3 — 4, and 0's DM names the photo.
        let lab = lab(5)
        dm(lab, to: 0, sentAt: EngineFixture.start)
        line(lab, 5)
        run(lab, for: 4 * 420_000)
        let ring = [pulls(lab, from: 0, to: 1), pulls(lab, from: 1, to: 2), pulls(lab, from: 2, to: 3)]
        #expect(!ring[0].isEmpty && ring[0].allSatisfy { $0 == BlobExchange.pullBudget }, "the root pulls with the whole budget")
        #expect(!ring[1].isEmpty && ring[1].allSatisfy { $0 == 2 }, "its echo with one less: \(ring[1])")
        #expect(!ring[2].isEmpty && ring[2].allSatisfy { $0 == 1 }, "the next with one: \(ring[2])")
        #expect(pulls(lab, from: 3, to: 4).isEmpty, "the third ring, at 0, asks nobody to pull it")
        #expect(queries(lab, from: 3, to: 4) > 0, "but still queries")
        #expect(!lab[4].engine.blobExchange.isWanted(photo), "and the fourth never wants it")
    }

    @Test func echoesOutliveARootThatStoppedByNoMoreThanATtlPerBudgetLevel() {
        // `aWantOfOurOwnWhoseReArmStoppedEndsWithinItsBudgetsTtls`, in a line: 0 — 1 — 2. 0's row is deleted, which forgets
        // its want at once (`MeshEngine+Deletes`); its echoes' asks back can make it again, each time with less budget.
        let lab = lab(3)
        dm(lab, to: 0, sentAt: EngineFixture.start)
        line(lab, 3)
        run(lab, for: 600_000)
        #expect(wanting(lab, 3) == [0, 1, 2], "the root and both rings want it")
        let rooted = [pulls(lab, from: 0, to: 1), pulls(lab, from: 1, to: 2), pulls(lab, from: 2, to: 1)]
        #expect(!rooted[0].isEmpty && rooted[0].allSatisfy { $0 == BlobExchange.pullBudget }, "3 at the root's ask: \(rooted[0])")
        #expect(!rooted[1].isEmpty && rooted[1].allSatisfy { $0 == 2 }, "then 2: \(rooted[1])")
        #expect(rooted[2].allSatisfy { $0 == 1 }, "and the second ring asks back with 1: \(rooted[2])")
        #expect(lab[0].engine.deleteMessage(frameIdOf("m-root")))
        let bound = (Int64(BlobExchange.pullBudget) + 1) * ttl + 60_000
        let ran = run(lab, for: bound + 600_000) { wanting(lab, 3).isEmpty }
        #expect(wanting(lab, 3).isEmpty, "every want ended")
        #expect(ran <= bound, "within a TTL per budget level and a re-offer: \(ran) ms")
    }

    @Test func aLinkThatReformsBetweenAnEchoAndItsNeighbourKeepsNeitherAlive() {
        // `aLinkThatReformsBetweenTwoEchoesRefreshesNeither`: a root outside the lab asks node 0 once, with the whole budget,
        // and walks away; 0 and 1 relink every four minutes, as a Bluetooth redial does.
        let lab = lab(2)
        lab.link(0, 1, capabilities: capable)
        let root = TestPeer(seed: 8)
        lab[0].deliver(root.blobRequest(for: photo.string, id: frameIdOf("breq-root"), pull: BlobExchange.pullBudget), from: root)
        lab.carry()
        run(lab, for: 60_000)
        #expect(wanting(lab, 2) == [0, 1], "0 echoes the root, and 1 echoes 0")
        let bound = (Int64(BlobExchange.pullBudget) + 1) * ttl + 60_000
        var ran: Int64 = 60_000
        while ran < bound + 600_000, !wanting(lab, 2).isEmpty {
            ran += run(lab, for: 240_000)
            lab.unlink(0, 1)
            lab.link(0, 1, capabilities: capable)
        }
        #expect(wanting(lab, 2).isEmpty, "both wants ended")
        #expect(ran <= bound, "within a TTL per budget level: \(ran) ms")
    }

    @Test func aDmPastItsWindowIsPulledThroughByNobody() {
        // `PullBudgetLabTest`'s DM delivered past its window: its want asks nobody to pull it from its first step.
        let lab = lab(2)
        dm(lab, to: 0, sentAt: EngineFixture.start - 90_000_000)
        lab.link(0, 1, capabilities: capable)
        run(lab, for: 600_000)
        #expect(queries(lab, from: 0, to: 1) > 0, "queried")
        #expect(pulls(lab, from: 0, to: 1).isEmpty, "and never asked")
        let line = "debug mesh blob no-pull \(photo.string.prefix(8))… → nobody of \(lab[1].me.nodeId) (past its deadline)"
        #expect(lab[0].log.all.contains(line))
        #expect(!lab[1].engine.blobExchange.isWanted(photo), "so nobody echoes it")
    }
}
