import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The deadline a want of ours pulls its blob through by, from the rows that name it (`PullThroughGate`, knit-next ADR
/// 2026-10.2drc, ADR 2026-10.8hek), and the budget and deadline every ask carries: `MeshManagerTest`'s re-arm deadlines and
/// `InboundPipelineTest`'s delivered ones in knit-next. A DM's custody window from its latest row, none for a group's or a
/// room's, and a read that fails never lifting a DM's.
@Suite struct MeshEngineBlobDeadlineTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let photo = BlobHash(of: Array("a photo nobody near holds".utf8))
    private let day = PullThroughGate.windowMilliseconds

    /// Alice's stores in memory, their message store one whose reads of the rows naming a blob can fail.
    private func stores() -> (MeshStores, RefusingMessageStore) {
        let memory = MeshStores.inMemory()
        // Only the rows read fails here, and it fails outside any unit: nothing to refuse.
        let messages = RefusingMessageStore(memory.messages) {
            // No unit to fail.
        }
        let stores = MeshStores(
            custody: memory.custody,
            peers: memory.peers,
            messages: messages,
            conversations: memory.conversations,
            blocks: memory.blocks,
            groups: memory.groups,
            ownProfile: memory.ownProfile,
            blobs: memory.blobs,
            ratchet: memory.ratchet,
            groupRatchet: memory.groupRatchet,
            transactor: memory.transactor
        )
        return (stores, messages)
    }

    /// A row naming the photo: Bob's DM to Alice when `dm`, else a post in a group.
    private func row(_ label: String, sentAt: Int64, dm: Bool = true) -> MessageRecord {
        MessageRecord(
            id: frameIdOf(label),
            senderId: bob.nodeId,
            recipientId: dm ? alice.nodeId : nil,
            conversationId: dm ? bob.nodeId.string : "g-group",
            body: "",
            sentAt: sentAt,
            attachment: MessageAttachment(hash: photo)
        )
    }

    /// What the asks for the photo carried, in order.
    private func asks(_ fixture: EngineFixture) throws -> [BlobRequestContent] {
        try fixture.transport.written(.blobRequest).map { try BlobRequestContent(decoding: $0.envelope.payload) }
            .filter { $0.hash == photo.string }
    }

    @Test func everyAskCarriesTheBudgetAndTheDmsWindowAndAGroupRowLiftsIt() throws {
        let fixture = EngineFixture(alice)
        let sent = EngineFixture.start - 1000
        fixture.stores.messages.save(row("dm-1", sentAt: sent))
        fixture.link(carol)
        let first = try #require(try asks(fixture).last)
        #expect(first == BlobRequestContent(hash: photo.string, pull: BlobExchange.pullBudget, until: sent + day))
        let shown = "\(photo.string.prefix(8))…"
        #expect(
            fixture.log.all.contains(
                "debug mesh blob ask \(shown) → \(carol.nodeId) first (neighbour), widen in 5000 ms [pull 3, until \(sent + day)]"))
        // A later DM naming it moves the window to its own; a group's row then lifts it, at the next re-arm.
        fixture.stores.messages.save(row("dm-2", sentAt: sent + 500))
        fixture.advance(60_000)
        #expect(fixture.engine.blobExchange.wants[photo]?.until == sent + 500 + day, "the latest DM's")
        fixture.stores.messages.save(row("post-1", sentAt: sent, dm: false))
        fixture.advance(60_000)
        #expect(fixture.engine.blobExchange.wants[photo]?.until == nil)
        // The tick steps its due blobs ahead of its re-arm, so the next cycle's ask is the first to carry none.
        fixture.advance(60_000)
        let lifted = try asks(fixture)
        #expect(lifted.last == BlobRequestContent(hash: photo.string, pull: BlobExchange.pullBudget), "no deadline at all: \(lifted)")
    }

    @Test func aReArmWhoseRowsReadFailsKeepsTheDeadlineItHad() {
        let (stores, messages) = stores()
        let fixture = EngineFixture(alice, stores: stores)
        stores.messages.save(row("dm-1", sentAt: EngineFixture.start))
        fixture.advance(60_000)
        #expect(fixture.engine.blobExchange.wants[photo]?.until == EngineFixture.start + day)
        messages.failsAttachmentRows = true
        fixture.advance(60_000)
        #expect(fixture.engine.blobExchange.wants[photo]?.until == EngineFixture.start + day, "no rows read is no news")
    }

    @Test func aDeliveredDmIsPulledThroughUntilItsWindowAndARoomPostLiftsIt() throws {
        let fixture = EngineFixture(alice)
        fixture.link(carol)
        try fixture.pin(bob)
        let content = MessageContent(body: "", attachmentHash: photo.string, attachmentMime: "image/jpeg")
        let sent = EngineFixture.start - 3000
        fixture.deliver(try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: sent, content: content), from: carol)
        #expect(fixture.engine.blobExchange.wants[photo]?.until == sent + day, "from its first step")
        #expect(try asks(fixture).last?.until == sent + day)
        // A room post naming the same picture: no row that is no DM's has a deadline, so it lifts the DM's at once.
        let post = ChatContent(body: "", attachmentHash: photo.string, attachmentMime: "image/jpeg")
        fixture.deliver(try bob.roomPost("", id: frameIdOf("post-1"), sentAt: sent, content: post), from: carol)
        #expect(fixture.engine.blobExchange.wants[photo]?.until == nil)
    }

    /// A DM the ratchet sealed reaches its want by the same door, once its open's unit commits: from its first ask, the
    /// row it stored, clamped `sentAt` and all, sets the window (the crypto-reviewer's gap on 2026-10-24).
    @Test func aRatchetSealedDmIsPulledThroughUntilItsStoredRowsWindow() throws {
        let lab = EngineLab([try EngineFixture.ratcheting(alice, seed: 11), try EngineFixture.ratcheting(bob, seed: 12)])
        lab.link(0, 1)
        let picture = OutgoingPhoto(bytes: Array("a photo bob then loses".utf8), mime: "image/jpeg")
        let sent = try #require(lab[1].engine.sendDirectMessage("", to: alice.nodeId, photo: picture))
        let hash = try #require(sent.attachment?.hash)
        // Neither side holds the bytes, so nothing can serve them and the want stands to be read.
        lab[1].stores.blobs.remove(hash)
        lab.carry()
        let frame = try #require(lab.chats(from: 1, to: 0, id: sent.id).first)
        #expect(try ChatContent(decoding: frame.envelope.payload).enc?.ratchet != nil, "sealed with the ratchet")
        let stored = try #require(lab[0].stores.messages.message(sent.id))
        #expect(stored.attachment?.hash == hash)
        #expect(lab[0].engine.blobExchange.wants[hash]?.until == stored.sentAt + day)
        let asked = try lab[0].transport.written(.blobRequest).map { try BlobRequestContent(decoding: $0.envelope.payload) }
        #expect(asked.last == BlobRequestContent(hash: hash.string, pull: BlobExchange.pullBudget, until: stored.sentAt + day))
    }

    @Test func aDeliveredDmWhoseRowsReadFailsKeepsItsOwnWindow() throws {
        let (stores, messages) = stores()
        let fixture = EngineFixture(alice, stores: stores)
        try fixture.pin(bob)
        messages.failsAttachmentRows = true
        let content = MessageContent(body: "", attachmentHash: photo.string, attachmentMime: "image/jpeg")
        let sent = EngineFixture.start - 3000
        fixture.deliver(try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: sent, content: content), from: bob)
        #expect(fixture.engine.blobExchange.wants[photo]?.until == sent + day, "the delivered row, folded in by its id")
    }

    @Test func aDmPastItsWindowAsksNobodyToPullItFromItsFirstStep() {
        let fixture = EngineFixture(alice, configuration: MeshConfiguration(queriesBlobHolders: true))
        fixture.stores.messages.save(row("dm-1", sentAt: EngineFixture.start - day - 1))
        fixture.link(carol, capabilities: Capabilities.local.union(.blobHave))
        let query = fixture.transport.written(.blobHave)
        #expect(query.map(\.to) == [carol.nodeId])
        fixture.deliver(carol.blobHas([BlobHasItem(hash: photo.string, state: .notHeld)], re: query.first?.envelope.id), from: carol)
        #expect(fixture.transport.written(.blobRequest).isEmpty, "asked nobody to pull it")
        #expect(fixture.engine.blobCounts.pullsWithheld == 1)
        #expect(
            fixture.log.all.contains("debug mesh blob no-pull \(photo.string.prefix(8))… → nobody of \(carol.nodeId) (past its deadline)"))
    }
}
