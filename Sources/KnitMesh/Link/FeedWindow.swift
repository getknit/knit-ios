/// A file feed clocked by its receiver's reports instead of a fixed pace (knit-next ADR 2026-10.5buf, `FeedWindow.kt`).
/// The radio's stream buffer sits between our writes and the air, but the receiver's `blobprog` reports say how much it
/// holds. So, as TCP does with its acks, the feed bounds the bytes written and not yet reported held to a window: the
/// drain over the round trip, plus ``queueMilliseconds`` of it queued. A frame queued behind the file then waits about a
/// quarter second past the round trip on any link, and the feed runs at whatever the link drains, where a fixed pace
/// overfeeds a slow pair and starves a fast one.
///
/// The estimates are BBR's:
/// - **Drain:** Δheld ÷ Δms between reports on the receiver's clock, so a report's trip back costs it nothing, over at
///   least ``minSampleMilliseconds``. The rate is the largest of the last ``samples`` (a few seconds of them), held to
///   ``ceilingBytesPerSecond``. Fewer let a feed that was briefly the limit drag its own window down in a spiral
///   (knit-next device sweep 6). A link that really slowed is read from the round trip instead.
/// - **Round trip:** from a chunk's write to the report that first holds all of it, on the sender's clock; the
///   smallest in the last ``roundTripWindowMilliseconds``. When none smaller has come for that long, the window drops
///   to one smallest chunk for a round (``probingRoundTrip``) so a chunk's sample reads the air alone.
/// - **Growth:** a window larger than the drain over the round trip delivers more than the rate in a round, so while the
///   feed is the limit each round raises the rate, until the air is the limit and about ``queueMilliseconds`` stands.
/// - **Silence:** before the first report the window is four smallest chunks. With no report for
///   ``noReportMilliseconds`` the owner paces the feed (``pacing(now:)``) until one comes.
/// - **Two-second reporter:** a receiver whose reports come ``slowReportMilliseconds`` apart, each covering several
///   chunks, is paced too (``slowReporter``), in chunks small enough that a receiver reporting every chunk answers each
///   well inside that gap; ``recoverReports`` such answers in a row give the window back (the 2026-10-08 amendment).
///
/// Android's Coded parts are left out: CoreBluetooth never shows the PHY, so there is no step to forget the link at,
/// and the smallest chunk is always 1M's. One stream at a time (``start(offset:now:)``), clocked by the `now` each call
/// passes.
internal struct FeedWindow {
    /// A chunk written and not yet reported held: where it ends in the stream, when it went out, and how much was
    /// unreported ahead of it then.
    private struct Written {
        let end: Int64
        let at: Int64
        let ahead: Int64
    }

    /// The queue, in ms of the rate, the feed keeps ahead of the receiver past the round trip (`QUEUE_MS`).
    static let queueMilliseconds: Int64 = 250
    /// The fastest drain a report is believed at, which bounds a garbled or lying one: about twice the best 1M drain
    /// knit-next measured (`CEILING_BYTES_PER_SEC`).
    static let ceilingBytesPerSecond: Int64 = 65_536
    /// The smallest chunk the feed writes, which sizes the window's floor, its start and a probe's room
    /// (`MIN_CHUNK_BYTES`). A receiver reports on every chunk that brings this much.
    static let minChunkBytes = 2048
    /// The largest window: a second of the ceiling (`MAX_WINDOW`).
    static let maxWindowBytes: Int64 = 65_536
    /// A receiver silent this long gets the paced fallback until it reports (`NO_REPORT_MS`).
    static let noReportMilliseconds: Int64 = 3000
    /// The longest one wait for room lasts; a report wakes the writer sooner (`REPORT_WAIT_MS`).
    static let reportWaitMilliseconds: Int64 = 500
    /// The shortest span, on the receiver's clock, a drain sample is measured over: a reader catching up a burst
    /// reports bytes ms apart, which would read MB/s (`MIN_SAMPLE_MS`).
    static let minSampleMilliseconds: Int64 = 250
    /// The round trip assumed until one is measured, its bounds, and how long the smallest stands before a probe.
    static let initialRoundTripMilliseconds: Int64 = 500
    static let minRoundTripMilliseconds: Int64 = 50
    static let maxRoundTripMilliseconds: Int64 = 3000
    static let roundTripWindowMilliseconds: Int64 = 10_000
    /// A receiver reporting this far apart (its own clock), twice running, reports every two seconds: pace it.
    static let slowReportMilliseconds: Int64 = 1900
    /// How many reports in a row, one chunk at a time at the paced spacing, give a two-second reporter its window back.
    static let recoverReports = 3
    /// A chunk's crossing counted at most this long when the slow gap and the silence are scaled to a slow drain, so one
    /// low sample cannot hold a receiver whose reports stopped unpaced for minutes (`MAX_CHUNK_CROSSING_MS`).
    static let maxChunkCrossingMilliseconds: Int64 = 3400
    /// A chunk carries about this much of the rate (`CHUNK_MS`).
    static let chunkMilliseconds: Int64 = 250

