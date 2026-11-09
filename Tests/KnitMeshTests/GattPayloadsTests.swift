import KnitCrypto
import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// Whose GATT payload a radio reads and when: once per address, one at a time, and again only after a wait or a
/// failed dial (ADR 2026-09.xzpt).
@Suite struct GattPayloadsTests {
    /// A ``GattPayloads`` behind a reference, so `#expect` can check what a mutating call answers.
    private final class Reads {
        var state: GattPayloads

        init(
            _ configuration: GattPayloads.Configuration = GattPayloads.Configuration(
                readTimeoutMilliseconds: 100, retryMilliseconds: 1000, strangerRetryMilliseconds: 5000)
        ) {
            state = GattPayloads(configuration: configuration)
        }

        func begin(_ address: RadioAddress, now: Int64) -> Bool {
            state.begin(address, now: now)
        }

        func helloNamed(_ node: NodeId, told: NodeId? = nil, announced: NodeId? = nil, at address: RadioAddress) -> Bool {
            state.helloNamed(node, told: told, announced: announced, at: address)
        }

        func forgetPastEdge(wall: Int64, linked: Set<RadioAddress> = []) -> [RadioAddress] {
            state.forgetPastEdge(wall: wall, linked: linked)
        }

        func forgetQuiet(now: Int64, linked: Set<RadioAddress>) -> [RadioAddress] {
            state.forgetQuiet(now: now, linked: linked)
        }

        func noReply(at address: RadioAddress) -> Bool {
            state.noReply(at: address)
        }
    }

    private static let phone = RadioAddress("phone")
    private static let other = RadioAddress("other")
    private static let payload = AdvertPayload(capabilities: 0xFFF, nodeId: fixtureNodeId(2), digestCue: 0, psm: 0x81)

    @Test func knitNextsConnectWatchdogBoundsARead() {
        let defaults = GattPayloads.Configuration()
        #expect(defaults.readTimeoutMilliseconds == 12_000)
        #expect(defaults.retryMilliseconds == 30_000)
        #expect(defaults.strangerRetryMilliseconds == 600_000)
        #expect(defaults.quietMilliseconds == 60_000, "the payload lifetime's rule 3, shared with knit-next")
    }

    // MARK: The payload's lifetime

    private func read(_ reads: Reads, _ address: RadioAddress, _ payload: AdvertPayload = Self.payload, now: Int64) {
        #expect(reads.begin(address, now: now))
        reads.state.finish(address, .read(payload), now: now, wall: 0)
    }

    // MARK: Rule 5, the seal's forget-once (the `link-seal` contract, §7, revisions 1 and 2)

    private static let sealing = AdvertPayload(
        capabilities: 0xFFF, nodeId: fixtureNodeId(2), digestCue: 0, psm: 0x81, flags: AdvertPayload.linkSealFlag)

    @Test func aPlainDialWithNoReplyForgetsAnUnflaggedPayloadOnce() {
        let reads = Reads()
        read(reads, Self.phone, now: 0)
        #expect(reads.noReply(at: Self.phone))
        #expect(reads.state.payload(of: Self.phone) == nil)
        #expect(reads.begin(Self.phone, now: 10), "read again at its next advert")
        reads.state.finish(Self.phone, .read(Self.payload), now: 10, wall: 0)
        #expect(!reads.noReply(at: Self.phone), "still unflagged: kept, once is enough")
        #expect(reads.state.payload(of: Self.phone) == Self.payload)
        #expect(!reads.noReply(at: Self.other), "nothing read there")
    }

    @Test func aFlaggedPayloadIsNeverForgottenForANoReply() {
        let reads = Reads()
        read(reads, Self.phone, Self.sealing, now: 0)
        #expect(!reads.noReply(at: Self.phone), "revision 2: a no-reply says nothing of the flag")
        #expect(reads.state.payload(of: Self.phone) == Self.sealing)
    }

    @Test func theMarkClearsWhenAReadFindsTheFlagOrAnotherRuleForgets() {
        let reads = Reads()
        read(reads, Self.phone, now: 0)
        #expect(reads.noReply(at: Self.phone))
        read(reads, Self.phone, Self.sealing, now: 10)
        reads.state.forget(Self.phone)
        read(reads, Self.phone, now: 20)
        #expect(reads.noReply(at: Self.phone), "the flag was read, so the mark went")
        read(reads, Self.phone, now: 30)
        reads.state.forget(Self.phone)
        read(reads, Self.phone, now: 40)
        #expect(reads.noReply(at: Self.phone), "another rule forgot the address, so the mark went")
    }

