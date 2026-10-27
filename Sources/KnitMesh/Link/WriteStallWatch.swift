/// Whether a live link's writes have stalled: bytes queued, and none written, for 120 s of the app's running time
/// (ADR 2026-10.f5zs). The link manager keeps one, and polls each link's ``OutboxLevel`` at a check every 30 s.
///
/// It polls progress and never counts events. At each check a link's baseline is its written total and when that was
/// read. A link with nothing queued, or whose written total moved, takes a fresh baseline. One whose total stood still
/// with bytes queued for ``Configuration/stallMilliseconds`` is stalled. So a slow link whose bytes keep moving never
/// trips it, whatever its queue: a back-fill that drains over 393 s survives, as on the Pixel 3 on 2026-09-27
/// (`.agents/context/linux-peer.md`, "Why the frames were late"). A link that stops writing is found between 120 and
/// 150 s after its last byte out, by when in the 30 s between checks that byte went.
///
/// Android closes a link whose one `write()` has not returned in `WRITE_STALL_MS = 120_000` (`LinkSilence.kt:35-37`,
/// `:212`, `:389` at knit-next `e63f15f4`), which its blocking socket shows directly. Here a write never blocks, so the
/// stall is read from the queue instead.
///
/// **Only running time counts.** `SystemClock` runs on `ContinuousClock`, which counts the time iOS holds Knit
/// suspended, and a suspended Knit writes nothing, so a link would look stalled by the suspension alone. The link
/// manager re-stamps every baseline when Knit comes to the front and when its doorbell rings (``restamp(now:)``), and a
/// check that fires more than ``Configuration/lateMilliseconds`` late re-stamps instead of judging. On resume the
/// timer and the front reach the link manager in no fixed order, so the late check is what covers a timer that wins.
public struct WriteStallWatch: Sendable {
    /// How the watch is timed.
    public struct Configuration: Sendable {
        /// How often a check reads every link's level.
        public var checkEveryMilliseconds: Int64
        /// How long a link may hold bytes queued with none written: Android's `WRITE_STALL_MS`.
        public var stallMilliseconds: Int64
        /// How late a check may fire and still judge: later, the app was suspended (``LinkManager``'s
        /// `suspendedLatenessMilliseconds`).
        public var lateMilliseconds: Int64

        /// A check every 30 s, a stall at 120 s, and a check 1 s late taken as a suspension.
        public init(checkEveryMilliseconds: Int64 = 30_000, stallMilliseconds: Int64 = 120_000, lateMilliseconds: Int64 = 1000) {
            self.checkEveryMilliseconds = checkEveryMilliseconds
            self.stallMilliseconds = stallMilliseconds
            self.lateMilliseconds = lateMilliseconds
        }
    }

    /// What a check found.
    public enum Check: Sendable, Equatable {
        /// No check was due.
        case notDue
        /// The check fired this late, so the app was suspended: every baseline starts again, and no link is judged.
        case late(milliseconds: Int64)
        /// Each link stalled, in channel order, with how long its written total has stood still.
        case checked(stalled: [Stall])
    }

    /// A link whose writes stalled.
    public struct Stall: Sendable, Equatable {
        /// The link.
        public var link: ChannelID
        /// How long its written total has stood still with bytes queued.
        public var milliseconds: Int64

        /// A stall.
        public init(link: ChannelID, milliseconds: Int64) {
            self.link = link
            self.milliseconds = milliseconds
        }
    }

    private struct Baseline: Sendable {
        var written: Int64
        var since: Int64
    }

    private let configuration: Configuration
    private var baselines: [ChannelID: Baseline] = [:]
    /// When the next check is due, while any link is watched.
    public private(set) var due: Int64?

    /// A watch with Android's 120 s unless told otherwise.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The links watched.
    public var count: Int { baselines.count }

    /// Watches `link` from `now`, its written total `written`. The first link watched schedules the checks.
    public mutating func watch(_ link: ChannelID, written: Int64, now: Int64) {
        baselines[link] = Baseline(written: written, since: now)
        if due == nil {
            due = now + configuration.checkEveryMilliseconds
        }
    }

    /// Stops watching `link`. With no link left, no check is due.
    public mutating func forget(_ link: ChannelID) {
        baselines[link] = nil
        if baselines.isEmpty {
            due = nil
        }
    }

    /// Counts every link's stall from `now`: the app has just run again after a time it may have been suspended.
    public mutating func restamp(now: Int64) {
        for link in baselines.keys {
            baselines[link]?.since = now
        }
    }

    /// Runs the check if one is due at `now`, reading each link's `level`. A link `exempt` says to leave alone takes a
    /// fresh baseline like one that moved, so it is never judged on time it spent exempt.
    public mutating func check(now: Int64, level: (ChannelID) -> OutboxLevel, exempt: (ChannelID) -> Bool) -> Check {
        guard let scheduled = due, now >= scheduled else {
            return .notDue
        }
        due = now + configuration.checkEveryMilliseconds
        let lateness = now - scheduled
        if lateness > configuration.lateMilliseconds {
            restamp(now: now)
            return .late(milliseconds: lateness)
        }
        var stalled: [Stall] = []
        // Each pass writes only its own link's baseline, so the sorted copy reads what the loop would.
        for (link, baseline) in baselines.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let reading = level(link)
            if reading.queuedBytes == 0 || reading.writtenBytes != baseline.written || exempt(link) {
                baselines[link] = Baseline(written: reading.writtenBytes, since: now)
            } else if now - baseline.since >= configuration.stallMilliseconds {
                stalled.append(Stall(link: link, milliseconds: now - baseline.since))
            }
        }
        return .checked(stalled: stalled)
    }
}
