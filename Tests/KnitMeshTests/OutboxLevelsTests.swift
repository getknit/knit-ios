import KnitMesh
import Testing

/// A radio's per-channel write levels, counted at its entry points and read in place by the `Mesh` actor (ADR
/// 2026-10.f5zs). Bytes for a channel it does not hold are not counted, as the radio drops them too.
@Suite struct OutboxLevelsTests {
    let channel = ChannelID(7)

    @Test func queuedBytesMoveToWrittenAsTheSocketTakesThem() {
        let levels = OutboxLevels()
        levels.open(channel)
        levels.queued(100, on: channel)
        levels.wrote(30, on: channel)
        #expect(levels.level(on: channel) == OutboxLevel(queuedBytes: 70, writtenBytes: 30))
        levels.discarded(20, on: channel)
        #expect(levels.level(on: channel) == OutboxLevel(queuedBytes: 50, writtenBytes: 30), "a replaced digest gives its bytes back")
        levels.discarded(80, on: channel)
        levels.wrote(10, on: channel)
        #expect(levels.level(on: channel) == OutboxLevel(queuedBytes: 0, writtenBytes: 40), "the queue never reads below nothing")
    }

    @Test func nothingIsANoOp() {
        let levels = OutboxLevels()
        levels.open(channel)
        levels.queued(40, on: channel)
        levels.wrote(10, on: channel)
        levels.queued(0, on: channel)
        levels.discarded(0, on: channel)
        levels.wrote(0, on: channel)
        levels.queued(-5, on: channel)
        levels.discarded(-5, on: channel)
        levels.wrote(-5, on: channel)
        #expect(levels.level(on: channel) == OutboxLevel(queuedBytes: 30, writtenBytes: 10))
    }

    @Test func aChannelNeverOpenedCountsNothing() {
        let levels = OutboxLevels()
        levels.queued(100, on: channel)
        levels.discarded(10, on: channel)
        levels.wrote(10, on: channel)
        #expect(levels.isEmpty, "bytes for a channel the radio does not hold are not counted")
        #expect(levels.level(on: channel) == OutboxLevel())
    }

    @Test func aClosedChannelCountsNothingMore() {
        let levels = OutboxLevels()
        levels.open(channel)
        levels.queued(100, on: channel)
        levels.wrote(60, on: channel)
        levels.note(.closed(channel))
        #expect(levels.isEmpty)
        levels.queued(10, on: channel)
        levels.discarded(10, on: channel)
        levels.wrote(10, on: channel)
        #expect(levels.isEmpty, "a late write's bytes for a closed channel are not counted")
        #expect(levels.level(on: channel) == OutboxLevel(), "and its level reads empty")
        levels.open(channel)
        #expect(levels.level(on: channel) == OutboxLevel(), "a channel reopened under the same number starts empty")
    }

    @Test func onlyAClosingEventDropsAChannel() {
        let levels = OutboxLevels()
        levels.open(ChannelID(8))
        levels.note(.dialFailed(ChannelID(8)))
        #expect(levels.isEmpty)
        levels.open(channel)
        levels.queued(5, on: channel)
        levels.note(.connected(channel))
        #expect(levels.level(on: channel).queuedBytes == 5)
        levels.open(channel)
        #expect(levels.level(on: channel).queuedBytes == 5, "opening twice keeps the count")
        levels.close(channel)
        #expect(levels.isEmpty)
    }
}