    @Test func aHelloNamingAnotherNodeForgetsThePayloadAndTheSameNodeKeepsIt() {
        let reads = Reads()
        read(reads, Self.phone, now: 0)
        #expect(!reads.helloNamed(Self.payload.advertised, at: Self.phone))
        #expect(!reads.helloNamed(fixtureNodeId(3), at: Self.other), "nothing read there")
        #expect(reads.state.payload(of: Self.phone) == Self.payload)
        #expect(reads.helloNamed(fixtureNodeId(3), at: Self.phone))
        #expect(reads.state.payload(of: Self.phone) == nil)
        #expect(reads.begin(Self.phone, now: 10), "read again at its next advert")
    }

    @Test func anAddressQuietForAMinuteOfScanningIsForgotten() {
        let reads = Reads()
        reads.state.scanStarted(now: 0)
        read(reads, Self.phone, now: 0)
        reads.state.heard(Self.phone, now: 0)
        #expect(reads.forgetQuiet(now: 59_999, linked: []).isEmpty)
        reads.state.heard(Self.phone, now: 30_000)
        #expect(reads.forgetQuiet(now: 89_999, linked: []).isEmpty, "heard again at 30 s")
        #expect(reads.forgetQuiet(now: 90_000, linked: []) == [Self.phone])
        #expect(reads.state.payload(of: Self.phone) == nil)
        #expect(reads.forgetQuiet(now: 200_000, linked: []).isEmpty, "forgotten once")
    }

    @Test func addressesQuietTogetherAreForgottenInOrder() {
        let reads = Reads()
        reads.state.scanStarted(now: 0)
        read(reads, Self.phone, now: 0)
        read(reads, Self.other, now: 0)
        #expect(reads.forgetQuiet(now: 60_000, linked: []) == [Self.other, Self.phone])
    }

    @Test func onlyTimeTheScanRunsCounts() {
        let reads = Reads()
        reads.state.scanStarted(now: 0)
        read(reads, Self.phone, now: 0)
        reads.state.heard(Self.phone, now: 0)
        reads.state.scanStopped(now: 40_000)
        #expect(reads.state.scanTime(now: 500_000) == 40_000)
        #expect(reads.forgetQuiet(now: 500_000, linked: []).isEmpty, "a stopped scan hears nothing, so proves nothing")
        reads.state.scanStarted(now: 500_000)
        reads.state.scanStarted(now: 505_000)
        #expect(reads.forgetQuiet(now: 519_999, linked: []).isEmpty)
        #expect(reads.forgetQuiet(now: 520_000, linked: []) == [Self.phone], "40 s before the stop and 20 s after")
    }

    @Test func aLinkedAddressIsNeverQuietAndItsMinuteStartsWhenTheLinkEnds() {
        let reads = Reads()
        reads.state.scanStarted(now: 0)
        read(reads, Self.phone, now: 0)
        reads.state.heard(Self.phone, now: 0)
        #expect(reads.forgetQuiet(now: 300_000, linked: [Self.phone]).isEmpty)
        #expect(reads.state.payload(of: Self.phone) == Self.payload)
        #expect(reads.forgetQuiet(now: 359_999, linked: []).isEmpty)
        #expect(reads.forgetQuiet(now: 360_000, linked: []) == [Self.phone])
    }

    @Test func aQuietStrangerKeepsItsWait() {
        let reads = Reads(GattPayloads.Configuration())
        reads.state.scanStarted(now: 0)
        #expect(reads.begin(Self.phone, now: 0))
        reads.state.finish(Self.phone, .stranger, now: 0, wall: 0)
        reads.state.heard(Self.phone, now: 0)
        #expect(reads.forgetQuiet(now: 60_000, linked: []).isEmpty, "no payload to forget")
        #expect(!reads.begin(Self.phone, now: 60_000), "its ten minutes stand")
    }

    @Test func theReadThatFoundThePayloadCountsAsHearingIt() {
        let reads = Reads()
        reads.state.scanStarted(now: 0)
        reads.state.heard(Self.phone, now: 0)
        #expect(reads.begin(Self.phone, now: 0))
        reads.state.finish(Self.phone, .read(Self.payload), now: 10_000, wall: 0)
        #expect(reads.forgetQuiet(now: 69_999, linked: []).isEmpty)
        #expect(reads.forgetQuiet(now: 70_000, linked: []) == [Self.phone])
    }

