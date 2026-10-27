import Foundation
import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A sealed photo and the content of a DM carrying it with its key.
struct SealedPhoto {
    let sealed: AttachmentCrypto.Sealed
    let content: MessageContent
    var hash: BlobHash { BlobHash(of: sealed.blob) }

    /// `picture` sealed afresh.
    init(_ picture: [UInt8]) throws {
        let made = try #require(AttachmentCrypto.seal(picture))
        sealed = made
        content = MessageContent(
            body: "", attachmentHash: BlobHash(of: made.blob).string, attachmentMime: "image/jpeg", attachmentKey: Base64.encode(made.key))
    }
}

/// The `blobhave` and `blobreq` frames `fixture` wrote naming `hash`.
func requestAsks(_ fixture: EngineFixture, for hash: BlobHash) -> [Written] {
    let asks = fixture.transport.written(.blobRequest).filter { written in
        (try? BlobRequestContent(decoding: written.envelope.payload))?.hash == hash.string
    }
    let queries = fixture.transport.written(.blobHave).filter { written in
        (try? BlobHaveContent(decoding: written.envelope.payload))?.hashes.contains(hash.string) == true
    }
    return asks + queries
}

/// `bytes` landing from `peer` as an attachment.
func requestFile(_ bytes: [UInt8], from peer: TestPeer) -> InboundFile {
    InboundFile(from: peer.nodeId, kind: .attachment, hash: BlobHash(of: bytes), mime: "image/jpeg", bytes: bytes)
}

