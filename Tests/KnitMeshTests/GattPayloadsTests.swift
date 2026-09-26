import KnitMesh
import KnitTestSupport
import KnitWire
import Testing

/// Whose GATT payload a radio reads and when: once per address, one at a time, and again only after a wait or a
/// failed dial (ADR 2026-09.xzpt).
@Suite struct GattPayloadsTests {
    /// A ``GattPayloads`` behind a reference, so `#expect` can check what a mutating call answers.
    private final class Reads {
        var state = GattPayloads(
            configuration: GattPayloads.Configuration(
                readTimeoutMilliseconds: 100, retryMilliseconds: 1000, strangerRetryMilliseconds: 5000)
        )

        func begin(_ address: RadioAddress, now: Int64) -> Bool {
            state.begin(address, now: now)
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