    @Test func anAddressIsReadOnceAndWhatItServedIsKept() {
        let reads = Reads()
        #expect(reads.state.payload(of: Self.phone) == nil)
        #expect(reads.begin(Self.phone, now: 0))
        #expect(reads.state.current?.address == Self.phone)
        #expect(reads.state.current?.deadline == 100)
        reads.state.finish(Self.phone, .read(Self.payload), now: 40, wall: 0)
        #expect(reads.state.current == nil)
        #expect(reads.state.payload(of: Self.phone) == Self.payload)
        #expect(!reads.begin(Self.phone, now: 50), "read once")
    }

    @Test func oneReadRunsAtATime() {
        let reads = Reads()
        #expect(reads.begin(Self.phone, now: 0))
        #expect(!reads.begin(Self.other, now: 10))
        reads.state.finish(Self.phone, .failed, now: 20, wall: 0)
        #expect(reads.begin(Self.other, now: 30))
    }

    @Test func aFailedReadWaitsItsRetryAndAStrangerWaitsLonger() {
        let reads = Reads()
        #expect(reads.begin(Self.phone, now: 0))
        reads.state.finish(Self.phone, .failed, now: 0, wall: 0)
        #expect(!reads.begin(Self.phone, now: 999))
        #expect(reads.begin(Self.phone, now: 1000))
        reads.state.finish(Self.phone, .stranger, now: 1000, wall: 0)
        #expect(!reads.begin(Self.phone, now: 5999))
        #expect(reads.begin(Self.phone, now: 6000))
        #expect(reads.state.payload(of: Self.phone) == nil)
    }

    @Test func anOutcomeForAReadGivenUpOnIsIgnored() {
        let reads = Reads()
        #expect(reads.begin(Self.phone, now: 0))
        reads.state.finish(Self.other, .read(Self.payload), now: 10, wall: 0)
        #expect(reads.state.current?.address == Self.phone)
        #expect(reads.state.payload(of: Self.other) == nil)
    }

    @Test func aCancelledReadLeavesNoWait() {
        let reads = Reads()
        #expect(reads.begin(Self.phone, now: 0))
        reads.state.cancel()
        #expect(reads.state.current == nil)
        #expect(reads.begin(Self.phone, now: 1))
    }

    @Test func aForgottenAddressIsReadAgainAtOnce() {
        let reads = Reads()
        #expect(reads.begin(Self.phone, now: 0))
        reads.state.finish(Self.phone, .read(Self.payload), now: 0, wall: 0)
        reads.state.forget(Self.phone)
        #expect(reads.state.payload(of: Self.phone) == nil)
        #expect(reads.begin(Self.phone, now: 1))
        reads.state.finish(Self.phone, .stranger, now: 1, wall: 0)
        reads.state.forget(Self.phone)
        #expect(reads.begin(Self.phone, now: 2), "forgetting ends the wait too")
    }

    @Test func forgettingTheAddressBeingReadLetsTheReadRunOn() {
        let reads = Reads()
        #expect(reads.begin(Self.phone, now: 0))
        reads.state.forget(Self.phone)
        #expect(reads.state.current?.address == Self.phone)
        reads.state.finish(Self.phone, .read(Self.payload), now: 5, wall: 0)
        #expect(reads.state.payload(of: Self.phone) == Self.payload)
    }

    // MARK: A blinded payload (ADR 2026-11.prsp)

    private static let tag = AdvertForm.tag(prefixing: 7, 7)
    private static let nextTag = AdvertForm.tag(prefixing: 8, 8)
    private static let blinded = AdvertPayload(
        capabilities: 0xFFF,
        advertised: tag,
        digestCue: 0,
        psm: 0x81,
        flags: AdvertPayload.writtenFlags(dialsGattPeers: true, blinded: true, seals: false)
    )
    /// Mid-slot on the wall clock.
    private static let wall: Int64 = 1_800_000_000_000
    private static let edge = (BlindTag.slotOf(wallMilliseconds: wall) + 1) * BlindTag.slotMilliseconds

    private func readBlinded(_ reads: Reads, wall: Int64 = Self.wall) {
        #expect(reads.begin(Self.phone, now: 0))
        reads.state.finish(Self.phone, .read(Self.blinded), now: 0, wall: wall)
    }

    /// Rule 5 takes clear payloads only (the `blind-gatt-reads` contract, §6, Android's `forgetUnsealed`): a blinded one
    /// that lacks `FLAG_LINK_SEAL` stays for a plain dial's silence, as rule 4 forgets it every slot anyway.
    @Test func aBlindedPayloadIsNeverForgottenForANoReply() {
        let reads = Reads()
        readBlinded(reads)
        #expect(!reads.noReply(at: Self.phone))
        #expect(reads.state.payload(of: Self.phone) == Self.blinded)
        #expect(reads.forgetPastEdge(wall: Self.edge + 70_000) == [Self.phone], "rule 4 still forgets it at its edge")
    }

