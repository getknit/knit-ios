import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// The holder query through the engine, both ends (knit-next ADR 2026-10.6e5t; `BlobHolderQueryTest` and
/// `InboundPipelineTest`'s blob cases in knit-next).
@Suite struct MeshEngineBlobQueryTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)

    private let photo: [UInt8] = Array("not really a jpeg, but bytes all the same".utf8)
    private var photoHash: BlobHash { BlobHash(of: photo) }
    private let other = BlobHash(of: Array("a blob nobody holds".utf8))

    private func holding(_ fixture: EngineFixture) {
        fixture.stores.blobs.insert(photo, hash: photoHash, mime: "image/png", storedAt: EngineFixture.start)
    }

    /// The answers the engine wrote, decoded, with whom each went to.
    private func answers(_ fixture: EngineFixture) throws -> [(content: BlobHasContent, to: NodeId?)] {
        try fixture.transport.written(.blobHas).map { (try BlobHasContent(decoding: $0.envelope.payload), $0.to) }
    }

    // MARK: Answering

    @Test func aQueryIsAnsweredFromReadsAloneAndServesNothing() throws {
        let fixture = EngineFixture(alice)
        holding(fixture)
        fixture.link(bob)
        fixture.transport.clear()
        fixture.deliver(bob.blobHave([photoHash.string, other.string, "not-a-hash"], id: "q-1"), from: bob)
        let answer = try #require(try answers(fixture).first)
        #expect(answer.to == bob.nodeId)
        #expect(
            answer.content.items == [
                BlobHasItem(hash: photoHash.string, state: .have, size: Int64(photo.count)),
                BlobHasItem(hash: other.string, state: .notHeld),
                BlobHasItem(hash: "not-a-hash", state: .notHeld),
            ])
        #expect(answer.content.load == 0 && answer.content.re == "q-1")
        let wire = try #require(fixture.transport.written(.blobHas).first)
        #expect(!wire.wire.relay && wire.wire.sig.isEmpty && wire.envelope.senderId == alice.nodeId.string)
        #expect(fixture.transport.files.isEmpty, "a query is not an ask")
        #expect(!fixture.engine.blobExchange.isWanted(other), "and wants nothing")
        #expect(fixture.transport.written(.keyRequest).isEmpty, "unsigned by design, so no key is asked for")
        #expect(fixture.engine.dropped.isEmpty)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: "breq-1"), from: bob)
        #expect(fixture.transport.files.count == 1, "the memo was peeked at, never stamped")
        #expect(fixture.engine.blobExchange.counts.queriesAnswered == 1)
    }

    @Test func aCopyOnTheLinkOrInsideTheMemoAnswersSendingAndOneOnItsWayInFetching() throws {
        let fixture = EngineFixture(alice)
        holding(fixture)
        fixture.link(bob, carol)
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: "breq-1"), from: bob)
        fixture.transport.inFlight = [(photoHash, carol.nodeId)]
        fixture.transport.arrivingFileKeys = [other]
        fixture.transport.feedingLoad = 2
        fixture.transport.clear()
        fixture.deliver(bob.blobHave([photoHash.string, other.string], id: "q-1"), from: bob)
        fixture.deliver(carol.blobHave([photoHash.string], id: "q-2"), from: carol)
        let states = try answers(fixture).map { $0.content.items.map(\.state) }
        #expect(states == [[.sending, .fetching], [.sending]], "the memo for bob, the link for carol")
        #expect(try answers(fixture).allSatisfy { $0.content.load == 2 })
        let shown = "\(photoHash.string.prefix(8)) SENDING \(photo.count)B, \(other.string.prefix(8)) FETCHING"
        #expect(fixture.log.all.contains("debug mesh blob has → \(bob.nodeId) #q-1 1/2 held: \(shown) load=2"))
    }

    @Test func aQueryMarkedForRelayOrNamingAnotherSenderIsNeitherAnsweredNorFlooded() {
        let fixture = EngineFixture(alice)
        holding(fixture)
        fixture.link(bob, carol)
        fixture.transport.clear()
        fixture.deliver(bob.blobHave([photoHash.string], id: "q-relay", relay: true), from: bob)
        fixture.deliver(carol.blobHave([photoHash.string], id: "q-claimed"), from: bob)
        fixture.advance(1000)
        #expect(fixture.transport.written(.blobHas).isEmpty)
        #expect(fixture.transport.written.allSatisfy { !["q-relay", "q-claimed"].contains($0.envelope.id) })
    }

    @Test func aNeighbourGetsSixteenAnswersInABurst() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.transport.clear()
        for index in 0..<17 {
            fixture.deliver(bob.blobHave([photoHash.string], id: "q-\(index)"), from: bob)
        }
        #expect(fixture.transport.written(.blobHas).count == 16)
        #expect(fixture.engine.blobExchange.counts.queriesRefused == 1)
    }

    @Test func aMalformedOrEmptyQueryAndAnAnswerFromElsewhereAreDroppedQuietly() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.transport.clear()
        fixture.deliver(bob.unsigned(.blobHave, payload: [0xFF], id: "q-bad"), from: bob)
        fixture.deliver(bob.blobHave([""], id: "q-empty"), from: bob)
        fixture.deliver(bob.unsigned(.blobHas, payload: [0xFF], id: "has-bad"), from: bob)
        fixture.deliver(carol.blobHas([BlobHasItem(hash: photoHash.string, state: .have)], re: nil), from: bob)
        fixture.deliver(bob.blobHas([BlobHasItem(hash: photoHash.string, state: .have)], re: "q-never"), from: bob)
        #expect(fixture.transport.written(.blobHas).isEmpty && fixture.transport.written(.blobRequest).isEmpty)
        #expect(fixture.engine.dropped[.undecodable] == 2)
        #expect(fixture.engine.blobExchange.counts.answersIgnored == 1, "only the one from its own link was read")
    }

    // MARK: Progress reports (knit-next ADR 2026-10.nsr7)

    @Test func aFileStreamingInIsReportedToItsSenderOnlyWhenItsLinkCarriesTheBit() throws {
        // `BlobHolderQueryTest.aFileStreamingInIsReportedToACapableSenderAndAReportReachesItsLink`'s sending half.
        let fixture = EngineFixture(alice)
        let dave = TestPeer(seed: 4)
        fixture.link(bob, capabilities: Capabilities.local.union(.blobHave))
        fixture.link(carol)
        fixture.link(dave, capabilities: Capabilities.local.union([.blobHave, .doorbell]))
        fixture.transport.clear()
        for peer in [bob, carol, dave, TestPeer(seed: 5)] {
            fixture.engine.fileProgress(FileProgress(from: peer.nodeId, hash: photoHash, held: 40_960, milliseconds: 2000))
        }
        let sent = fixture.transport.written(.blobProgress)
        // An iPhone too, since it clocks its feed by the reports (ADR 2026-10.xwjc).
        #expect(sent.map(\.to) == [bob.nodeId, dave.nodeId], "not to an older build or a peer no longer linked")
        let report = try #require(sent.first)
        #expect(
            try BlobProgressContent(decoding: report.envelope.payload)
                == BlobProgressContent(hash: photoHash.string, held: 40_960, ms: 2000))
        #expect(!report.wire.relay && report.wire.sig.isEmpty && report.envelope.senderId == alice.nodeId.string)
        #expect(fixture.engine.blobExchange.counts.progressSent == 2)
    }

    @Test func aReportIsTakenQuietlyFromItsOwnLinkAndNeverAsksForAKey() {
        // Before ADR 2026-10.nsr7's port, an unpinned sender's `blobprog` was a frame with no key: dropped, and its key
        // asked for, every two seconds of every file we fed it.
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        fixture.transport.clear()
        let report = BlobProgressContent(hash: photoHash.string, held: 40_960, ms: 2000)
        fixture.deliver(bob.unsigned(.blobProgress, payload: report.encoded, id: "prog-1"), from: bob)
        #expect(fixture.engine.blobExchange.counts.progressTaken == 1)
        #expect(fixture.engine.dropped.isEmpty)
        #expect(fixture.transport.written.isEmpty, "no key request, and never relayed")
        let handed = FileProgress(from: bob.nodeId, hash: photoHash, held: 40_960, milliseconds: 2000)
        #expect(fixture.transport.progressReports == [handed], "the link feeding bob clocks its window by it")
        fixture.deliver(carol.unsigned(.blobProgress, payload: report.encoded, id: "prog-claimed"), from: bob)
        let negative = BlobProgressContent(hash: photoHash.string, held: -1, ms: 2000)
        fixture.deliver(bob.unsigned(.blobProgress, payload: negative.encoded, id: "prog-negative"), from: bob)
        fixture.deliver(bob.unsigned(.blobProgress, payload: [0xFF], id: "prog-bad"), from: bob)
        let notAHash = BlobProgressContent(hash: "not-a-hash", held: 1, ms: 1)
        fixture.deliver(bob.unsigned(.blobProgress, payload: notAHash.encoded, id: "prog-not-a-hash"), from: bob)
        #expect(fixture.engine.blobExchange.counts.progressTaken == 2, "not another sender's claim, nor a count that cannot be")
        #expect(fixture.transport.progressReports.count == 1, "a key that is no hash names no file we feed")
        #expect(fixture.engine.dropped[.undecodable] == 1)
        #expect(fixture.transport.written.isEmpty)
    }

    // MARK: Asking

    @Test func aBlobThatStartsArrivingIsNotSteppedWhenItsTimerComes() {
        let fixture = EngineFixture(alice)
        fixture.link(bob, carol)
        fixture.engine.wantBlob(photoHash, author: bob.nodeId, via: nil, asker: nil)
        fixture.transport.clear()
        fixture.transport.arrivingFileKeys = [photoHash]
        fixture.advance(BlobExchange.firstAskGraceMilliseconds)
        #expect(fixture.transport.written(.blobRequest).isEmpty, "its bytes are coming, so the round does not widen")
    }

    @Test func theAskerQueriesFirstThenFetchesFromTheHolderThatSaysSo() throws {
        let fixture = EngineFixture(alice, configuration: MeshConfiguration(queriesBlobHolders: true))
        fixture.link(bob, carol, capabilities: Capabilities.local.union(.blobHave))
        fixture.transport.clear()
        fixture.engine.wantBlob(photoHash, author: nil, via: nil, asker: nil)
        let queries = fixture.transport.written(.blobHave)
        #expect(queries.map(\.to) == [bob.nodeId, carol.nodeId])
        #expect(try queries.map { try BlobHaveContent(decoding: $0.envelope.payload).hashes } == [[photoHash.string], [photoHash.string]])
        #expect(queries.allSatisfy { !$0.wire.relay && $0.wire.sig.isEmpty })
        #expect(fixture.transport.written(.blobRequest).isEmpty, "nobody is asked until the answers are in")
        let toCarol = try #require(queries.last?.envelope.id)
        let toBob = try #require(queries.first?.envelope.id)
        fixture.clock.advance(250)
        fixture.deliver(carol.blobHas([BlobHasItem(hash: photoHash.string, state: .have, size: 41)], re: toCarol), from: carol)
        #expect(fixture.transport.written(.blobRequest).isEmpty, "bob's answer is still due")
        fixture.deliver(bob.blobHas([BlobHasItem(hash: photoHash.string, state: .notHeld)], re: toBob), from: bob)
        #expect(fixture.transport.written(.blobRequest).map(\.to) == [carol.nodeId])
        let shown = "\(photoHash.string.prefix(8))"
        #expect(
            fixture.log.all.contains("debug mesh blob answer ← \(carol.nodeId) #\(toCarol.prefix(6)) in 250 ms: \(shown) HAVE 41B load=0"))
        // The grace gains the 250 ms carol's answer took: our own frames to her may be that far behind (knit-next #140).
        #expect(fixture.log.all.contains("debug mesh blob fetch \(shown)… → \(carol.nodeId) (link, load 0), grace 5250 ms"))
        fixture.advance(BlobExchange.firstAskGraceMilliseconds)
        #expect(fixture.transport.written(.blobHave).count == 2, "inside the stretched grace")
        fixture.advance(250)
        #expect(fixture.transport.written(.blobHave).last?.to == carol.nodeId, "the grace's own timer confirms")
        #expect(fixture.engine.blobExchange.counts == BlobCounts(queriesSent: 3, answersTaken: 2, fetches: 1, confirms: 1))
    }

    @Test func anAskWhoseLinkGoesAsksTheNextHolderAtOnce() throws {
        // knit-next #140: an ask stands on a live link until its floor, so a link that goes must move it on itself.
        let fixture = EngineFixture(alice, configuration: MeshConfiguration(queriesBlobHolders: true))
        fixture.link(bob, carol, capabilities: Capabilities.local.union(.blobHave))
        fixture.transport.clear()
        fixture.engine.wantBlob(photoHash, author: nil, via: nil, asker: nil)
        let queries = fixture.transport.written(.blobHave)
        let toBob = try #require(queries.first?.envelope.id)
        let toCarol = try #require(queries.last?.envelope.id)
        fixture.deliver(bob.blobHas([BlobHasItem(hash: photoHash.string, state: .have)], re: toBob), from: bob)
        fixture.deliver(carol.blobHas([BlobHasItem(hash: photoHash.string, state: .have)], re: toCarol, load: 1), from: carol)
        #expect(fixture.transport.written(.blobRequest).map(\.to) == [bob.nodeId])
        fixture.unlink(bob)
        #expect(fixture.transport.written(.blobRequest).map(\.to) == [bob.nodeId, carol.nodeId], "no timer waited on")
        #expect(fixture.log.all.contains("debug mesh blob fallback \(photoHash.string.prefix(8))… \(bob.nodeId) (link gone) → next"))
    }

    @Test func anAnswerNamingNoQueryIsStillTakenFromANeighbourQueriedThisCycle() {
        let fixture = EngineFixture(alice, configuration: MeshConfiguration(queriesBlobHolders: true))
        fixture.link(bob, capabilities: Capabilities.local.union(.blobHave))
        fixture.engine.wantBlob(photoHash, author: nil, via: nil, asker: nil)
        fixture.transport.clear()
        fixture.deliver(bob.blobHas([BlobHasItem(hash: photoHash.string, state: .have, size: 41)], re: nil), from: bob)
        #expect(fixture.transport.written(.blobRequest).map(\.to) == [bob.nodeId])
        #expect(fixture.log.all.contains("debug mesh blob answer ← \(bob.nodeId): \(photoHash.string.prefix(8)) HAVE 41B load=0"))
    }

    @Test func aNeighbourThatCannotAnswerIsAskedBlindAndNeverQueried() {
        let fixture = EngineFixture(alice, configuration: MeshConfiguration(queriesBlobHolders: true))
        fixture.link(bob)
        fixture.transport.clear()
        fixture.engine.wantBlob(photoHash, author: nil, via: nil, asker: nil)
        #expect(fixture.transport.written(.blobHave).isEmpty)
        #expect(fixture.transport.written(.blobRequest).map(\.to) == [bob.nodeId])
    }

    @Test func aChatsPhotoIsAskedOfItsAuthorFirstThenOfTheHopItCameFrom() throws {
        let fixture = EngineFixture(alice)
        let dave = TestPeer(seed: 4)
        fixture.link(bob, dave)
        try fixture.pin(carol)
        fixture.transport.clear()
        let post = ChatContent(body: "", attachmentHash: photoHash.string, attachmentMime: "image/png")
        let envelope = RelayEnvelope(
            type: .chat, id: "post-1", senderId: carol.nodeId.string, sentAt: EngineFixture.start, payload: post.encoded)
        fixture.deliver(try carol.signed(envelope), from: dave)
        #expect(fixture.transport.written(.blobRequest).map(\.to) == [dave.nodeId], "the author is not linked, so the hop")
        #expect(fixture.engine.blobExchange.wants[photoHash]?.author == carol.nodeId)
    }
}

