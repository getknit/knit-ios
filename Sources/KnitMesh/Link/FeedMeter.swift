public import KnitWire

/// A copy of a file being fed to a neighbour, as its link reads it (`FileFeed` in knit-next's `MeshTransport.kt`, its ADR
/// 2026-10.nsr7): what a holder weighs before it parks a second ask for the blob behind it.
public struct FeedReading: Sendable, Equatable {
    /// How long the rest should take, by the rate the receiver's reports measured or, before the first, by the pace;
    /// `nil` while the copy is queued and its pace not known.
    public var etaMilliseconds: Int64?
    /// Whether it still holds a parked ask: false once it stalled, or ran past the deadline its first measurement set.
    public var live: Bool
    /// Whether ``etaMilliseconds`` came from the receiver's reports.
    public var measured: Bool
    /// How soon ``live`` can next flip on its own, a stall or a deadline coming due, so a holder looks again then; `nil`
    /// when nothing is due.
    public var recheckMilliseconds: Int64?

    /// A reading.
    public init(etaMilliseconds: Int64?, live: Bool, measured: Bool = false, recheckMilliseconds: Int64? = nil) {
        self.etaMilliseconds = etaMilliseconds
        self.live = live
        self.measured = measured
        self.recheckMilliseconds = recheckMilliseconds
    }
}

/// How a link's file feed is really going, measured from the receiver's progress reports (`FeedMeter.kt`, knit-next ADR
/// 2026-10.nsr7, ported line for line from `8dc60836`). The radio's report that a chunk left its queue says nothing of
/// what arrived; the receiver's `blobprog` reports do: the bytes it holds, and when by its own clock, so the rate between
/// two reports is the drain whatever a report waited for on its way back.
///
/// One stream at a time (``start(_:now:)`` … ``end()``), plus what a stream leaves the link: ``drainRatio``, how far
/// below its pace it measured. The sender feeds below the drain on purpose, so a report shows the lower of the pace and
/// the drain, and only a shortfall says anything about the link. The shortfall is read only from reports whose window
/// ran at one pace with the writer awake: a pace that rose mid-window, or a wait the app slept through, would read as a
/// slow air. Its owner is the link's ``FileFeed``, and every method takes the monotonic clock's `now`.
internal struct FeedMeter {
    /// A feed with no progress this long is over for the asks parked behind it (`STALL_MS`): no report moved, once the
    /// stream has one, or no write went through, before.
    static let stallMilliseconds: Int64 = 15_000
    /// A feed's deadline, set once from its first measured ETA (`DEADLINE_NUM`, `DEADLINE_DEN`, `DEADLINE_SLACK_MS`):
    /// ETA × 5/4, plus slack for a slow start or a report's lag.
    static let deadlineNumerator: Int64 = 5
    static let deadlineDenominator: Int64 = 4
    static let deadlineSlackMilliseconds: Int64 = 30_000
    /// A stream that drained this much of its pace or more kept up (`KEPT_UP`).
    private static let keptUp = 0.9
    /// Reports skipped after a pace change or an overslept wait before one is read against the pace (`STEADY_REPORTS`).
    private static let steadyReportsNeeded = 2
    /// The shortest span, on the receiver's clock, a sample is measured over (`MIN_SAMPLE_MS`): a paced feed's report
    /// interval, so a windowed feed's meter samples as nsr7 tuned it.
    static let minSampleMilliseconds: Int64 = 2000
    /// A new sample counts a quarter (`SMOOTHING`).
    private static let smoothing: Int64 = 4

    /// The share of its pace the last measured stream on this link drained, when that fell short; 1.0 when it kept up,
    /// or nothing has been measured.
    private(set) var drainRatio = 1.0
    /// The rate the last measured stream on this link drained at, in bytes a second: 0 before one.
    private(set) var lastRate: Int64 = 0

    /// Whether the stream going now has a rate measured from its reports.
    var measured: Bool { rate > 0 }

