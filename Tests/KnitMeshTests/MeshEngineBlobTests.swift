import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// Blob requests and served files (`BlobExchangeTest`, `InboundPipelineTest.aBlobRequestIsDispatchedToBlobExchange`
/// in knit-next; ADR 2026-10.nh55).
@Suite struct MeshEngineBlobTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    private let photo: [UInt8] = Array("not really a jpeg, but bytes all the same".utf8)
    private var photoHash: BlobHash { BlobHash(of: photo) }

    private func holding(_ fixture: EngineFixture) {
        fixture.stores.blobs.insert(photo, hash: photoHash, mime: "image/png", storedAt: EngineFixture.start)
    }

    /// What the log says became of each blob request, in order.
    private func answers(_ fixture: EngineFixture) -> [String] {
        let prefix = "debug mesh blobreq \(photoHash.string.prefix(12)) from "
        return fixture.log.all.filter { $0.hasPrefix(prefix) }.compactMap { $0.split(separator: ": ", maxSplits: 1).last.map(String.init) }
    }

    @Test func aRequestIsServedFromWhatIsHeldToTheNeighbourWhoseLinkCarriedIt() {
        let fixture = EngineFixture(alice)
        holding(fixture)
        fixture.link(bob, carol)
        fixture.transport.clear()
        // The unsigned sender says carol; the request came over bob's link, so bob is the asker.
        fixture.deliver(carol.blobRequest(for: photoHash.string, id: frameIdOf("breq-1")), from: bob)
        #expect(fixture.transport.files == [SentFile(kind: .attachment, hash: photoHash, mime: "image/png", bytes: photo, to: bob.nodeId)])
        #expect(!fixture.stores.custody.contains(frameIdOf("breq-1")), "never carried")
        #expect(fixture.transport.written.isEmpty, "never relayed")
        #expect(fixture.engine.dropped.isEmpty, "unsigned by design, so not a drop")
        #expect(
            fixture.log.all.contains("debug mesh blobreq \(photoHash.string.prefix(12)) from \(bob.nodeId): serving \(photo.count) bytes"))
    }

    @Test func aRequestMarkedForRelayIsStillNeverFlooded() {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        fixture.transport.clear()
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-1"), relay: true), from: bob)
        fixture.advance(1000)
        #expect(fixture.transport.written.allSatisfy { $0.envelope.id != frameIdOf("breq-1") })
    }

    @Test func aSecondAskInsideTheMemoOrWhileACopyIsOnTheLinkServesNothing() {
        let fixture = EngineFixture(alice)
        holding(fixture)
        fixture.link(bob)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-1")), from: bob)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-2")), from: bob)
        #expect(fixture.transport.files.count == 1, "the serve memo")
        fixture.clock.advance(BlobExchange.serveMemoMilliseconds)
        fixture.transport.inFlight = [(photoHash, bob.nodeId)]
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-3")), from: bob)
        #expect(fixture.transport.files.count == 1, "a copy already on the link")
        fixture.transport.inFlight = []
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-4")), from: bob)
        #expect(fixture.transport.files.count == 2)
        let serving = "serving \(photo.count) bytes"
        #expect(answers(fixture) == [serving, "served to it within the serve memo", "already on its way", serving])
    }

    @Test func aBlobNotHeldIsPulledOnTheAskersBehalfAndNeverAskedOfIt() throws {
        // `aBlobPulledForANeighbourIsNotAskedOfItThatRoundButIsTheNext`: the asker lacks it (knit-next ADR 2026-10.f7gg).
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        fixture.transport.clear()
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-1")), from: bob)
        #expect(fixture.transport.files.isEmpty)
        let asked = fixture.transport.written(.blobRequest)
        #expect(asked.map(\.to) == [carol.nodeId])
        let request = try #require(asked.first)
        #expect(try BlobRequestContent(decoding: request.envelope.payload).hash == photoHash.string)
        #expect(fixture.transport.accepted == [photoHash], "the links keep it when it streams in")
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-2")), from: bob)
        fixture.advance(BlobExchange.firstAskGraceMilliseconds)
        #expect(fixture.transport.written(.blobRequest).count == 1, "already wanted, and the round has nobody else to widen to")
        #expect(answers(fixture) == ["not held; fetching it", "not held; fetching it"])
        let shown = "\(photoHash.string.prefix(BlobExchange.shownHashCharacters))…"
        // A fieldless ask is a fetch only: the echo it makes asks with no budget left (knit-next ADR 2026-10.2drc).
        #expect(fixture.log.all.contains("debug mesh blob ask \(shown) → \(carol.nodeId) first (neighbour), widen in 5000 ms [pull 0]"))
    }

    /// The `pull` and `until` of every ask for the photo the fixture wrote to `peer`.
    private func reach(_ fixture: EngineFixture, to peer: TestPeer) throws -> [BlobRequestContent] {
        try fixture.transport.written(.blobRequest).filter { $0.to == peer.nodeId }.map { written in
            try BlobRequestContent(decoding: written.envelope.payload)
        }
    }

    @Test func anEchoAsksWithOneHopLessThanItWasAskedAndTheAsksDeadline() throws {
        // knit-next ADR 2026-10.2drc: asked with 3, Alice wants it with 2 and asks Carol with that, and Bob's deadline.
        for (pull, budget) in [(3, 2), (1, 0)] {
            let fixture = EngineFixture(alice)
            fixture.link(bob, carol)
            fixture.transport.clear()
            let until = EngineFixture.start + 600_000
            fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-1"), pull: pull, until: until), from: bob)
            #expect(
                try reach(fixture, to: carol) == [BlobRequestContent(hash: photoHash.string, pull: budget, until: until)],
                "asked with \(pull)")
            #expect(answers(fixture) == ["not held; fetching it"])
        }
    }

    @Test func anAskWithNoBudgetLeftOrPastItsDeadlineMakesNoEchoButIsServed() {
        // `anAskWithNoBudgetFieldIsAFetchOnlyAndOneWithNoneLeftIsServedOnly` and `pastItsDeadlineAnAskMakesNoEcho…`.
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        fixture.transport.clear()
        let past = EngineFixture.start - 1
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-1"), pull: 0), from: bob)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-2"), pull: 3, until: past), from: bob)
        #expect(fixture.transport.written(.blobRequest).isEmpty && !fixture.engine.blobExchange.isWanted(photoHash), "no want at all")
        #expect(answers(fixture) == ["not held; no echo (fetch only)", "not held; no echo (past its deadline)"])
        let shown = "\(photoHash.string.prefix(BlobExchange.shownHashCharacters))…"
        #expect(fixture.log.all.contains("debug mesh blob no-echo \(shown) for \(bob.nodeId) (fetch only)"))
        #expect(fixture.log.all.contains("debug mesh blob no-echo \(shown) for \(bob.nodeId) (past its deadline)"))
        #expect(fixture.engine.blobCounts.echoesDeclined == 2)
        // Held, either ask is served: a holder serves past any budget or deadline.
        holding(fixture)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-3"), pull: 0), from: bob)
        fixture.deliver(carol.blobRequest(for: photoHash.string, id: frameIdOf("breq-4"), pull: 3, until: past), from: carol)
        #expect(fixture.transport.files.map(\.to) == [bob.nodeId, carol.nodeId])
    }

    @Test func aPullOutsideThirtyTwoBitsRefusesTheRequest() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.transport.clear()
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-1"), pull: Int(Int32.max) + 1), from: bob)
        #expect(fixture.engine.dropped[.undecodable] == 1)
        #expect(fixture.transport.written.isEmpty && !fixture.engine.blobExchange.isWanted(photoHash))
    }

    @Test func aRequestWhoseHashIsNotOneIsDropped() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.transport.clear()
        fixture.deliver(bob.blobRequest(for: "AB", id: frameIdOf("breq-1")), from: bob)
        #expect(fixture.transport.written.isEmpty && fixture.transport.files.isEmpty)
        #expect(fixture.engine.dropped[.undecodable] == 1)
    }

    @Test func aBlobRequestHasTheShapeAndroidGivesIt() throws {
        let fixture = EngineFixture(alice)
        let wire = fixture.engine.blobRequest(photoHash, pull: BlobExchange.pullBudget, until: nil)
        #expect(!wire.relay && wire.sig.isEmpty)
        // `{relay: false, sig: h'', signed: …}`: the default ttl and hops left out, as `wireEnvelopeUnsigned` has them.
        #expect(Hex.encode(Array(wire.encoded.prefix(20))) == "a36572656c6179f46373696740667369676e6564")
        let envelope = try RelayEnvelope(decoding: wire.signed)
        #expect(envelope.type == .blobRequest && envelope.senderId == alice.nodeId.string)
        #expect(envelope.sentAt == 0 && envelope.recipientId == nil && envelope.group == nil)
        #expect(envelope.id.utf8.count == 22, "a fresh frame id")
        #expect(
            try BlobRequestContent(decoding: envelope.payload) == BlobRequestContent(hash: photoHash.string, pull: BlobExchange.pullBudget))
    }

    @Test func aBlobArrivingOnALinkIsNotAskedFor() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.transport.clear()
        fixture.transport.arrivingFileKeys = [photoHash]
        fixture.engine.wantBlob(photoHash, author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: false))
        #expect(fixture.transport.written(.blobRequest).isEmpty)
        #expect(!fixture.engine.blobExchange.isWanted(photoHash), "not even marked: a torn transfer re-arms from the stores")
    }

    @Test func aWantedBlobIsAskedAgainAtEachReofferUntilItArrives() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.engine.wantBlob(photoHash, author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: false))
        fixture.transport.clear()
        fixture.advance(60_000)
        #expect(fixture.transport.written(.blobRequest).map(\.to) == [bob.nodeId])
        holding(fixture)
        fixture.transport.clear()
        fixture.advance(60_000)
        #expect(fixture.transport.written(.blobRequest).isEmpty, "held now, so wanted no more")
        #expect(!fixture.engine.blobExchange.isWanted(photoHash))
    }

    @Test func aNeighbourThatLinksDuringTheFirstAsksGraceIsAskedWhenTheRoundWidens() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.engine.wantBlob(photoHash, author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: false))
        fixture.transport.clear()
        fixture.link(carol)
        #expect(fixture.transport.written(.blobRequest).isEmpty, "the first ask's grace runs")
        fixture.advance(BlobExchange.firstAskGraceMilliseconds)
        #expect(fixture.transport.written(.blobRequest).map(\.to) == [carol.nodeId], "widened on the grace's own timer")
    }

    @Test func aNeighbourThatLinksAgainIsAskedAgainAtOnce() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.engine.wantBlob(photoHash, author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: false))
        fixture.transport.clear()
        fixture.unlink(bob)
        fixture.link(bob)
        #expect(fixture.transport.written(.blobRequest).map(\.to) == [bob.nodeId], "the ask may have died with the old link")
    }

    @Test func aWantNobodyRefreshedIsSweptAndTheLinksForgetIt() {
        let fixture = EngineFixture(alice)
        fixture.engine.wantBlob(photoHash, author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: false))
        #expect(fixture.transport.accepted == [photoHash])
        fixture.advance(BlobExchange.wantMilliseconds + 600_000)
        #expect(!fixture.engine.blobExchange.isWanted(photoHash))
        #expect(fixture.transport.accepted.isEmpty)
    }

    @Test func aFileWhoseBytesDoNotMatchItsHashIsDropped() {
        let fixture = EngineFixture(alice)
        fixture.engine.wantBlob(photoHash, author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: false))
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: photoHash, mime: "image/jpeg", bytes: [1]))
        #expect(!fixture.stores.blobs.contains(photoHash))
        #expect(fixture.engine.filesRejected == 1)
        #expect(fixture.engine.blobExchange.isWanted(photoHash), "still wanted, so asked again")
    }

    @Test func aFileNothingWantedIsDropped() {
        let fixture = EngineFixture(alice)
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: photoHash, mime: "image/jpeg", bytes: photo))
        #expect(!fixture.stores.blobs.contains(photoHash))
        #expect(fixture.engine.filesRejected == 1)
    }

    @Test func aFileIsTakenOffTheLinkOnceTheStoreHasAnsweredKeptOrNot() {
        // knit-next #138: until then a landing file still reads as on its way, so it is neither asked for nor queried.
        let fixture = EngineFixture(alice)
        fixture.engine.wantBlob(photoHash, author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: false))
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: photoHash, mime: "image/jpeg", bytes: [1]))
        fixture.engine.receiveFile(InboundFile(from: carol.nodeId, kind: .attachment, hash: photoHash, mime: "image/jpeg", bytes: photo))
        #expect(fixture.transport.taken.map(\.from) == [bob.nodeId, carol.nodeId])
        #expect(fixture.transport.taken.allSatisfy { $0.hash == photoHash })
    }

    @Test func aWantedFileIsKeptAndWantedNoMore() {
        let fixture = EngineFixture(alice)
        fixture.engine.wantBlob(photoHash, author: nil, via: nil, asker: nil, reach: .own(until: nil, rederived: false))
        fixture.engine.receiveFile(InboundFile(from: bob.nodeId, kind: .attachment, hash: photoHash, mime: "image/webp", bytes: photo))
        #expect(fixture.stores.blobs.bytes(of: photoHash) == photo)
        #expect(fixture.stores.blobs.mime(of: photoHash) == "image/webp")
        #expect(!fixture.engine.blobExchange.isWanted(photoHash))
        #expect(fixture.transport.accepted.isEmpty)
    }

    @Test func aServeThatNeverWentOutIsServedAtTheNextAsk() {
        let fixture = EngineFixture(alice)
        holding(fixture)
        // Carol's request came over a link the transport no longer holds, so nothing went out.
        fixture.deliver(carol.blobRequest(for: photoHash.string, id: frameIdOf("breq-1")), from: carol)
        #expect(fixture.transport.files.isEmpty)
        fixture.link(carol)
        fixture.deliver(carol.blobRequest(for: photoHash.string, id: frameIdOf("breq-2")), from: carol)
        #expect(fixture.transport.files.map(\.to) == [carol.nodeId], "not held off by the memo of a serve that never went out")
        #expect(answers(fixture) == ["no link to it", "serving \(photo.count) bytes"])
    }
}

