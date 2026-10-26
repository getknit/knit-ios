import KnitMesh
import Testing

/// The write-stall policy alone, on readings handed to it (ADR 2026-10.f5zs). `LinkWriteStallTests` drives it through
/// the link manager.
@Suite struct WriteStallWatchTests {
    private let link = ChannelID(7)
    private let stuck = OutboxLevel(queuedBytes: 10, writtenBytes: 5)

    @Test func checksRunEvery30SecondsWhileALinkIsWatched() {
        var watch = WriteStallWatch()
        #expect(watch.due == nil)
        watch.watch(link, written: 5, now: 0)
        watch.watch(ChannelID(8), written: 0, now: 10_000)
        #expect(watch.due == 30_000, "the first link sets the cadence")
        #expect(watch.check(now: 29_999, level: { _ in stuck }, exempt: { _ in false }) == .notDue)
        #expect(watch.check(now: 30_000, level: { _ in stuck }, exempt: { _ in false }) == .checked(stalled: []))
        #expect(watch.due == 60_000)
        watch.forget(link)
        #expect(watch.due == 60_000, "one link is still watched")
        watch.forget(ChannelID(8))
        #expect(watch.due == nil)
    }

    @Test func aStillTotalWithBytesQueuedStallsAt120Seconds() {
        var watch = WriteStallWatch()
        watch.watch(link, written: 5, now: 0)
        for now in stride(from: Int64(30_000), through: 90_000, by: 30_000) {
            #expect(watch.check(now: now, level: { _ in stuck }, exempt: { _ in false }) == .checked(stalled: []))
        }
        let found = watch.check(now: 120_000, level: { _ in stuck }, exempt: { _ in false })
        #expect(found == .checked(stalled: [WriteStallWatch.Stall(link: link, milliseconds: 120_000)]))
    }

    @Test func movementAnEmptyQueueOrAnExemptionTakesAFreshBaseline() {
        let readings: [(OutboxLevel, Bool)] = [
            (OutboxLevel(queuedBytes: 10, writtenBytes: 6), false),
            (OutboxLevel(queuedBytes: 0, writtenBytes: 5), false),
            (stuck, true),
        ]
        for (reading, exempt) in readings {
            var watch = WriteStallWatch()
            watch.watch(link, written: 5, now: 0)
            for now in stride(from: Int64(30_000), through: 90_000, by: 30_000) {
                _ = watch.check(now: now, level: { _ in stuck }, exempt: { _ in false })
            }
            #expect(watch.check(now: 120_000, level: { _ in reading }, exempt: { _ in exempt }) == .checked(stalled: []))
            let later = watch.check(now: 150_000, level: { _ in stuck }, exempt: { _ in false })
            #expect(later == .checked(stalled: []), "counted from 120 s, not from the start")
        }
    }

    @Test func aLateCheckRestampsInsteadOfJudging() {
        var watch = WriteStallWatch(configuration: WriteStallWatch.Configuration(lateMilliseconds: 1000))
        watch.watch(link, written: 5, now: 0)
        #expect(watch.check(now: 31_000, level: { _ in stuck }, exempt: { _ in false }) == .checked(stalled: []), "1 s late judges")
        #expect(watch.check(now: 500_000, level: { _ in stuck }, exempt: { _ in false }) == .late(milliseconds: 439_000))
        #expect(watch.due == 530_000)
        for now in stride(from: Int64(530_000), through: 590_000, by: 30_000) {
            #expect(watch.check(now: now, level: { _ in stuck }, exempt: { _ in false }) == .checked(stalled: []))
        }
        let found = watch.check(now: 620_000, level: { _ in stuck }, exempt: { _ in false })
        #expect(found == .checked(stalled: [WriteStallWatch.Stall(link: link, milliseconds: 120_000)]))
    }
}