extension TestPeer {
    /// An unsigned, point-to-point frame of `type` carrying `payload` as it stands.
    func unsigned(_ type: FrameType, payload: [UInt8], id: String) -> TestFrame {
        let envelope = RelayEnvelope(type: type, id: id, senderId: nodeId.string, payload: payload)
        return TestFrame(wire: WireEnvelope(relay: false, sig: [], signed: envelope.encoded), envelope: envelope)
    }

    /// An unsigned holder query, as Android builds one (`BlobExchange.holderQueryFrame`).
    func blobHave(_ hashes: [String], id: String, relay: Bool = false) -> TestFrame {
        let envelope = RelayEnvelope(type: .blobHave, id: id, senderId: nodeId.string, payload: BlobHaveContent(hashes: hashes).encoded)
        return TestFrame(wire: WireEnvelope(relay: relay, sig: [], signed: envelope.encoded), envelope: envelope)
    }

    /// An unsigned answer to a holder query (`BlobExchange.holderAnswerFrame`).
    func blobHas(_ items: [BlobHasItem], re: String?, load: Int? = nil) -> TestFrame {
        let content = BlobHasContent(items: items, load: load, re: re)
        let envelope = RelayEnvelope(type: .blobHas, id: "has-\(re ?? "none")", senderId: nodeId.string, payload: content.encoded)
        return TestFrame(wire: WireEnvelope(relay: false, sig: [], signed: envelope.encoded), envelope: envelope)
    }
}
