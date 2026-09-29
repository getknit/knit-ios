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

        func helloNamed(_ node: NodeId, at address: RadioAddress) -> Bool {
            state.helloNamed(node, at: address)
        }

        func forgetQuiet(now: Int64, linked: Set<RadioAddress>) -> [RadioAddress] {
            state.forgetQuiet(now: now, linked: linked)
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
        reads.state.finish(address, .read(payload), now: now)
    }

    @Test func aHelloNamingAnotherNodeForgetsThePayloadAndTheSameNodeKeepsIt() {
        let reads = Reads()
        read(reads, Self.phone, now: 0)
        #expect(!reads.helloNamed(Self.payload.nodeId, at: Self.phone))
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
        reads.state.finish(Self.phone, .stranger, now: 0)
        reads.state.heard(Self.phone, now: 0)
        #expect(reads.forgetQuiet(now: 60_000, linked: []).isEmpty, "no payload to forget")
        #expect(!reads.begin(Self.phone, now: 60_000), "its ten minutes stand")
    }

    @Test func theReadThatFoundThePayloadCountsAsHearingIt() {
        let reads = Reads()
        reads.state.scanStarted(now: 0)
        reads.state.heard(Self.phone, now: 0)
        #expect(reads.begin(Self.phone, now: 0))
        reads.state.finish(Self.phone, .read(Self.payload), now: 10_000)
        #expect(reads.forgetQuiet(now: 69_999, linked: []).isEmpty)
        #expect(reads.forgetQuiet(now: 70_000, linked: []) == [Self.phone])
    }

    @Test func anAddressIsReadOnceAndWhatItServedIsKept() {
        let reads = Reads()
        #expect(reads.state.payload(of: Self.phone) == nil)
        #expect(reads.begin(Self.phone, now: 0))
        #expect(reads.state.current?.address == Self.phone)
        #expect(reads.state.current?.deadline == 100)
        reads.state.finish(Self.phone, .read(Self.payload), now: 40)
        #expect(reads.state.current == nil)
        #expect(reads.state.payload(of: Self.phone) == Self.payload)
        #expect(!reads.begin(Self.phone, now: 50), "read once")
    }

    @Test func oneReadRunsAtATime() {
        let reads = Reads()
        #expect(reads.begin(Self.phone, now: 0))
        #expect(!reads.begin(Self.other, now: 10))
        reads.state.finish(Self.phone, .failed, now: 20)
        #expect(reads.begin(Self.other, now: 30))
    }

    @Test func aFailedReadWaitsItsRetryAndAStrangerWaitsLonger() {
        let reads = Reads()
        #expect(reads.begin(Self.phone, now: 0))
        reads.state.finish(Self.phone, .failed, now: 0)
        #expect(!reads.begin(Self.phone, now: 999))
        #expect(reads.begin(Self.phone, now: 1000))
        reads.state.finish(Self.phone, .stranger, now: 1000)
        #expect(!reads.begin(Self.phone, now: 5999))
        #expect(reads.begin(Self.phone, now: 6000))
        #expect(reads.state.payload(of: Self.phone) == nil)
    }

    @Test func anOutcomeForAReadGivenUpOnIsIgnored() {
        let reads = Reads()
        #expect(reads.begin(Self.phone, now: 0))
        reads.state.finish(Self.other, .read(Self.payload), now: 10)
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
        reads.state.finish(Self.phone, .read(Self.payload), now: 0)
        reads.state.forget(Self.phone)
        #expect(reads.state.payload(of: Self.phone) == nil)
        #expect(reads.begin(Self.phone, now: 1))
        reads.state.finish(Self.phone, .stranger, now: 1)
        reads.state.forget(Self.phone)
        #expect(reads.begin(Self.phone, now: 2), "forgetting ends the wait too")
    }

    @Test func forgettingTheAddressBeingReadLetsTheReadRunOn() {
        let reads = Reads()
        #expect(reads.begin(Self.phone, now: 0))
        reads.state.forget(Self.phone)
        #expect(reads.state.current?.address == Self.phone)
        reads.state.finish(Self.phone, .read(Self.payload), now: 5)
        #expect(reads.state.payload(of: Self.phone) == Self.payload)
    }
}
