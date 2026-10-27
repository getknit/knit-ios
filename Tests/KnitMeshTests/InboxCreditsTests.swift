import KnitMesh
import Testing

/// A channel's inbound credit: reads stop at the limit and resume below half, and the count dies with the channel
/// (ADR 2026-10.f5zs, rule 6).
@Suite struct InboxCreditsTests {
    let channel = ChannelID(7)

    @Test func theLimitIsAQuarterMebibyte() {
        #expect(InboxCredits.limitBytes == 256 * 1024)
        #expect(InboxCredits().limit == InboxCredits.limitBytes)
    }

    @Test func aChannelReadsUntilItsCreditIsSpent() {
        let credits = InboxCredits(limit: 100)
        credits.open(channel)
        #expect(credits.gate(channel) == .read)
        credits.delivered(60, on: channel)
        #expect(credits.gate(channel) == .read)
        credits.delivered(39, on: channel)
        #expect(credits.gate(channel) == .read, "one byte under the limit still reads")
        credits.delivered(30, on: channel)
        #expect(credits.unprocessed(on: channel) == 129, "a read in flight is counted whole")
        #expect(credits.gate(channel) == .pause(unprocessed: 129), "the pause is said once")
        #expect(credits.gate(channel) == .paused)
        #expect(credits.gate(channel) == .paused)
    }

    @Test func aPausedChannelResumesOnlyBelowHalf() {
        let credits = InboxCredits(limit: 100)
        credits.open(channel)
        credits.delivered(100, on: channel)
        #expect(credits.gate(channel) == .pause(unprocessed: 100))
        #expect(credits.consumed(40, on: channel) == nil, "60 left is under the limit, not under half")
        #expect(credits.gate(channel) == .paused, "it stays paused between half and the limit")
        #expect(credits.consumed(10, on: channel) == nil, "exactly half is not below it")
        #expect(credits.consumed(1, on: channel) == 49, "below half resumes, once, with what is left")
        #expect(credits.gate(channel) == .read)
        #expect(credits.consumed(49, on: channel) == nil, "a channel reading is not resumed again")
        #expect(credits.unprocessed(on: channel) == 0)
    }

    @Test func consumingNeverReadsBelowNothing() {
        let credits = InboxCredits(limit: 100)
        credits.open(channel)
        credits.delivered(10, on: channel)
        #expect(credits.consumed(50, on: channel) == nil)
        #expect(credits.unprocessed(on: channel) == 0)
        #expect(credits.consumed(0, on: channel) == nil)
        credits.delivered(0, on: channel)
        #expect(credits.unprocessed(on: channel) == 0)
    }

    @Test func channelsAreCountedApart() {
        let credits = InboxCredits(limit: 100)
        let other = ChannelID(8)
        credits.open(channel)
        credits.open(other)
        credits.delivered(150, on: channel)
        #expect(credits.gate(channel) == .pause(unprocessed: 150))
        #expect(credits.gate(other) == .read, "a flood on one channel holds no other")
        #expect(credits.consumed(150, on: other) == nil)
        #expect(credits.unprocessed(on: channel) == 150)
    }

    @Test func theCountDiesWithTheChannel() {
        let credits = InboxCredits(limit: 100)
        credits.open(channel)
        credits.delivered(200, on: channel)
        #expect(credits.gate(channel) == .pause(unprocessed: 200))
        credits.note(.closed(channel))
        #expect(credits.isEmpty)
        #expect(credits.gate(channel) == .read, "a channel no longer counted is not held")
        #expect(credits.consumed(200, on: channel) == nil, "a late report for a closed channel resumes nothing")
        credits.delivered(10, on: channel)
        #expect(credits.isEmpty, "bytes for a channel not counted are not counted")

        credits.open(ChannelID(9))
        credits.note(.dialFailed(ChannelID(9)))
        credits.open(ChannelID(10))
        credits.note(.connected(ChannelID(10)))
        credits.close(ChannelID(10))
        #expect(credits.isEmpty)
    }

    @Test func openingTwiceKeepsTheCount() {
        let credits = InboxCredits(limit: 100)
        credits.open(channel)
        credits.delivered(30, on: channel)
        credits.open(channel)
        #expect(credits.unprocessed(on: channel) == 30)
    }
}
