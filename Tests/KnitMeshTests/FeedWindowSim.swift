@testable import KnitMesh

/// One simulated stream, as knit-next's `FeedWindowTest.Sim` runs one: the sender follows the window, the air drains
/// `drain` B/s from one queue (the radio's buffer and the air), and the receiver reports as a windowed one does
/// (`LinkManager.fileProgress`, `RxReports`): on the chunk that brings 2 KiB since its last report, or `reportEvery`
/// after it once anything more landed. Each report reaches the sender `lag` ms later, the reverse air a slow connection
/// interval stretches. Android's Coded modes (whole records, a dark receiver, the paced fallback) are left out with the
/// Coded tests they serve.
final class FeedWindowSim {
    /// A report on its way back: when it reaches the sender, what it holds, and when it was sent by the receiver's clock.
    private struct Report {
        let arrives: Int64
        let held: Int64
        let at: Int64
    }

    static let step: Int64 = 10
    static let chunkReportBytes: Int64 = 2048

    var drain: Int64
    var lag: Int64
    private let reportEvery: Int64
    // A dark sender: its timers never fire, so it writes only when a report wakes it.
    private let asleep: Bool

    var window = FeedWindow(maxChunkBytes: 16_384)
    private(set) var time: Int64 = 0
    // Written and not yet across the air.
    private(set) var queue: Int64 = 0
    // What the receiver holds.
    private(set) var held: Int64 = 0
    // The deepest queue, in ms of the drain, since `measure(from:)`.
    private(set) var maxQueueMilliseconds: Int64 = 0
    private var measureFrom: Int64 = 0
    private var reports: [Report] = []
    private var reportedAt: Int64 = 0
    private var reportedHeld: Int64 = 0
    private var waitUntil: Int64 = 0

    init(drain: Int64, lag: Int64 = 100, reportEvery: Int64 = 500, asleep: Bool = false) {
        self.drain = drain
        self.lag = lag
        self.reportEvery = reportEvery
        self.asleep = asleep
        window.start(now: 0)
    }

    func measure(from at: Int64) {
        measureFrom = at
        maxQueueMilliseconds = 0
    }

    func run(until end: Int64) {
        while time < end {
            deliverReports()
            writerTurn()
            airAndReceiver()
            if time >= measureFrom {
                maxQueueMilliseconds = max(maxQueueMilliseconds, queue * 1000 / drain)
            }
            time += Self.step
        }
    }

    /// What the receiver got per second over (`from`, now].
    func throughput(since from: Int64, heldThen: Int64) -> Int64 {
        (held - heldThen) * 1000 / (time - from)
    }

    // The writer's turn: its wait has run out, and a dark one's only at the instant a report woke it (or at the start).
    private var writerAwake: Bool {
        time >= waitUntil && (!asleep || time == waitUntil || time == 0)
    }

    private func deliverReports() {
        while let first = reports.first, first.arrives <= time {
            reports.removeFirst()
            window.report(held: first.held, milliseconds: first.at, now: time)
            // A report wakes the writer.
            waitUntil = time
        }
    }

    private func writerTurn() {
        while writerAwake {
            let wait = window.waitMilliseconds
            if wait > 0 {
                waitUntil = asleep ? Int64.max : time + wait
                return
            }
            let chunk = window.chunkBytes
            window.wrote(chunk, now: time)
            queue += Int64(chunk)
        }
    }

    // One step of the air, and the receiver's report on what it now holds.
    private func airAndReceiver() {
        let drained = min(queue, drain * Self.step / 1000)
        queue -= drained
        held += drained
        let grown = held - reportedHeld
        let due = time - reportedAt >= reportEvery
        if grown >= Self.chunkReportBytes || (grown > 0 && due) {
            reports.append(Report(arrives: time + lag, held: held, at: time))
            reportedHeld = held
            reportedAt = time
        }
    }
}
