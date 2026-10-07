import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// An asker withdraws its ask with a `blobcancel` (knit-next ADR 2026-10.nsr7's cancel amendment, ADR 2026-10.ds45):
/// `BlobHolderQueryTest.aCancelDropsAParkedAskAndAQueuedCopy` and `aBlobThatLandsWithdrawsTheOtherAsks` in knit-next.
@Suite struct MeshEngineBlobCancelTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    private let photo: [UInt8] = Array("not really a jpeg, but bytes all the same".utf8)
    private var photoHash: BlobHash { BlobHash(of: photo) }
    /// What an Android build that reads the blob traffic claims in its HELLO.
    private let android = Capabilities.local.union(.blobHave)

    private func cancel(from peer: TestPeer, _ hash: String, id: String) -> TestFrame {
        peer.unsigned(.blobCancel, payload: BlobCancelContent(hash: hash).encoded, id: id)
    }

    // MARK: Holding

    @Test func aWithdrawalTakesAQueuedCopyOffAndAFreshAskOfItsOwnIsServed() {
        let fixture = EngineFixture(alice)
        fixture.stores.blobs.insert(photo, hash: photoHash, mime: "image/png", storedAt: EngineFixture.start)
        fixture.link(bob, carol)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: "breq-1"), from: bob)
        #expect(fixture.transport.files.count == 1)
        fixture.transport.queued = [(photoHash, bob.nodeId)]
        fixture.transport.inFlight = [(photoHash, bob.nodeId)]
        fixture.transport.clear()
        fixture.deliver(cancel(from: carol, photoHash.string, id: "cancel-claimed"), from: bob)
        fixture.deliver(cancel(from: bob, photoHash.string, id: "cancel-1"), from: bob)
        #expect(fixture.transport.withdrawn.map(\.to) == [bob.nodeId], "another sender's claim is not taken")
        #expect(fixture.engine.blobExchange.counts.cancelsTaken == 1)
        #expect(fixture.engine.dropped.isEmpty)
        #expect(fixture.transport.written.isEmpty, "unsigned by design, so no key is asked for, and never relayed")
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: "breq-2"), from: bob)
        #expect(fixture.transport.files.count == 1, "inside the memo, but the withdrawal forgot it")
    }

    @Test func aWithdrawalOfNothingQueuedOrNamingNoBlobChangesNothing() {
        let fixture = EngineFixture(alice)
        fixture.stores.blobs.insert(photo, hash: photoHash, mime: "image/png", storedAt: EngineFixture.start)
        fixture.link(bob)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: "breq-1"), from: bob)
        fixture.transport.clear()
        fixture.deliver(cancel(from: bob, photoHash.string, id: "cancel-1"), from: bob)
        fixture.deliver(cancel(from: bob, "not-a-hash", id: "cancel-2"), from: bob)
        fixture.deliver(bob.unsigned(.blobCancel, payload: [0xFF], id: "cancel-bad"), from: bob)
        #expect(fixture.engine.blobExchange.counts.cancelsTaken == 0)
        #expect(fixture.engine.dropped[.undecodable] == 1)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: "breq-2"), from: bob)
        #expect(fixture.transport.files.isEmpty, "a copy that streamed keeps its memo")
    }

    // MARK: Asking

    @Test func aWideningKeepsTheFirstPicksAskAndTheBlobLandingWithdrawsEveryOtherAsk() throws {
        let fixture = EngineFixture(alice)
        let dave = TestPeer(seed: 4)
        let erin = TestPeer(seed: 5)
        fixture.link(bob, carol, erin, capabilities: android)
        fixture.link(dave, capabilities: android.union(.doorbell))
        fixture.engine.wantBlob(photoHash, author: bob.nodeId, via: nil, asker: nil)
        #expect(fixture.transport.written(.blobRequest).map(\.to) == [bob.nodeId])
        fixture.advance(BlobExchange.firstAskGraceMilliseconds)
        let widened = fixture.transport.written(.blobRequest).dropFirst().map(\.to)
        #expect(widened == [carol.nodeId, erin.nodeId, dave.nodeId])
        #expect(fixture.transport.written(.blobCancel).isEmpty, "widening gives up on nobody: the author may have it queued")
        fixture.engine.receiveFile(InboundFile(from: carol.nodeId, kind: .attachment, hash: photoHash, mime: "image/png", bytes: photo))
        let cancels = fixture.transport.written(.blobCancel)
        #expect(cancels.map(\.to) == [bob.nodeId, erin.nodeId].sorted(), "not the one it came from, nor an iPhone")
        let cancel = try #require(cancels.last)
        #expect(try BlobCancelContent(decoding: cancel.envelope.payload) == BlobCancelContent(hash: photoHash.string))
        #expect(!cancel.wire.relay && cancel.wire.sig.isEmpty && cancel.envelope.senderId == alice.nodeId.string)
        #expect(fixture.engine.blobExchange.counts.cancelsSent == 2)
    }

    @Test func aBlobHeldSomeOtherWayWithdrawsEveryAskAtItsNextStep() {
        let fixture = EngineFixture(alice)
        fixture.link(bob, capabilities: android)
        fixture.engine.wantBlob(photoHash, author: bob.nodeId, via: nil, asker: nil)
        fixture.stores.blobs.insert(photo, hash: photoHash, mime: "image/png", storedAt: EngineFixture.start)
        fixture.advance(BlobExchange.firstAskGraceMilliseconds)
        #expect(fixture.transport.written(.blobCancel).map(\.to) == [bob.nodeId])
        #expect(!fixture.engine.blobExchange.isWanted(photoHash))
    }
}