/// Serving the rest of a cut transfer from the offset its asker kept (knit-next ADR 2026-10.wtyc, knit-ios #2).
extension MeshEngineBlobTests {
    /// `BlobExchangeTest.aServeStreamsFromTheAskersOffsetUpToTheWholeLength` (knit-next ADR 2026-10.wtyc): a resume
    /// streams from the asker's offset, up to the whole length, so a prefix already complete gets an empty tail and its
    /// END, and anything else the asker claims is the whole file. The log names the tail and, last, where it starts.
    @Test func aServeStreamsFromTheAskersOffsetUpToTheWholeLength() {
        let fixture = EngineFixture(alice)
        let image = Array("image".utf8)
        let hash = BlobHash(of: image)
        fixture.stores.blobs.insert(image, hash: hash, mime: "image/jpeg", storedAt: EngineFixture.start)
        fixture.link(bob)
        for (index, asked) in [2, 5, 6, 0, -1, nil].enumerated() {
            fixture.deliver(bob.blobRequest(for: hash.string, id: frameIdOf("breq-\(index)"), offset: asked.map(Int64.init)), from: bob)
            fixture.clock.advance(BlobExchange.serveMemoMilliseconds) // each ask a fresh one
        }
        let sent = fixture.transport.files
        #expect(sent.map(\.start) == [2, 5, 0, 0, 0, 0], "a resume, an empty tail, and the asker's nonsense as the whole file")
        #expect(sent.map(\.bytes) == [Array("age".utf8), [], image, image, image, image])
        #expect(
            sent.first == SentFile(kind: .attachment, hash: hash, mime: "image/jpeg", bytes: Array("age".utf8), to: bob.nodeId, start: 2))
        let prefix = "debug mesh blobreq \(hash.string.prefix(12)) from \(bob.nodeId): "
        let lines = fixture.log.all.filter { $0.hasPrefix(prefix) }.map { $0.dropFirst(prefix.count) }
        #expect(lines == ["serving 3 bytes resumed at 2", "serving 0 bytes resumed at 5"] + Array(repeating: "serving 5 bytes", count: 4))
    }

    /// The header a resumed serve streams under declares the tail and the byte it starts at, and a whole file's is the
    /// header it always was (`FramedLink.streamFile`): the file keeps the whole blob's size, so a feed from `start` has
    /// `size - start` left.
    @Test func aResumedServesHeaderDeclaresTheTailAndItsOffset() throws {
        let fixture = EngineFixture(alice)
        holding(fixture)
        let resumed = try #require(fixture.engine.outboundFile(photoHash, kind: .attachment, from: 10))
        #expect(resumed.size == photo.count && resumed.start == 10)
        #expect(
            resumed.header == FileHeader(kind: .attachment, key: photoHash.string, mime: "image/png", size: photo.count - 10, offset: 10))
        let complete = try #require(fixture.engine.outboundFile(photoHash, kind: .attachment, from: Int64(photo.count)))
        #expect(complete.header.size == 0 && complete.header.offset == photo.count, "an empty tail")
        #expect(OutboundFile.start(asked: 1, size: 0) == 0 && OutboundFile.start(asked: 0, size: 0) == 0, "an empty blob is whole")
        for whole in [nil, 0, -1, Int64(photo.count + 1), .max] as [Int64?] {
            let file = try #require(fixture.engine.outboundFile(photoHash, kind: .attachment, from: whole))
            #expect(
                file.start == 0 && file.header == FileHeader(kind: .attachment, key: photoHash.string, mime: "image/png", size: photo.count)
            )
        }
    }

    /// The serve memo is keyed by the blob and the asker alone (knit-next's `servedRecently`): an unsigned asker that names
    /// another offset inside it is served nothing more.
    @Test func anotherOffsetInsideTheMemoServesNothingMore() {
        let fixture = EngineFixture(alice)
        holding(fixture)
        fixture.link(bob)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-1"), offset: 20), from: bob)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-2"), offset: 10), from: bob)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: frameIdOf("breq-3")), from: bob)
        #expect(fixture.transport.files.map(\.start) == [20])
        #expect(
            answers(fixture) == ["serving \(photo.count - 20) bytes resumed at 20"]
                + Array(repeating: "served to it within the serve memo", count: 2))
    }
}

/// A file the engine streamed, read back from where it starts (``RecordingTransport/files``): the whole blob, or the
/// tail a resuming asker lacked, from `start`.
struct SentFile: Equatable {
    var kind: FileHeader.Kind
    var hash: BlobHash
    var mime: String
    var bytes: [UInt8]
    var to: NodeId
    var start = 0
}

extension TestPeer {
    /// An unsigned blob request, as Android builds one (`BlobExchange.blobRequest`): its budget and deadline when given
    /// (knit-next ADR 2026-10.2drc), and the bytes a build before them sends when not.
    /// An `offset` is the bytes of a cut transfer it kept (knit-next ADR 2026-10.wtyc).
    func blobRequest(
        for hash: String, id: String, relay: Bool = false, pull: Int? = nil, until: Int64? = nil, offset: Int64? = nil
    ) -> TestFrame {
        let content = BlobRequestContent(hash: hash, offset: offset, pull: pull, until: until)
        let envelope = RelayEnvelope(type: .blobRequest, id: id, senderId: nodeId.string, payload: content.encoded)
        return TestFrame(wire: WireEnvelope(relay: relay, sig: [], signed: envelope.encoded), envelope: envelope)
    }
}
