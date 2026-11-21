import KnitCrypto
import KnitStore
import KnitTestSupport
import KnitWire
import Testing

@testable import KnitMesh

/// A file comes first, and endings come first (the `custody-carry-policy` contract, §2 and §3, revision 14), on one engine
/// whose transport a test sets.
@Suite struct MeshEngineCustodyFileFirstTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)
    private static let look = CustodyAnswers.roundCheckMilliseconds
    private static let photo = BlobHash(of: Array("a photo for bob".utf8))

    /// Alice's node linked to Bob, Carol's key pinned but no profile of hers in custody, which holds `others` DMs from
    /// Carol to Dave and `mine` DMs from Carol to Bob, and nothing written yet.
    private func fixture(others: Int = 20, mine: Int = 3) throws -> (EngineFixture, mail: Set<String>) {
        let fixture = EngineFixture(alice)
        try fixture.pin(carol)
        fixture.link(bob)
        let wall = fixture.clock.wallMilliseconds()
        for entry in fixture.stores.custody.liveIndex(now: wall) where entry.type == .profile && entry.senderId == carol.nodeId.string {
            fixture.stores.custody.remove(entry.id)
        }
        var mail: Set<String> = []
        for index in 0..<(others + mine) {
            let to = index < others ? dave : bob
            let dm = try carol.directMessage("x", to: to, id: frameIdOf("ff-\(index)"), sentAt: wall - 1000 + Int64(index))
            fixture.stores.custody.store(
                CarriedFrame(envelope: dm.envelope, sig: dm.wire.sig, signed: dm.wire.signed), origin: .relayed, now: wall)
            if to == bob {
                mail.insert(dm.envelope.id)
            }
        }
        fixture.transport.clear()
        return (fixture, mail)
    }

    /// What the rounds wrote to Bob: fresh frames, the router's relays left out.
    private func rounds(_ fixture: EngineFixture) -> [Written] {
        fixture.transport.written.filter { $0.to == bob.nodeId && $0.wire.hops == 0 }
    }

    /// Whether every round write to Bob is mail for him or a key ahead of it, and some mail went.
    private func onlyMailAndKeys(_ fixture: EngineFixture, mail: Set<String>) -> Bool {
        let written = rounds(fixture)
        let keys = written.filter { $0.envelope.type == .profile && !$0.wire.relay }
        let frames = written.filter { !($0.envelope.type == .profile && !$0.wire.relay) }
        return !frames.isEmpty && frames.allSatisfy { mail.contains($0.envelope.id) }
            && keys.allSatisfy { $0.envelope.senderId == carol.nodeId.string }
    }

    @Test func whileAFileStreamsToThePeerARoundCarriesOnlyItsMailAndTheirKeys() throws {
        let (fixture, mail) = try fixture()
        fixture.engine.custodyAnswers.noteFileOut(Self.photo, to: bob.nodeId)
        fixture.transport.inFlight.append((Self.photo, bob.nodeId))
        fixture.engine.receiveDigest([], from: bob.nodeId)
        for _ in 0..<5 {
            fixture.advance(Self.look)
        }
        #expect(onlyMailAndKeys(fixture, mail: mail), "\(rounds(fixture).map(\.envelope.type.rawValue))")
        #expect(Set(rounds(fixture).map(\.envelope.id)).isSuperset(of: mail), "all of it")
        #expect(rounds(fixture).contains { $0.envelope.type == .profile }, "with Carol's key ahead")
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) != nil, "the rest waits for the file, the answer open")
    }

    @Test func whileAFileArrivesFromThePeerARoundCarriesOnlyItsMailAndTheirKeys() throws {
        let (fixture, mail) = try fixture()
        fixture.transport.arrivingFrom = [bob.nodeId]
        fixture.engine.receiveDigest([], from: bob.nodeId)
        for _ in 0..<5 {
            fixture.advance(Self.look)
        }
        #expect(onlyMailAndKeys(fixture, mail: mail))
    }

    @Test func aFileQueuedBehindAMovingOneHoldsTheOtherTiersAndBehindAStalledOneDoesNot() throws {
        let (fixture, mail) = try fixture()
        let queued = BlobHash(of: Array("queued behind".utf8))
        for hash in [Self.photo, queued] {
            fixture.engine.custodyAnswers.noteFileOut(hash, to: bob.nodeId)
            fixture.transport.inFlight.append((hash, bob.nodeId))
        }
        fixture.transport.feedStalls[Self.photo] = false
        #expect(fixture.engine.fileOnLink(with: bob.nodeId), "streaming, and a copy queued behind it")
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.advance(Self.look)
        #expect(onlyMailAndKeys(fixture, mail: mail))
        fixture.transport.feedStalls[Self.photo] = true
        #expect(!fixture.engine.fileOnLink(with: bob.nodeId), "nothing behind a stalled stream moves either")
    }

    @Test func afterTheFileEndsTheOtherTiersResume() throws {
        let (fixture, mail) = try fixture()
        fixture.engine.custodyAnswers.noteFileOut(Self.photo, to: bob.nodeId)
        fixture.transport.inFlight.append((Self.photo, bob.nodeId))
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.advance(Self.look)
        fixture.transport.inFlight.removeAll()
        for _ in 0..<5 {
            fixture.advance(Self.look)
        }
        let others = rounds(fixture).filter { $0.envelope.type == .chat && !mail.contains($0.envelope.id) }
        #expect(others.count == 20, "every other frame once the file ended")
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) == nil, "and the answer ended with nothing left")
    }

    @Test func aLinkThatNeverDrainsEndsItsAnswerAtTwoMinutesAndStopsLooking() throws {
        let (fixture, _) = try fixture()
        fixture.transport.unwritten[bob.nodeId] = CustodySync.roundBytes
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(fixture.engine.custodyLookDeadline != nil)
        for _ in 0..<1199 {
            fixture.advance(Self.look)
        }
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) != nil)
        fixture.advance(Self.look)
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) == nil, "ended by age, the link never drained")
        #expect(fixture.engine.custodyRoundCounts.custodyAnswersCutShort == 1)
        #expect(fixture.engine.custodyLookDeadline == nil, "and nothing more to look for")
    }

    @Test func aRoundNeverCreditedWithinTwoMinutesCreditsNothingAndTheLookStops() throws {
        let (fixture, _) = try fixture()
        fixture.engine.receiveDigest([], from: bob.nodeId)
        let first = Set(rounds(fixture).map(\.envelope.id))
        #expect(!first.isEmpty)
        fixture.transport.unwritten[bob.nodeId] = CustodySync.roundBytes
        for _ in 0..<1200 {
            fixture.advance(Self.look)
        }
        #expect(fixture.engine.custody.ledger.creditsWaiting.isEmpty, "the uncredited round expired")
        #expect(fixture.engine.custodyLookDeadline == nil)
        fixture.transport.unwritten[bob.nodeId] = 0
        fixture.advance(Self.look)
        #expect(first.allSatisfy { fixture.engine.custody.ledger.spread(of: $0) == 0 }, "a later drain credits nothing")
    }

    @Test func aFileHandedTheLinkCountsUntilTheLinkNoLongerCarriesIt() {
        let fixture = EngineFixture(alice)
        fixture.link(bob)
        #expect(!fixture.engine.fileOnLink(with: bob.nodeId))
        fixture.engine.custodyAnswers.noteFileOut(Self.photo, to: bob.nodeId)
        #expect(!fixture.engine.fileOnLink(with: bob.nodeId), "a file the link no longer carries is forgotten")
        fixture.engine.custodyAnswers.noteFileOut(Self.photo, to: bob.nodeId)
        fixture.transport.inFlight.append((Self.photo, bob.nodeId))
        #expect(fixture.engine.fileOnLink(with: bob.nodeId))
        fixture.unlink(bob)
        #expect(!fixture.engine.fileOnLink(with: bob.nodeId), "forgotten with the link")
    }

    @Test func ourPhotoPushedToThePeerMakesTheNextRoundItsMailAlone() throws {
        let (fixture, mail) = try fixture()
        let jpeg = Array("our photo, in spirit".utf8)
        fixture.engine.setAvatar(jpeg)
        let hash = BlobHash(of: jpeg)
        #expect(fixture.transport.files.contains { $0.hash == hash && $0.to == bob.nodeId }, "pushed through the transport")
        fixture.transport.inFlight.append((hash, bob.nodeId))
        fixture.transport.clear()
        fixture.engine.receiveDigest([], from: bob.nodeId)
        #expect(onlyMailAndKeys(fixture, mail: mail), "\(rounds(fixture).map(\.envelope.type.rawValue))")
    }

    // MARK: Only a file that is moving comes first (revision 16)

    @Test func aStreamStalledFifteenSecondsFreesTheOtherTiersAndProgressHoldsThemAgain() throws {
        let (fixture, mail) = try fixture(others: 40)
        fixture.engine.custodyAnswers.noteFileOut(Self.photo, to: bob.nodeId)
        fixture.transport.inFlight.append((Self.photo, bob.nodeId))
        fixture.transport.feedStalls[Self.photo] = false
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.advance(Self.look)
        #expect(onlyMailAndKeys(fixture, mail: mail), "a moving file: the peer's mail alone")
        #expect(Set(rounds(fixture).map(\.envelope.id)).isSuperset(of: mail), "tier 2 throughout")
        // 15 s with no progress, the blob plane's stall: the other tiers go at the next look.
        fixture.transport.feedStalls[Self.photo] = true
        fixture.transport.unwritten[bob.nodeId] = 0
        let before = rounds(fixture).count
        fixture.advance(Self.look)
        let freed = rounds(fixture).dropFirst(before).filter { $0.envelope.type == .chat }
        #expect(!freed.isEmpty && freed.allSatisfy { !mail.contains($0.envelope.id) }, "the others go at the next look")
        // Progress resumes: they wait again.
        fixture.transport.feedStalls[Self.photo] = false
        let resumed = rounds(fixture).count
        for _ in 0..<5 {
            fixture.advance(Self.look)
        }
        #expect(rounds(fixture).count == resumed, "held again behind the moving file")
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) != nil)
    }

    @Test func behindAMovingFileWithNoMailALookReadsNoIndex() throws {
        let failable = FailableStores()
        let fixture = EngineFixture(alice, stores: failable.stores)
        try fixture.pin(carol)
        fixture.link(bob)
        let wall = fixture.clock.wallMilliseconds()
        for index in 0..<10 {
            let dm = try carol.directMessage("x", to: dave, id: frameIdOf("idle-\(index)"), sentAt: wall)
            fixture.stores.custody.store(
                CarriedFrame(envelope: dm.envelope, sig: dm.wire.sig, signed: dm.wire.signed), origin: .relayed, now: wall)
        }
        fixture.engine.custodyAnswers.noteFileOut(Self.photo, to: bob.nodeId)
        fixture.transport.inFlight.append((Self.photo, bob.nodeId))
        fixture.engine.receiveDigest([], from: bob.nodeId)
        let reads = failable.custody.indexReads
        for _ in 0..<20 {
            fixture.advance(Self.look)
        }
        #expect(failable.custody.indexReads == reads, "the empty file-first round is not cut again")
        // Mail for the peer wakes it.
        let mail = try carol.directMessage("for bob", to: bob, id: frameIdOf("wake"), sentAt: wall)
        fixture.deliver(mail, from: carol)
        fixture.advance(Self.look)
        #expect(rounds(fixture).contains { $0.envelope.id == mail.envelope.id })
    }

    @Test func anInboundStreamStalledFreesTheOtherTiersAndProgressHoldsThemAgain() throws {
        let (fixture, mail) = try fixture(others: 40)
        fixture.transport.arrivingFrom.insert(bob.nodeId)
        fixture.engine.receiveDigest([], from: bob.nodeId)
        fixture.advance(Self.look)
        #expect(onlyMailAndKeys(fixture, mail: mail), "a moving stream from the peer: its mail alone")
        #expect(Set(rounds(fixture).map(\.envelope.id)).isSuperset(of: mail), "tier 2 throughout")
        // Still arriving, but stalled: the other tiers go at the next look.
        fixture.transport.stalledFrom.insert(bob.nodeId)
        fixture.transport.unwritten[bob.nodeId] = 0
        let before = rounds(fixture).count
        fixture.advance(Self.look)
        let freed = rounds(fixture).dropFirst(before).filter { $0.envelope.type == .chat }
        #expect(!freed.isEmpty && freed.allSatisfy { !mail.contains($0.envelope.id) }, "the others go at the next look")
        // It moves again: they wait.
        fixture.transport.stalledFrom.remove(bob.nodeId)
        let resumed = rounds(fixture).count
        for _ in 0..<5 {
            fixture.advance(Self.look)
        }
        #expect(rounds(fixture).count == resumed, "held again behind the moving stream")
        #expect(fixture.engine.custodyAnswers.answer(for: bob.nodeId) != nil)
    }

    @Test func aFeedPastItsDeadlineThatStillMovesKeepsComingFirstUntilItStalls() throws {
        let (fixture, mail) = try fixture(others: 40)
        fixture.engine.custodyAnswers.noteFileOut(Self.photo, to: bob.nodeId)
        fixture.transport.inFlight.append((Self.photo, bob.nodeId))
        // Past its deadline, so its reading is not live, but reports still move it: `FeedMeter`'s stall alone (revision 18).
        fixture.transport.feeds = [FedCopy(Self.photo, bob.nodeId, FeedReading(etaMilliseconds: nil, live: false))]
        fixture.transport.feedStalls[Self.photo] = false
        fixture.engine.receiveDigest([], from: bob.nodeId)
        for _ in 0..<5 {
            fixture.advance(Self.look)
            fixture.transport.unwritten[bob.nodeId] = 0
        }
        #expect(onlyMailAndKeys(fixture, mail: mail), "late but moving: the peer's mail alone")
        #expect(Set(rounds(fixture).map(\.envelope.id)).isSuperset(of: mail))
        // 15 s with no progress: the other tiers go at the next look.
        fixture.transport.feedStalls[Self.photo] = true
        let before = rounds(fixture).count
        fixture.advance(Self.look)
        let freed = rounds(fixture).dropFirst(before).filter { $0.envelope.type == .chat }
        #expect(!freed.isEmpty && freed.allSatisfy { !mail.contains($0.envelope.id) }, "stalled: the others go")
    }
}