    private static let minWindowChunks = 2
    private static let initialWindowChunks = 4
    private static let initialChunks = 2
    private static let slowGaps = 2
    private static let slowRecords = 2
    private static let silentRecords = 3
    // How many windows of queue at a report make it a standing one, whose sample is the drain: what a report finds
    // unheld is the queue plus the round trip's bytes plus the writer's last chunk, so one window fired on nearly every
    // report of a lit sender (knit-next's reviewer's port).
    private static let standingWindows: Int64 = 2
    private static let sampleCount = 12
    // A chunk's round trip past this many of what it should have taken says the link slowed.
    private static let slowedNumerator: Int64 = 3
    private static let slowedDenominator: Int64 = 2
    static let millisecondsPerSecond: Int64 = 1000
    // An on-time answer comes no sooner than this share of the paced chunks' spacing.
    private static let onTimeFloorShare: Int64 = 2

    /// The starting window: what may be in flight before the first report, two seconds of the old 4 KiB/s base.
    static let initialWindowBytes = Int64(initialWindowChunks * minChunkBytes)
    /// A chunk before the rate is known.
    static let initialChunkBytes = initialChunks * minChunkBytes
    private static let minWindowBytes = Int64(minWindowChunks * minChunkBytes)

    /// The largest chunk the feed writes: Android's `FILE_CHUNK_BYTES`.
    private let maxChunkBytes: Int

    /// The drain measured from the receiver's reports, in bytes a second: 0 until a sample is taken.
    private(set) var rate: Int64 = 0
    /// The round trip the window covers, in ms.
    private(set) var roundTripMilliseconds = initialRoundTripMilliseconds
    /// Whether the window is down to one smallest chunk for a round, so the next round trip measured reads the air alone.
    private(set) var probingRoundTrip = false
    /// Whether the stream paces a receiver taken for a two-second reporter, until it answers chunk by chunk again.
    private(set) var slowReporter = false

    private var written: Int64 = 0
    private var lastHeld: Int64 = -1
    // When the stream began or a report last came, on the sender's clock: the silence counts from it.
    private var heardAt: Int64 = 0

    // Where the next drain sample is measured from: the last report a sample was taken at (or the stream's start).
    private var sampleHeld: Int64 = -1
    private var sampleAt: Int64 = 0
    private var drainSamples = [Int64](repeating: 0, count: sampleCount)
    private var drainSampleCount = 0
    private var nextSample = 0

    // The chunks written and not yet reported held: where each ends, when it went out, and how much was unreported
    // ahead of it then.
    private var out: [Written] = []

    // When the round trip was last measured as the smallest, its raw value, and, while probing, what was written when
    // the probe began. Kept across the link's streams: a file fed in full still has its tail in the radio's buffer, so
    // the next stream's first sample counts it, and taken fresh each stream the estimate grew with every file sent back
    // to back until it locked at the ceiling (knit-next's reviewer).
    private var roundTripAt: Int64 = -1
    private var roundTripRaw = Int64.max
    private var probeFrom: Int64 = 0

