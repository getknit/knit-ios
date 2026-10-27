import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// The other half of ``MeshEngineEchoBudgetTests`` (knit-ios #20): a blob nothing names goes at the first sweep past an
/// echo's life, over both store kinds, unless something names it or uses it, and never on a read that failed; and a
/// link's queue of serves is bounded.
@Suite struct MeshEngineEchoSweepTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)

    private let photo: [UInt8] = Array("not really a jpeg, but bytes all the same".utf8)
    private var photoHash: BlobHash { BlobHash(of: photo) }
    private let thirtyOneMinutes: Int64 = 31 * 60_000

    private func shown(_ hash: BlobHash) -> Substring {
        hash.string.prefix(BlobExchange.shownHashCharacters)
    }

    /// What the log says became of each blob request for `hash`, in order.
    private func answers(_ fixture: EngineFixture, for hash: BlobHash) -> [String] {
        let prefix = "debug mesh blobreq \(hash.string.prefix(12)) from "
        return fixture.log.all.filter { $0.hasPrefix(prefix) }.compactMap { $0.split(separator: ": ", maxSplits: 1).last.map(String.init) }
    }

    private func file(_ bytes: [UInt8], from peer: TestPeer) -> InboundFile {
        InboundFile(from: peer.nodeId, kind: .attachment, hash: BlobHash(of: bytes), mime: "image/jpeg", bytes: bytes)
    }

    // MARK: The sweep

    /// Each reason a blob nothing names stays past an echo's life.
    enum Keep: CaseIterable, Sendable, CustomTestStringConvertible {
        case named
        case wanted
        case inFlight
        case parked
        case arriving

        var testDescription: String { "\(self)" }
    }

    /// An echo's blob: fetched for `bob`, landed, its want gone.
    private func echoBlob(_ fixture: EngineFixture) {
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-echo"), pull: 3), from: bob)
        fixture.engine.receiveFile(file(photo, from: dave))
        #expect(fixture.stores.blobs.contains(photoHash) && !fixture.engine.blobExchange.isWanted(photoHash))
    }

    @Test(arguments: StoreKind.allCases)
    func anEchosBlobGoesAtTheFirstSweepPastThirtyMinutes(kind: StoreKind) throws {
        let directory = scratchDirectory("echo-sweep")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record).0
        let fixture = EngineFixture(alice, stores: stores)
        fixture.link(bob, dave)
        echoBlob(fixture)
        fixture.advance(20 * 60_000)
        #expect(stores.blobs.contains(photoHash), "a sweep at 20 minutes: younger than an echo's life, so its asker still finds it")
        fixture.advance(11 * 60_000)
        #expect(!stores.blobs.contains(photoHash), "the first sweep past 30 minutes")
    }

    @Test(arguments: StoreKind.allCases, Keep.allCases)
    func aBlobInUseOrNamedStaysAtTheSweep(kind: StoreKind, keep: Keep) throws {
        let directory = scratchDirectory("echo-keep")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record).0
        let fixture = EngineFixture(alice, stores: stores)
        fixture.link(bob, dave)
        echoBlob(fixture)
        // An echo's life on: the sweep itself forgets a want older than that, so each reason is set up now.
        fixture.clock.advance(thirtyOneMinutes)
        let now = fixture.clock.monotonicMilliseconds()
        switch keep {
        case .named:
            stores.messages.save(
                MessageRecord(
                    id: frameIdOf("dm-photo"),
                    senderId: bob.nodeId,
                    recipientId: alice.nodeId,
                    conversationId: bob.nodeId.string,
                    body: "",
                    sentAt: EngineFixture.start,
                    attachment: MessageAttachment(hash: photoHash)
                ))
        case .wanted:
            fixture.engine.blobExchange.admit(BlobExchange.Want(hash: photoHash, at: now, author: nil, via: nil, puller: nil))
        case .inFlight:
            fixture.transport.inFlight = [(photoHash, bob.nodeId)]
        case .parked:
            _ = fixture.engine.blobExchange.park(photoHash, for: bob.nodeId, bytes: 10, reached: BlobExchange.Reached(), now: now)
        case .arriving:
            fixture.transport.arrivingFileKeys = [photoHash]
        }
        fixture.engine.sweep()
        #expect(stores.blobs.contains(photoHash))
        fixture.engine.sweepUnreferencedBlobs()
        #expect(stores.blobs.contains(photoHash), "nor does the start's sweep take it")
    }

    @Test(arguments: StoreKind.allCases)
    func aSweepWhoseReadsFailRemovesNothing(kind: StoreKind) throws {
        let directory = scratchDirectory("echo-unread")
        defer { try? FileManager.default.removeItem(at: directory) }
        let failures = ReportedFailures()
        let (stores, messages) = try kind.storesRefusingRows(blobs: directory, failures: failures.record)
        let fixture = EngineFixture(alice, stores: stores)
        fixture.link(bob, dave)
        echoBlob(fixture)
        stores.messages.save(
            MessageRecord(
                id: frameIdOf("dm-photo"),
                senderId: bob.nodeId,
                recipientId: alice.nodeId,
                conversationId: bob.nodeId.string,
                body: "",
                sentAt: EngineFixture.start,
                attachment: MessageAttachment(hash: photoHash)
            ))
        messages.failsAttachmentHashes = true
        fixture.clock.advance(thirtyOneMinutes)
        fixture.engine.sweep()
        fixture.engine.sweepUnreferencedBlobs()
        #expect(stores.blobs.contains(photoHash), "a row whose read failed may still name it")
        messages.failsAttachmentHashes = false
        fixture.engine.sweep()
        #expect(stores.blobs.contains(photoHash), "read, the row names it")
    }

    // MARK: Serving

    /// The budget reads high between measures, so a new echo it would decline is weighed again from the store first, at
    /// most once per ``BlobExchange/echoRemeasureMilliseconds``: inside that it stays declined, past it the store's
    /// measure, here nothing held, lets the echo be made.
    @Test func aSpentBudgetIsMeasuredAgainBeforeANewEchoIsDeclined() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.engine.blobExchange.echoBudget.landed(BlobExchange.echoBudgetBytes)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-1"), pull: 3), from: bob)
        #expect(answers(fixture, for: photoHash) == ["not held; no echo (over budget)"], "measured at the start, too soon again")
        fixture.clock.advance(BlobExchange.echoRemeasureMilliseconds)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-2"), pull: 3), from: bob)
        #expect(answers(fixture, for: photoHash).last == "not held; fetching it")
        #expect(fixture.engine.blobExchange.echoBudget.heldForOthers == 0)
    }

    @Test func aServeBehindEightWaitingIsRefusedAndCountedButAParkedTurnIsNot() {
        let fixture = EngineFixture(alice)
        fixture.stores.blobs.insert(photo, hash: photoHash, mime: "image/png", storedAt: EngineFixture.start)
        fixture.link(bob, carol)
        fixture.transport.clear()
        fixture.transport.waiting = [bob.nodeId: BlobExchange.maxWaitingServes, carol.nodeId: BlobExchange.maxWaitingServes]
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-1")), from: bob)
        #expect(fixture.transport.files.isEmpty)
        #expect(answers(fixture, for: photoHash) == ["not queued behind 8 files waiting"])
        #expect(fixture.log.all.contains("debug mesh blob no-serve \(shown(photoHash))… to \(bob.nodeId) (8 waiting)"))
        #expect(fixture.engine.blobCounts.servesRefused == 1)
        fixture.transport.waiting[bob.nodeId] = BlobExchange.maxWaitingServes - 1
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-2")), from: bob)
        #expect(fixture.transport.files.map(\.to) == [bob.nodeId], "nothing was stamped, so the next ask is served")
        fixture.engine.serveOrWant(photoHash, to: carol.nodeId, mayPark: false, reached: BlobExchange.Reached())
        #expect(fixture.transport.files.map(\.to) == [bob.nodeId, carol.nodeId], "a parked ask waited its turn already")
        #expect(fixture.engine.blobCounts.servesRefused == 1)
    }
}