/// A message request's photo is neither fetched nor kept until the thread is accepted (knit-ios #21, from knit-next's
/// malicious-fork review H7): a fork minting identities could otherwise seal DMs naming 8 MiB blobs each, and the phone
/// would pull them all and keep them for good. Once accepted, the photo comes over the air from its author.
@Suite struct MeshEngineRequestPhotoTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private let picture = Array("a stranger's picture".utf8)
    private let thirtyOneMinutes: Int64 = 31 * 60_000

    private func sealedPhoto() throws -> SealedPhoto {
        try SealedPhoto(picture)
    }

    // MARK: Before and after accepting

    @Test func aStrangersSealedPhotoWaitsForAcceptThenComesFromItsAuthorAndOpens() throws {
        let fixture = EngineFixture(alice, configuration: MeshConfiguration(queriesBlobHolders: true))
        fixture.link(bob, carol, capabilities: Capabilities.local.union(.blobHave))
        try fixture.pin(bob)
        let photo = try sealedPhoto()
        fixture.transport.clear()
        fixture.deliver(
            try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: EngineFixture.start, content: photo.content), from: carol)
        let row = try #require(fixture.stores.messages.message(frameIdOf("dm-1")))
        #expect(fixture.engine.drainEvents().contains(.received(row, isRequest: true)))
        #expect(!fixture.engine.blobExchange.isWanted(photo.hash))
        #expect(requestAsks(fixture, for: photo.hash).isEmpty, "no query and no ask")
        #expect(
            fixture.log.all.contains(
                "debug mesh blob \(LinkManager.shown(photo.hash.string)) from \(bob.nodeId) not fetched (message request)"))
        fixture.advance(60_000)
        #expect(requestAsks(fixture, for: photo.hash).isEmpty, "nor at the re-offer")

        // A restart on the same stores re-arms from the rows, and still wants nothing.
        let restarted = EngineFixture(alice, stores: fixture.stores, configuration: MeshConfiguration(queriesBlobHolders: true))
        restarted.link(bob, carol, capabilities: Capabilities.local.union(.blobHave))
        #expect(!restarted.engine.blobExchange.isWanted(photo.hash))
        #expect(requestAsks(restarted, for: photo.hash).isEmpty)

        restarted.transport.clear()
        restarted.engine.accept(bob.nodeId.string)
        #expect(restarted.engine.blobExchange.wants[photo.hash]?.author == bob.nodeId)
        let queries = restarted.transport.written(.blobHave)
        #expect(Set(queries.map(\.to)) == [bob.nodeId, carol.nodeId], "each neighbour is asked whether it holds it")
        let toBob = queries.first { $0.to == bob.nodeId }
        restarted.deliver(bob.blobHas([BlobHasItem(hash: photo.hash.string, state: .have)], re: toBob?.envelope.id), from: bob)
        #expect(restarted.transport.written(.blobRequest).map(\.to) == [bob.nodeId], "exactly one ask, on the author's link")
        restarted.engine.receiveFile(requestFile(photo.sealed.blob, from: bob))
        let held = try #require(restarted.stores.blobs.bytes(of: photo.hash))
        let key = try #require(row.attachment?.key.flatMap { Base64.decode($0) })
        #expect(AttachmentCrypto.open(held, key: key) == picture, "it opens with the row's key")
    }

    @Test func aRatchetSealedPhotoFromAStrangerWaitsForAcceptToo() throws {
        let iphone = try EngineFixture.ratcheting(alice)
        let android = try AndroidPeer(bob)
        try iphone.pin(android)
        iphone.link(bob, carol)
        let photo = try sealedPhoto()
        let frame = try android.dm(
            photo.content, to: alice, prekey: try iphone.ourPrekey(), id: frameIdOf("dm-1"), sentAt: EngineFixture.start)
        iphone.transport.clear()
        iphone.deliver(frame, from: carol)
        #expect(iphone.stores.messages.message(frameIdOf("dm-1"))?.attachment?.hash == photo.hash)
        #expect(!iphone.engine.blobExchange.isWanted(photo.hash) && requestAsks(iphone, for: photo.hash).isEmpty)
        // The same id again, a re-seal or a carrier's copy: no second row, and still nothing wanted.
        let again = try android.dm(
            photo.content, to: alice, prekey: try iphone.ourPrekey(), id: frameIdOf("dm-1"), sentAt: EngineFixture.start)
        iphone.deliver(again, from: bob)
        #expect(iphone.stores.messages.messages(in: bob.nodeId.string).count == 1)
        #expect(!iphone.engine.blobExchange.isWanted(photo.hash) && requestAsks(iphone, for: photo.hash).isEmpty)
        iphone.engine.accept(bob.nodeId.string)
        #expect(iphone.transport.written(.blobRequest).map(\.to) == [bob.nodeId], "one ask, on the author's link")
        iphone.engine.receiveFile(requestFile(photo.sealed.blob, from: bob))
        let held = try #require(iphone.stores.blobs.bytes(of: photo.hash))
        let key = try #require(iphone.stores.messages.message(frameIdOf("dm-1"))?.attachment?.key.flatMap { Base64.decode($0) })
        #expect(AttachmentCrypto.open(held, key: key) == picture, "it opens with the key the ratchet's content carried")
    }

    @Test func aV1DMDeliveredTwiceBeforeAcceptKeepsOneRowAndWantsNothing() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        let photo = try sealedPhoto()
        let frame = try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: EngineFixture.start, content: photo.content)
        fixture.deliver(frame, from: bob)
        fixture.deliver(frame, from: bob)
        #expect(fixture.stores.messages.messages(in: bob.nodeId.string).count == 1)
        #expect(!fixture.engine.blobExchange.isWanted(photo.hash))
    }

    @Test(arguments: StoreKind.allCases)
    func aRatchetUnitReplayedAtTheSweepWantsNothingForARequest(kind: StoreKind) throws {
        let directory = scratchDirectory("request-replay")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, refusing) = try kind.storesRefusingRows(blobs: directory, failures: ReportedFailures().record)
        let iphone = try EngineFixture.ratcheting(
            alice, stores: stores, configuration: MeshConfiguration(queriesBlobHolders: true, ratchet: true))
        let android = try AndroidPeer(bob)
        try iphone.pin(android)
        iphone.link(carol, capabilities: Capabilities.local.union(.blobHave))
        let photo = try sealedPhoto()
        let frame = try android.dm(
            photo.content, to: alice, prekey: try iphone.ourPrekey(), id: frameIdOf("dm-1"), sentAt: EngineFixture.start)
        refusing.refusesRows = true
        iphone.deliver(frame, from: carol)
        refusing.refusesRows = false
        iphone.advance(MeshConfiguration().sweepMilliseconds)
        #expect(iphone.stores.messages.message(frameIdOf("dm-1"))?.attachment?.hash == photo.hash, "the replay stored the row")
        #expect(requestAsks(iphone, for: photo.hash).isEmpty && !iphone.engine.blobExchange.isWanted(photo.hash))
        iphone.engine.accept(bob.nodeId.string)
        #expect(iphone.engine.blobExchange.wants[photo.hash]?.author == bob.nodeId, "accepted, the replayed row's photo is wanted")
    }

    @Test func aRequestsPhotoAlreadyHeldLearnsItsPlaintextNameAndWantsNothing() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        try fixture.pin(bob)
        let photo = try sealedPhoto()
        fixture.stores.blobs.insert(photo.sealed.blob, hash: photo.hash, mime: "image/jpeg", storedAt: EngineFixture.start)
        fixture.deliver(
            try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: EngineFixture.start, content: photo.content), from: bob)
        #expect(fixture.stores.messages.message(frameIdOf("dm-1"))?.attachment?.plainHash == BlobHash(of: picture))
        #expect(!fixture.engine.blobExchange.isWanted(photo.hash) && fixture.transport.written(.blobRequest).isEmpty)
    }

    // MARK: What a request's photo costs

    @Test func aRequestOnlyBlobAnEchoBroughtCountsTowardTheEchoBudgetAndIsSwept() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol, dave)
        try fixture.pin(bob)
        let photo = try sealedPhoto()
        fixture.deliver(
            try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: EngineFixture.start, content: photo.content), from: bob)
        // Dave asks us for it, and Carol serves the echo.
        fixture.deliver(dave.blobRequest(for: photo.hash.string, id: frameIdOf("breq-1"), pull: 3), from: dave)
        #expect(fixture.engine.blobExchange.isEcho(photo.hash))
        fixture.engine.receiveFile(requestFile(photo.sealed.blob, from: carol))
        #expect(fixture.stores.blobs.contains(photo.hash))
        fixture.engine.measureEchoBudget()
        #expect(
            fixture.engine.blobExchange.echoBudget.heldForOthers == Int64(photo.sealed.blob.count),
            "held for others: no row it may keep names it")
        fixture.advance(thirtyOneMinutes)
        #expect(!fixture.stores.blobs.contains(photo.hash), "swept past an echo's life")
    }

    @Test(arguments: StoreKind.allCases)
    func aSweepWhoseAcceptedThreadsReadFailsRemovesNothing(kind: StoreKind) throws {
        let directory = scratchDirectory("request-unread")
        defer { try? FileManager.default.removeItem(at: directory) }
        let failures = ReportedFailures()
        let (stores, conversations) = try kind.storesRefusingConversationReads(blobs: directory, failures: failures.record)
        let fixture = EngineFixture(alice, stores: stores)
        fixture.link(bob)
        try fixture.pin(bob)
        fixture.befriend(bob)
        let photo = try sealedPhoto()
        fixture.deliver(
            try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: EngineFixture.start, content: photo.content), from: bob)
        fixture.engine.receiveFile(requestFile(photo.sealed.blob, from: bob))
        conversations.failsReads = true
        fixture.clock.advance(thirtyOneMinutes)
        fixture.engine.sweep()
        fixture.engine.sweepUnreferencedBlobs()
        #expect(stores.blobs.contains(photo.hash), "a read that failed is not no thread accepted")
        conversations.failsReads = false
        fixture.engine.sweep()
        #expect(stores.blobs.contains(photo.hash), "and read, it is named")
    }

    // MARK: Whose rows choose

    @Test func aForksEarlierRequestNamingAContactsPhotoNeitherAuthorsItNorSetsItsDeadline() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, dave)
        try fixture.pin(bob)
        try fixture.pin(dave)
        fixture.befriend(bob)
        let photo = try sealedPhoto()
        let sent = EngineFixture.start - 3000
        // The fork copies the hash into a DM dated earlier, and into a group request of its own, which would lift a deadline.
        fixture.deliver(
            try dave.directMessage("", to: alice, id: frameIdOf("dm-fork"), sentAt: sent - 1000, content: photo.content), from: dave)
        let forkGroup = roster([dave, alice], createdBy: dave)
        fixture.deliver(
            try dave.groupMessage("", in: forkGroup, to: [alice], id: frameIdOf("gm-fork"), sentAt: sent - 500, content: photo.content),
            from: dave)
        #expect(!fixture.engine.blobExchange.isWanted(photo.hash))
        fixture.deliver(try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: sent, content: photo.content), from: bob)
        let day = PullThroughGate.windowMilliseconds
        #expect(fixture.engine.blobExchange.wants[photo.hash]?.author == bob.nodeId)
        #expect(fixture.engine.blobExchange.wants[photo.hash]?.until == sent + day, "the fork's group row lifts nothing")

        let restarted = EngineFixture(alice, stores: fixture.stores)
        #expect(restarted.engine.blobExchange.wants[photo.hash]?.author == bob.nodeId, "the re-arm names the contact, not the fork")
        #expect(restarted.engine.blobExchange.wants[photo.hash]?.until == sent + day)
    }

    @Test func deletingTheAcceptedMessageForgetsTheWantARequestStillNames() throws {
        let fixture = EngineFixture(alice)
        fixture.link(bob, dave)
        try fixture.pin(bob)
        try fixture.pin(dave)
        fixture.befriend(bob)
        let photo = try sealedPhoto()
        fixture.deliver(
            try dave.directMessage("", to: alice, id: frameIdOf("dm-fork"), sentAt: EngineFixture.start, content: photo.content), from: dave
        )
        fixture.deliver(
            try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: EngineFixture.start, content: photo.content), from: bob)
        #expect(fixture.engine.blobExchange.isWanted(photo.hash))
        #expect(fixture.engine.deleteMessage(frameIdOf("dm-1")))
        #expect(!fixture.engine.blobExchange.isWanted(photo.hash), "the request naming it keeps no want")
    }

    @Test(arguments: StoreKind.allCases)
    func aDeleteWhoseAcceptedThreadsReadFailsRemovesNothingAnotherThreadNames(kind: StoreKind) throws {
        let directory = scratchDirectory("request-delete")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, conversations) = try kind.storesRefusingConversationReads(blobs: directory, failures: ReportedFailures().record)
        let fixture = EngineFixture(alice, stores: stores)
        fixture.link(bob, carol)
        try fixture.pin(bob)
        try fixture.pin(carol)
        fixture.befriend(bob, carol)
        let photo = try sealedPhoto()
        fixture.deliver(
            try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: EngineFixture.start, content: photo.content), from: bob)
        fixture.deliver(
            try carol.directMessage("", to: alice, id: frameIdOf("dm-2"), sentAt: EngineFixture.start, content: photo.content), from: carol)
        fixture.engine.receiveFile(requestFile(photo.sealed.blob, from: bob))
        conversations.failsReads = true
        #expect(fixture.engine.deleteMessage(frameIdOf("dm-1")))
        conversations.failsReads = false
        #expect(fixture.stores.blobs.contains(photo.hash), "Carol's thread still shows it, whatever the read said")
        #expect(fixture.engine.deleteMessage(frameIdOf("dm-2")))
        #expect(!fixture.stores.blobs.contains(photo.hash), "read, nothing names it")
    }

    @Test(arguments: StoreKind.allCases)
    func releasingABlobUnderAFailedReadKeepsItAndOneNotHeldReadsNothing(kind: StoreKind) throws {
        let directory = scratchDirectory("request-release")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (stores, conversations) = try kind.storesRefusingConversationReads(blobs: directory, failures: ReportedFailures().record)
        let fixture = EngineFixture(alice, stores: stores)
        fixture.link(bob)
        try fixture.pin(bob)
        fixture.befriend(bob)
        let photo = try sealedPhoto()
        fixture.deliver(
            try bob.directMessage("", to: alice, id: frameIdOf("dm-1"), sentAt: EngineFixture.start, content: photo.content), from: bob)
        fixture.engine.receiveFile(requestFile(photo.sealed.blob, from: bob))
        conversations.failsReads = true
        fixture.engine.releaseBlob(photo.hash)
        conversations.failsReads = false
        #expect(fixture.stores.blobs.contains(photo.hash), "a read that failed names nothing, and removes nothing")
        fixture.engine.releaseBlob(photo.hash)
        #expect(fixture.stores.blobs.contains(photo.hash), "read, Bob's thread names it")
        let absent = BlobHash(of: Array("never held".utf8))
        fixture.engine.releaseBlob(absent)
        #expect(!fixture.stores.blobs.contains(absent))
    }
}