    // The receiver's last report time on its own clock, and how many reports in a row came the slow gap or more apart.
    private var lastReportAt: Int64 = -1
    private var slowGapsInARow = 0
    private var onTimeReports = 0
    // The shortest gap an on-time report may follow the last by: half the paced chunks' spacing. A dozing receiver
    // working through its backlog reports each chunk ms apart, and three of those would give the window back to a
    // receiver still asleep.
    private var onTimeFloor: Int64 = 0
    // Where the stream stood when it was last taken for a two-second reporter: only a chunk written after it can be
    // answered on time.
    private var pacedFrom: Int64 = 0

    /// A window whose chunks are at most `maxChunkBytes`, a record's: Android's `FILE_CHUNK_BYTES`.
    init(maxChunkBytes: Int) {
        self.maxChunkBytes = max(Self.minChunkBytes, maxChunkBytes)
    }

    /// A stream starts at `now`. The round trip is the link's and outlives it.
    mutating func start(now: Int64) {
        written = 0
        lastHeld = -1
        heardAt = now
        sampleHeld = -1
        sampleAt = 0
        rate = 0
        drainSampleCount = 0
        nextSample = 0
        out.removeAll()
        probingRoundTrip = false
        lastReportAt = -1
        slowGapsInARow = 0
        onTimeReports = 0
        onTimeFloor = 0
        pacedFrom = 0
        slowReporter = false
    }

    /// `bytes` more of the stream went to the radio at `now`.
    mutating func wrote(_ bytes: Int, now: Int64) {
        let ahead = queued
        written += Int64(bytes)
        out.append(Written(end: written, at: now, ahead: ahead))
    }

    /// The receiver holds `held` bytes, `milliseconds` after the stream's header reached it, and the report came at
    /// `now`. A report older than the last, or naming more than was written, moves nothing past what it can prove.
    mutating func report(held: Int64, milliseconds: Int64, now: Int64) {
        let proven = min(held, written)
        guard proven >= max(lastHeld, 0) else {
            return
        }
        let standing = !probingRoundTrip && written - proven > Self.standingWindows * target
        // The round trip of the last chunk this report holds whole.
        var sentAt: Int64 = -1
        var end: Int64 = 0
        var ahead: Int64 = 0
        var landed = 0
        while let first = out.first, first.end <= proven {
            out.removeFirst()
            (end, sentAt, ahead) = (first.end, first.at, first.ahead)
            landed += 1
        }
        noteReportGap(milliseconds, landed: landed, end: end)
        let slowed = sentAt >= 0 && noteTrip(now - sentAt, end: end, ahead: ahead, now: now)
        if !probingRoundTrip, roundTripAt >= 0, now - roundTripAt > Self.roundTripWindowMilliseconds {
            probingRoundTrip = true
            probeFrom = written
        }
        sampleDrain(proven, at: milliseconds, reset: standing || slowed)
        lastHeld = proven
        heardAt = now
    }

    /// A chunk ending at `end` came back `trip` ms after its write, with `ahead` unreported ahead of it then: its round
    /// trip is noted, and true if it says the link slowed. A chunk back after half again what it should have taken (the
    /// round trip, the queue, and what was ahead of it at the drain) waited behind a queue that grew. Judged by what was
    /// ahead, not by the window, which a faster earlier file can leave short (knit-next's reviewer).
    private mutating func noteTrip(_ trip: Int64, end: Int64, ahead: Int64, now: Int64) -> Bool {
        let expected = roundTripMilliseconds + Self.queueMilliseconds + (rate > 0 ? ahead * Self.millisecondsPerSecond / rate : 0)
        let slowed = !probingRoundTrip && roundTripAt >= 0 && trip * Self.slowedDenominator > Self.slowedNumerator * expected
        noteRoundTrip(trip, end: end, ahead: ahead, now: now)
        return slowed
    }

