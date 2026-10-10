import KnitCrypto
import KnitStore
import KnitWire
import Testing

@testable import KnitMesh

/// A holder feeds one copy of a blob at a time, parks the other asks, serves them members first, and says when a
/// parked asker's copy should land (knit-next ADR 2026-10.g24x's `e2191bb9`, ADR 2026-10.nsr7's `79f38d3d` and
/// `3890f16b`): `BlobHolderQueryTest`'s park cases in knit-next.
@Suite struct MeshEngineBlobParkTests {
    private let alice = TestPeer(seed: 1)
    private let bob = TestPeer(seed: 2)
    private let carol = TestPeer(seed: 3)
    private let dave = TestPeer(seed: 4)

    private let photo: [UInt8] = Array("not really a jpeg, but bytes all the same".utf8)
    private var photoHash: BlobHash { BlobHash(of: photo) }
    private var shown: Substring { photoHash.string.prefix(BlobExchange.shownHashCharacters) }
    private let android = Capabilities.local.union(.blobHave)

    /// Alice holds the photo, linked to `peers`, and feeds it to bob live with `eta` ms to go.
    private func feeding(_ peers: TestPeer..., eta: Int64 = 20_000) -> EngineFixture {
        let fixture = EngineFixture(alice)
        fixture.stores.blobs.insert(photo, hash: photoHash, mime: "image/png", storedAt: EngineFixture.start)
        for peer in [bob] + peers {
            fixture.link(peer, capabilities: android)
        }
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: "breq-bob"), from: bob)
        fixture.transport.feeds = [FedCopy(photoHash, bob.nodeId, FeedReading(etaMilliseconds: eta, live: true, recheckMilliseconds: 5000))]
        fixture.transport.feedingLoad = 1
        fixture.transport.clear()
        return fixture
    }

    private func ask(_ fixture: EngineFixture, from peer: TestPeer, _ id: String) {
        fixture.deliver(peer.blobRequest(for: photoHash.string, id: id), from: peer)
    }

    private func served(_ fixture: EngineFixture) -> [NodeId] {
        fixture.transport.files.map(\.to)
    }

    private func lines(_ fixture: EngineFixture, _ word: String) -> [String] {
        fixture.log.all.filter { $0.contains("mesh blob \(word) ") }
    }

    /// The photo carried by a message in a group of `members` and alice.
    private func inGroup(_ fixture: EngineFixture, _ members: TestPeer...) {
        let roster = ([alice] + members).map(\.nodeId.string)
        let group = GroupRecord(
            id: GroupId.derive(roster),
            name: "",
            createdBy: alice.nodeId.string,
            createdAt: 10,
            nameUpdatedAt: 0,
            roster: roster.map { GroupMember(nodeId: $0) }
        )
        fixture.stores.groups.save(group)
        fixture.stores.messages.save(
            MessageRecord(
                id: "m-1",
                senderId: alice.nodeId,
                recipientId: nil,
                conversationId: group.id,
                body: "",
                sentAt: 1,
                attachment: MessageAttachment(hash: photoHash)
            ))
    }

    @Test func aSecondAskWhileACopyIsFedIsParkedAndServedWhenThatFeedEnds() {
        let fixture = feeding(carol)
        ask(fixture, from: carol, "breq-1")
        ask(fixture, from: carol, "breq-2")
        #expect(served(fixture).isEmpty, "no side-by-side copy on one budget")
        #expect(
            lines(fixture, "park") == ["debug mesh blob park \(shown)… for \(carol.nodeId) behind a feed"], "a re-ask only refreshes it")
        #expect(fixture.engine.blobExchange.counts.asksParked == 1)
        #expect(
            fixture.log.all.contains("debug mesh blobreq \(LinkManager.shown(photoHash.string)) from \(carol.nodeId): parked behind a feed")
        )
        fixture.engine.fileFeedsChanged()
        #expect(served(fixture).isEmpty, "still live")
        fixture.transport.feeds = []
        fixture.engine.fileFeedsChanged()
        #expect(served(fixture) == [carol.nodeId], "served on the feed's end")
        #expect(lines(fixture, "unpark").count == 1)
        #expect(!fixture.engine.blobExchange.hasParked)
    }

    @Test func thePollServesAParkedAskOnceItsFeedStallsAndThenLetsItselfGo() {
        let fixture = feeding(carol)
        ask(fixture, from: carol, "breq-1")
        #expect(fixture.engine.blobExchange.parkPollAt == fixture.clock.monotonicMilliseconds() + BlobExchange.parkPollMilliseconds)
        fixture.advance(BlobExchange.parkPollMilliseconds)
        #expect(served(fixture).isEmpty)
        #expect(fixture.engine.blobExchange.parkPollAt == fixture.clock.monotonicMilliseconds() + 5000, "when the feed can next stall")
        fixture.transport.feeds = [FedCopy(photoHash, bob.nodeId, FeedReading(etaMilliseconds: 15_000, live: false))]
        fixture.advance(5000)
        #expect(served(fixture) == [carol.nodeId], "a stalled feed holds nobody")
        #expect(fixture.engine.blobExchange.parkPollAt == nil)
    }

    @Test func aSendingAnswerCarriesWhenTheAskersCopyShouldLand() throws {
        let fixture = feeding(carol)
        fixture.transport.inFlight = [(photoHash, bob.nodeId)]
        fixture.transport.feeds.append(FedCopy(photoHash, bob.nodeId, FeedReading(etaMilliseconds: 12_000, live: true)))
        fixture.deliver(bob.blobHave([photoHash.string], id: "q-bob"), from: bob)
        // Carol's copy of the 41 bytes would take 41 s at 1 B/s, so it waits behind bob's 20 s.
        fixture.transport.rates[carol.nodeId] = 1
        fixture.transport.feeds = [FedCopy(photoHash, bob.nodeId, FeedReading(etaMilliseconds: 20_000, live: true))]
        ask(fixture, from: carol, "breq-1")
        fixture.deliver(carol.blobHave([photoHash.string], id: "q-carol"), from: carol)
        let items = try fixture.transport.written(.blobHas).map { try BlobHasContent(decoding: $0.envelope.payload).items }
        let size = Int64(photo.count)
        #expect(
            items == [
                [BlobHasItem(hash: photoHash.string, state: .sending, size: size, eta: 12_000)],
                [BlobHasItem(hash: photoHash.string, state: .sending, size: size, eta: 20_000 + size * 1000)],
            ], "its own feed's ETA; parked, the feed ahead's end plus its own copy")
        let parked = try #require(fixture.engine.blobExchange.parked[photoHash]?[carol.nodeId])
        #expect(parked.keptUntil == fixture.clock.monotonicMilliseconds() + 20_000 + size * 1000 + BlobExchange.holdSlackMilliseconds)
    }

    @Test func membersGoFirstAndACarrierWaitsBehindAnyCopy() {
        let erin = TestPeer(seed: 5)
        let frank = TestPeer(seed: 6)
        let fixture = feeding(carol, dave, erin, frank)
        inGroup(fixture, carol, dave)
        fixture.transport.feeds = [FedCopy(photoHash, carol.nodeId, FeedReading(etaMilliseconds: 20_000, live: true))]
        ask(fixture, from: erin, "breq-1")
        ask(fixture, from: dave, "breq-2")
        #expect(served(fixture).isEmpty)
        #expect(lines(fixture, "park").contains("debug mesh blob park \(shown)… for \(erin.nodeId) behind a feed (carrier)"))
        fixture.transport.feeds = []
        fixture.engine.fileFeedsChanged()
        #expect(served(fixture) == [dave.nodeId], "the member first, one a pass")
        fixture.transport.feeds = [FedCopy(photoHash, dave.nodeId, FeedReading(etaMilliseconds: 20_000, live: true))]
        fixture.engine.fileFeedsChanged()
        #expect(served(fixture) == [dave.nodeId], "the carrier waits behind the member's copy")
        // A member goes beside a carrier's copy: that one is a spare.
        fixture.transport.feeds = [FedCopy(photoHash, frank.nodeId, FeedReading(etaMilliseconds: 20_000, live: true))]
        ask(fixture, from: carol, "breq-3")
        #expect(served(fixture) == [dave.nodeId, carol.nodeId])
        fixture.transport.feeds = []
        fixture.engine.fileFeedsChanged()
        #expect(served(fixture) == [dave.nodeId, carol.nodeId, erin.nodeId])
    }

    @Test func anAskWhoseOwnCopyWouldEndFirstGoesBesideOnlyWhenItSavesMoreThanItCosts() {
        let fixture = feeding(carol, dave)
        // 41 bytes at 41 B/s: one second, beside a feed 60 s from its end. Saves 59.5 s for 0.5 s of the feed's.
        fixture.transport.rates[carol.nodeId] = Int64(photo.count)
        fixture.transport.feeds = [FedCopy(photoHash, bob.nodeId, FeedReading(etaMilliseconds: 60_000, live: true))]
        ask(fixture, from: carol, "breq-1")
        #expect(served(fixture) == [carol.nodeId])
        #expect(
            lines(fixture, "beside") == [
                "debug mesh blob beside \(shown)… → \(carol.nodeId): its copy ~1000 ms, the feeds' 60000 ms; "
                    + "saves ~59500 ms for ~500 ms of theirs"
            ])
        // At 1 B/s its copy would take 41 s, behind a feed 30 s from its end: it waits.
        fixture.transport.rates[dave.nodeId] = 1
        fixture.transport.feeds = [FedCopy(photoHash, bob.nodeId, FeedReading(etaMilliseconds: 30_000, live: true))]
        ask(fixture, from: dave, "breq-2")
        #expect(served(fixture) == [carol.nodeId])
        #expect(fixture.engine.blobExchange.isParked(photoHash, for: dave.nodeId))
    }

    @Test func anAskBesideTwoFeedsMustSaveMoreThanItsSplitCostsThem() {
        // Two feeds 1.1 and 1.2 s out on a radio feeding two: a 1 s copy saves 1.2 − 1 × 2 ÷ 3 s for 1 × 2 ÷ 3 s.
        let fixture = feeding(carol, dave)
        fixture.transport.rates[carol.nodeId] = Int64(photo.count)
        fixture.transport.feedingLoad = 2
        fixture.transport.feeds = [
            FedCopy(photoHash, bob.nodeId, FeedReading(etaMilliseconds: 1100, live: true)),
            FedCopy(photoHash, dave.nodeId, FeedReading(etaMilliseconds: 1200, live: true)),
        ]
        ask(fixture, from: carol, "breq-1")
        #expect(served(fixture).isEmpty && lines(fixture, "beside").isEmpty)
    }

    @Test func aDMsTwoEndsAreItsMembersAndTheFasterThenTheOlderAskGoesFirst() {
        let erin = TestPeer(seed: 5)
        let fixture = feeding(carol, dave, erin)
        // Bob, whose copy is feeding, is a member too: a member goes beside a carrier's copy.
        inGroup(fixture, bob, carol, dave, erin)
        fixture.transport.feeds = [FedCopy(photoHash, bob.nodeId, FeedReading(etaMilliseconds: 20_000, live: true))]
        ask(fixture, from: carol, "breq-1")
        fixture.clock.advance(10)
        ask(fixture, from: dave, "breq-2")
        ask(fixture, from: erin, "breq-3")
        fixture.transport.rates[erin.nodeId] = 1
        fixture.transport.feeds = []
        fixture.engine.fileFeedsChanged()
        fixture.engine.fileFeedsChanged()
        fixture.engine.fileFeedsChanged()
        #expect(served(fixture) == [erin.nodeId, carol.nodeId, dave.nodeId], "the faster link, then the older ask")
        // A DM's addressees are its two ends.
        fixture.stores.messages.save(
            MessageRecord(
                id: "dm-1",
                senderId: carol.nodeId,
                recipientId: alice.nodeId,
                conversationId: carol.nodeId.string,
                body: "",
                sentAt: 0,
                attachment: MessageAttachment(hash: photoHash)
            ))
        #expect(fixture.engine.addressees(of: photoHash) == [carol.nodeId, alice.nodeId])
    }

    @Test func aWithdrawalOrAnUnlinkDropsAParkedAsk() {
        let fixture = feeding(carol, dave)
        ask(fixture, from: carol, "breq-1")
        ask(fixture, from: dave, "breq-2")
        fixture.deliver(carol.unsigned(.blobCancel, payload: BlobCancelContent(hash: photoHash.string).encoded, id: "c-1"), from: carol)
        #expect(fixture.log.all.contains("debug mesh blob cancel ← \(carol.nodeId) \(shown)…: parked ask dropped"))
        #expect(fixture.engine.blobExchange.counts.cancelsTaken == 1)
        fixture.unlink(dave)
        fixture.transport.feeds = []
        fixture.engine.fileFeedsChanged()
        #expect(served(fixture).isEmpty)
        #expect(!fixture.engine.blobExchange.hasParked)
    }

    @Test func aCopyOnTheLinkOrInsideTheMemoIsNeitherParkedNorSentTwice() {
        let fixture = feeding(carol)
        fixture.transport.inFlight = [(photoHash, carol.nodeId)]
        ask(fixture, from: carol, "breq-1")
        fixture.transport.inFlight = []
        fixture.deliver(bob.blobRequest(for: photoHash.string, id: "breq-again"), from: bob)
        #expect(served(fixture).isEmpty)
        #expect(!fixture.engine.blobExchange.hasParked, "carol's copy was on its link; bob's own copy is the feed")
        #expect(
            fixture.log.all.contains(
                "debug mesh blobreq \(LinkManager.shown(photoHash.string)) from \(bob.nodeId): served to it within the serve memo"))
    }
}