    private let minSample: Int64
    private var key: BlobHash?
    private var offset: Int64 = 0
    private var length: Int64 = -1
    private var startedAt: Int64 = 0
    private var lastHeld: Int64 = -1
    // Where the next sample is measured from: a report under `minSample` after it takes no sample.
    private var sampleHeld: Int64 = -1
    private var sampleMilliseconds: Int64 = 0
    private var advancedAt: Int64 = 0
    private var reportAt: Int64 = 0
    private var rate: Int64 = 0
    private var pace: Int64 = 0
    private var deadlineAt: Int64 = 0
    private var deadlinePace: Int64 = 0
    // The writer's pace wait under way: when it began (-1: none) and what it asked for.
    private var pauseAt: Int64 = -1
    private var pauseMilliseconds: Int64 = 0
    // What the writer overslept since the receiver's reports last moved: not the feed's time.
    private var sleptSinceAdvance: Int64 = 0
    private var steadyReports = 0
    // The pace moved since the last report: the next one's window spans both paces, so it only rebases the rate.
    private var paceMoved = false
    private var ratio = -1.0

    /// A meter.
    init() {
        minSample = Self.minSampleMilliseconds
    }

    /// A meter whose samples may be closer than ``minSampleMilliseconds``, for a test of the arithmetic alone.
    init(minSample: Int64) {
        self.minSample = minSample
    }

    /// A stream of `key` begins (`start`); its offset and length come with ``sized(offset:length:)``.
    mutating func start(_ key: BlobHash, now: Int64) {
        self.key = key
        offset = 0
        length = -1
        startedAt = now
        lastHeld = -1
        sampleHeld = -1
        sampleMilliseconds = 0
        paceMoved = false
        advancedAt = now
        rate = 0
        pace = 0
        deadlineAt = 0
        deadlinePace = 0
        pauseAt = -1
        sleptSinceAdvance = 0
        steadyReports = 0
        ratio = -1
    }

    /// The stream starts at `offset` of the blob and carries `length` bytes of it (`sized`).
    mutating func sized(offset: Int64, length: Int64) {
        self.offset = offset
        self.length = length
    }

    /// The pace the writer feeds the stream's next chunk at (`paced`): what a measured rate is held against, and what
    /// the ETA reads until a report measures the new pace. A rate smoothed over the old pace says little of the new one.
    mutating func paced(_ pace: Int64) {
        if pace != self.pace {
            steadyReports = 0
            if self.pace > 0 {
                rate = 0
                paceMoved = true
            }
        }
        self.pace = pace
    }

    /// The writer goes into its pace wait between chunks, for `milliseconds` (`pausing`).
    mutating func pausing(_ milliseconds: Int64, now: Int64) {
        pauseAt = now
        pauseMilliseconds = milliseconds
    }

    /// The writer came out of its pace wait (`resumed`). Whatever it ran past what it asked for, the app slept: no chunk
    /// went out, so the receiver had nothing new to report, and neither the stall nor the deadline counts that time.
    mutating func resumed(now: Int64) {
        let overslept = pauseAt < 0 ? 0 : now - pauseAt - pauseMilliseconds
        pauseAt = -1
        guard overslept > 0 else {
            return
        }
        if deadlineAt != 0 {
            deadlineAt += overslept
        }
        sleptSinceAdvance += overslept
        steadyReports = 0
    }

    /// The stream is over (`end`): the shortfall it measured, if any, stays as the link's ``drainRatio``.
    mutating func end() {
        if ratio >= 0 {
            drainRatio = ratio < Self.keptUp ? ratio : 1
        }
        if rate > 0 {
            lastRate = rate
        }
        key = nil
        pauseAt = -1
    }

    /// The peer holds `held` bytes of `key`, `milliseconds` after its header arrived (`report`). True when it named the
    /// stream going now; a report of any other is stale and ignored.
    mutating func report(_ key: BlobHash, held: Int64, milliseconds: Int64, now: Int64) -> Bool {
        guard key == self.key, length >= 0 else {
            return false
        }
        let (fromHeld, fromMilliseconds) = sampleHeld < 0 ? (offset, Int64(0)) : (sampleHeld, sampleMilliseconds)
        if paceMoved {
            paceMoved = false
            steadyReports += 1
            sampleHeld = held
            sampleMilliseconds = milliseconds
        } else if milliseconds - fromMilliseconds >= minSample, held >= fromHeld {
            let sample = min(
                max((held - fromHeld) * FeedWindow.millisecondsPerSecond / (milliseconds - fromMilliseconds), 0), Int64(Int32.max))
            rate = rate == 0 ? sample : (rate * (Self.smoothing - 1) + sample) / Self.smoothing
            if steadyReports >= Self.steadyReportsNeeded, pace > 0 {
                let share = min(1, Double(sample) / Double(pace))
                ratio = ratio < 0 ? share : (ratio * Double(Self.smoothing - 1) + share) / Double(Self.smoothing)
            }
            steadyReports += 1
            sampleHeld = held
            sampleMilliseconds = milliseconds
        }
        if held > max(lastHeld, offset) {
            advancedAt = now
            sleptSinceAdvance = 0
        }
        if held >= lastHeld {
            lastHeld = held
            reportAt = now
        }
        return true
    }