    /// A drain sample from the last sampled report to `proven` held at `at` on the receiver's clock, if that spans the
    /// shortest sample; none while probing, whose window is smaller than the pipe. `reset` keeps only this one: a
    /// standing queue or a slow round trip says the air set it, and the larger ones before it are a link that slowed.
    private mutating func sampleDrain(_ proven: Int64, at: Int64, reset: Bool) {
        let (fromHeld, fromAt) = sampleHeld < 0 ? (Int64(0), Int64(0)) : (sampleHeld, sampleAt)
        guard at - fromAt >= Self.minSampleMilliseconds else {
            return
        }
        if !probingRoundTrip {
            let sample = min(max((proven - fromHeld) * Self.millisecondsPerSecond / (at - fromAt), 0), Self.ceilingBytesPerSecond)
            if reset {
                drainSampleCount = 0
                nextSample = 0
            }
            drainSamples[nextSample] = sample
            nextSample = (nextSample + 1) % Self.sampleCount
            drainSampleCount = min(drainSampleCount + 1, Self.sampleCount)
            rate = drainSamples.prefix(drainSampleCount).reduce(0, max)
        }
        sampleHeld = proven
        sampleAt = at
    }

    /// A report at `at` on the receiver's clock covering `landed` more chunks: two gaps of the slow gap that each covered
    /// more than one chunk mark a two-second reporter. A windowed receiver reports every chunk, so its gaps are the
    /// chunks' own, long on a slow link: read by time alone they paced a slow link's window away (knit-next's
    /// reviewer). Once marked, ``recoverReports`` reports in a row unmark it, each one chunk written since, under the
    /// slow gap after the last and no sooner than the on-time floor.
    private mutating func noteReportGap(_ at: Int64, landed: Int, end: Int64) {
        if lastReportAt >= 0 {
            let gap = at - lastReportAt
            let slowGap = slowGapMilliseconds
            slowGapsInARow = gap >= slowGap && landed > 1 ? slowGapsInARow + 1 : 0
            if slowGapsInARow >= Self.slowGaps, !slowReporter {
                slowReporter = true
                pacedFrom = written
            }
            if slowReporter {
                let onTime = gap >= onTimeFloor && gap < slowGap && landed == 1 && end > pacedFrom
                onTimeReports = onTime ? onTimeReports + 1 : 0
                if onTimeReports >= Self.recoverReports {
                    slowReporter = false
                    slowGapsInARow = 0
                    onTimeReports = 0
                }
            }
        }
        lastReportAt = max(lastReportAt, at)
    }

    /// A chunk ending at `end` came back `trip` ms after its write, with `ahead` unreported ahead of it then. The
    /// smallest is the round trip; a probe's first chunk back, written with at most one smallest chunk ahead of it, is
    /// the round trip whatever it reads, and ends the probe. A chunk the paced fallback wrote behind a backlog does not.
    private mutating func noteRoundTrip(_ trip: Int64, end: Int64, ahead: Int64, now: Int64) {
        if probingRoundTrip, end > probeFrom, ahead <= Self.minChunkBytes {
            setRoundTrip(trip, now: now)
            probingRoundTrip = false
            return
        }
        // No larger, compared before the clamp: a steady link's samples keep the estimate fresh, and one clamped to the
        // ceiling must not.
        if roundTripAt < 0 || trip <= roundTripRaw {
            setRoundTrip(trip, now: now)
        }
    }

    private mutating func setRoundTrip(_ trip: Int64, now: Int64) {
        roundTripRaw = trip
        roundTripMilliseconds = min(max(trip, Self.minRoundTripMilliseconds), Self.maxRoundTripMilliseconds)
        roundTripAt = now
    }

    /// The writer's wait ended `late` ms past what it asked for: a suspended app's timer fires late. With nothing
    /// unreported the receiver had nothing to report, and that time does not count toward the silence; with a window
    /// out it owes a report, and the silence counts (knit-next's reviewer).
    mutating func slept(_ late: Int64, now: Int64) {
        if late > 0, queued == 0 {
            heardAt = min(now, heardAt + late)
        }
    }

    /// Whether the owner paces the feed: the receiver silent for the silence (until it reports), or one that reports
    /// only every two seconds (until it answers chunk by chunk again).
    func pacing(now: Int64) -> Bool {
        slowReporter || now - heardAt >= silenceMilliseconds
    }

    /// How long `records` of the smallest chunk take to cross at the measured rate; 0 before one. A receiver reports a
    /// chunk only once all of it has crossed, so on a drain under about 2 KB/s the constants alone would read every
    /// chunk as silence.
    private func recordsMilliseconds(_ records: Int) -> Int64 {
        guard rate > 0 else {
            return 0
        }
        return min(
            Int64(records * Self.minChunkBytes) * Self.millisecondsPerSecond / rate, Int64(records) * Self.maxChunkCrossingMilliseconds)
    }