    @Test func aBlindedPayloadIsComparedWithTheHellosToldFormOrItsAnnouncedTagNeverTheId() {
        let reads = Reads()
        readBlinded(reads)
        #expect(!reads.helloNamed(fixtureNodeId(2), told: Self.tag, at: Self.phone), "its `t` is the payload's tag")
        #expect(!reads.helloNamed(fixtureNodeId(2), announced: Self.tag, at: Self.phone), "the tag it announced")
        #expect(reads.state.payload(of: Self.phone) == Self.blinded)
        #expect(reads.helloNamed(fixtureNodeId(2), told: Self.nextTag, at: Self.phone), "it rotated since the read")
        #expect(reads.state.payload(of: Self.phone) == nil)
        readBlinded(reads)
        #expect(reads.helloNamed(Self.tag, at: Self.phone), "a HELLO with no `t` airs its id now, whatever it is called")
    }

    @Test func aClearPayloadIsStillComparedWithTheId() {
        let reads = Reads()
        read(reads, Self.phone, now: 0)
        #expect(!reads.helloNamed(Self.payload.advertised, told: Self.tag, at: Self.phone), "the id it names, whatever the `t`")
        #expect(reads.helloNamed(fixtureNodeId(3), told: Self.payload.advertised, at: Self.phone))
    }

    @Test func aBlindedPayloadIsForgottenPastItsSlotEdgeWithSlackAndJitter() {
        let configuration = GattPayloads.Configuration()
        #expect(configuration.blindedEdgeSlackMilliseconds == 35_000, "an announced rotation's 30 s, and 5 s")
        #expect(GattPayloads.Configuration.defaultBlindedEdgeSlackMilliseconds == configuration.blindedEdgeSlackMilliseconds)
        #expect(configuration.blindedEdgeJitterMilliseconds == 30_000)
        let reads = Reads()
        readBlinded(reads)
        read(reads, Self.other, now: 0)
        #expect(reads.forgetPastEdge(wall: Self.edge + 34_999).isEmpty, "the slack: an announced rotation may land 30 s late")
        #expect(reads.forgetPastEdge(wall: Self.edge + 65_000) == [Self.phone], "by the jitter's end, once")
        #expect(reads.state.payload(of: Self.phone) == nil)
        #expect(reads.state.payload(of: Self.other) == Self.payload, "a clear payload is rule 3's alone")
        #expect(reads.begin(Self.phone, now: 1), "read again at its next advert")
    }

    @Test func aBlindedPayloadReadBeforeTheClockWentBackIsForgotten() {
        let reads = Reads()
        readBlinded(reads)
        #expect(reads.begin(Self.other, now: 0))
        reads.state.finish(Self.other, .read(Self.blinded), now: 0, wall: Self.wall)
        #expect(reads.forgetPastEdge(wall: Self.wall - 1) == [Self.other, Self.phone], "in order")
    }

    @Test func eachReadDrawsItsOwnJitterFromTheSeed() {
        var forgets: Set<Int64> = []
        for seed in UInt64(0)..<8 {
            var state = GattPayloads(configuration: GattPayloads.Configuration(blindedEdgeSlackMilliseconds: 0), jitterSeed: seed)
            let began = state.begin(Self.phone, now: 0)
            #expect(began)
            state.finish(Self.phone, .read(Self.blinded), now: 0, wall: Self.wall)
            let forgotAt = stride(from: Self.edge, through: Self.edge + 30_000, by: 1000).first { wall in
                !state.forgetPastEdge(wall: wall, linked: []).isEmpty
            }
            forgets.insert(forgotAt ?? -1)
        }
        #expect(!forgets.contains(-1), "every read is forgotten inside the jitter")
        #expect(forgets.count > 1, "and not all at once")
    }

    @Test func aLinkedAddressKeepsItsBlindedPayloadUntilTheLinkEnds() {
        let reads = Reads()
        readBlinded(reads)
        #expect(reads.forgetPastEdge(wall: Self.edge + 60_000, linked: [Self.phone]).isEmpty)
        #expect(reads.state.payload(of: Self.phone) == Self.blinded)
        #expect(reads.forgetPastEdge(wall: Self.edge + 65_000) == [Self.phone], "the first check after the link ends")
    }

    @Test func aForgottenBlindedPayloadTakesItsEdgeWithIt() {
        let reads = Reads()
        readBlinded(reads)
        reads.state.forget(Self.phone)
        #expect(reads.forgetPastEdge(wall: Self.edge + 60_000).isEmpty)
    }
}