    /// The stream as a ``FeedReading`` (`feed`). `left` is what it still has to write, `wroteAt` its last write, and
    /// `pace` the rate its pace would feed at: the estimate until a report measures one. `settled` is whether the pace
    /// is past its settle. Time the writer slept through its own pace wait counts toward neither the stall nor the
    /// deadline.
    ///
    /// - **Stall:** nothing moved for ``stallMilliseconds``: the receiver's reports once this stream has one, its writes
    ///   before.
    /// - **Deadline:** set once, at the first measured rate, or from the pace when this stream has had no report for
    ///   ``stallMilliseconds``: ETA × 5/4 + slack. Pushed back when the pace drops below what it was set at, which is
    ///   this sender splitting its budget over another feed.
    mutating func reading(left: Int64, wroteAt: Int64, pace: Int64, settled: Bool, now: Int64) -> FeedReading {
        let hasRate = rate > 0
        let whole = max(length, 0)
        let delivered = lastHeld >= 0 ? lastHeld - offset : whole - left
        let remaining = max(whole - delivered, 0)
        let eta = etaNow(now, remaining: remaining, pace: pace, settled: settled)
        let asleep = pauseAt < 0 ? 0 : max(now - pauseAt - pauseMilliseconds, 0)
        let quiet = lastHeld >= 0 ? now - advancedAt - sleptSinceAdvance : now - wroteAt
        let stallIn = Self.stallMilliseconds - (quiet - asleep)
        let due = hasRate || (settled && lastHeld < 0 && now - startedAt >= Self.stallMilliseconds)
        setDeadline(now, eta: eta, remaining: remaining, pace: pace, due: due)
        let deadlineIn = deadlineAt == 0 ? nil : deadlineAt + asleep - now
        let live = stallIn >= 0 && (deadlineIn.map { $0 >= 0 } ?? true)
        let recheck = [stallIn > 0 ? stallIn : nil, deadlineIn.flatMap { $0 > 0 ? $0 : nil }].compactMap(\.self).min()
        return FeedReading(etaMilliseconds: eta, live: live, measured: hasRate, recheckMilliseconds: recheck)
    }

    /// The ETA of `remaining` bytes at the measured rate, counted from the last report, or at `pace` before one
    /// (`etaNow`). Unsettled, the faster of the two stands.
    private func etaNow(_ now: Int64, remaining: Int64, pace: Int64, settled: Bool) -> Int64 {
        let eta = Self.eta(of: remaining, at: measured && settled ? rate : max(rate, pace))
        return lastHeld >= 0 && measured ? max(eta - (now - reportAt), 0) : eta
    }

    /// Sets the deadline once it is `due`, and moves it back when the pace dropped below what it was set at.
    private mutating func setDeadline(_ now: Int64, eta: Int64, remaining: Int64, pace: Int64, due: Bool) {
        if deadlineAt == 0, due {
            deadlineAt = now + Self.deadline(for: eta)
            deadlinePace = pace
        } else if deadlineAt != 0, pace > 0, pace < deadlinePace {
            deadlineAt = max(deadlineAt, now + Self.deadline(for: max(eta, Self.eta(of: remaining, at: pace))))
            deadlinePace = pace
        }
    }

    private static func eta(of bytes: Int64, at rate: Int64) -> Int64 {
        rate <= 0 ? 0 : bytes * FeedWindow.millisecondsPerSecond / rate
    }

    private static func deadline(for eta: Int64) -> Int64 {
        eta * deadlineNumerator / deadlineDenominator + deadlineSlackMilliseconds
    }
}