    /// The report gap that marks a two-second reporter, and bounds an on-time report: two chunks' time at least.
    private var slowGapMilliseconds: Int64 {
        max(Self.slowReportMilliseconds, recordsMilliseconds(Self.slowRecords))
    }

    /// The silence after which the feed is paced: three chunks' time at least.
    private var silenceMilliseconds: Int64 {
        max(Self.noReportMilliseconds, recordsMilliseconds(Self.silentRecords))
    }

    /// The bytes the window lets be written and not yet reported held: the rate over the round trip plus the queue, one
    /// smallest chunk's room while probing, or the starting window before a rate. Never under two smallest chunks, so a
    /// slow link never stops and waits for each report.
    var target: Int64 {
        if probingRoundTrip {
            return Int64(Self.minChunkBytes) + 1
        }
        guard rate > 0 else {
            return Self.initialWindowBytes
        }
        let window = rate * (roundTripMilliseconds + Self.queueMilliseconds) / Self.millisecondsPerSecond
        return min(max(window, Self.minWindowBytes), Self.maxWindowBytes)
    }

    /// The bytes written that no report has said the receiver holds.
    var queued: Int64 {
        written - max(lastHeld, 0)
    }

    /// How long to wait before the next chunk: 0 while the window has room, else until a report frees it.
    var waitMilliseconds: Int64 {
        queued < target ? 0 : Self.reportWaitMilliseconds
    }

    /// The next windowed chunk's size: about a quarter second of the rate, so a frame queued mid-file waits at most a
    /// small chunk.
    var chunkBytes: Int {
        guard rate > 0 else {
            return Self.initialChunkBytes
        }
        return Int(min(max(rate * Self.chunkMilliseconds / Self.millisecondsPerSecond, Int64(Self.minChunkBytes)), Int64(maxChunkBytes)))
    }

    /// A paced chunk's size for a windowed feed in its fallback, from the pace's own: while ``slowReporter``, the
    /// smallest chunk, so a receiver reporting every chunk answers each well inside the slow gap and can earn the window
    /// back. It also sets how soon an on-time answer may come: half the paced spacing (`FeedWindow.chunkFor`).
    mutating func pacedChunkBytes(_ pace: FilePace) -> Int {
        let chunk = slowReporter ? min(pace.chunkBytes, Self.minChunkBytes) : pace.chunkBytes
        onTimeFloor = Int64(chunk) * Self.millisecondsPerSecond / max(pace.bytesPerSecond, 1) / Self.onTimeFloorShare
        return chunk
    }

    /// Why a windowed feed is paced, for its `link file window` line.
    var pacedWhy: String {
        slowReporter ? "paced: two-second reporter" : "paced: receiver silent"
    }
}

/// A link's file pace when no window clocks it (knit-next ADR 2026-10.8jwn, `CodedPhyPolicy.filePace`): its share of
/// one budget split among the links feeding at that pace, in chunks of two seconds of it. A budget of 0 is unbounded.
internal struct FilePace: Equatable {
    /// How long one chunk is of the link's share (`CHUNK_FEED_SECONDS`).
    static let chunkSeconds: Int64 = 2

    var bytesPerSecond: Int64
    var chunkBytes: Int

    /// The share of `budget` one of `feeding` links takes, in chunks from the smallest window chunk to `maxChunkBytes`.
    init(budget: Int64, feeding: Int, maxChunkBytes: Int) {
        guard budget > 0 else {
            bytesPerSecond = 0
            chunkBytes = maxChunkBytes
            return
        }
        let share = max(1, budget / Int64(max(1, feeding)))
        bytesPerSecond = share
        chunkBytes = Int(min(max(share * Self.chunkSeconds, Int64(FeedWindow.minChunkBytes)), Int64(maxChunkBytes)))
    }

    /// How long a chunk of `count` bytes holds the next one back; 0 when unbounded.
    func spacing(for count: Int) -> Int64 {
        bytesPerSecond > 0 ? Int64(count) * FeedWindow.millisecondsPerSecond / bytesPerSecond : 0
    }
}
