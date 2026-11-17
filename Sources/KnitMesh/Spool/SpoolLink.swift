import KnitWire

/// A connection's token: one engine-wide counter hands each dial its own (ADR 2026-11.adrq, P4b1), never one per relay, so a
/// relay removed and added again under its old handle never matches an old task's late event.
public struct SpoolConnectionToken: Hashable, Sendable, CustomStringConvertible {
    let value: Int64

    public var description: String { "#\(value)" }
}

/// Why a session ended, which decides what the backoff makes of it.
internal enum SpoolSessionEnd: Sendable, Equatable {
    /// ``SpoolPlane/pause(engine:)``: no failure, and no redial until the resume.
    case paused
    /// The relay was removed.
    case removed
    /// A second open on the same token: the old session gives way, counted neither way.
    case replaced
    /// Bytes waited past ``SpoolLink/writeStallMilliseconds`` with no send done: unreached.
    case writeStall
    /// A send failed, which is the socket's end.
    case sendFailed
    /// The socket ended, as the adapter says.
    case socket(SpoolSocketEnd)
    /// This side ended the session for `fault`: unreached.
    case fault(SpoolFault)
}

/// One relay's connection as the plane runs it (ADR 2026-11.adrq, P4b1): the dial, the open session's bounds, and the
/// backoff. Pure, its times on the monotonic clock.
///
/// - **One dial at a time.** A relay is idle, dialing under a token with an open deadline, or open under that token. A
///   dial that does not open by ``openMilliseconds`` is dropped and counted unreached.
/// - **Reached** (this port's rule): a session that lasted ``reachedMilliseconds`` or ended a round that compared a scope
///   against the spool's anchor. Anything else (a hello followed by a close, a dial that failed or never opened, a session
///   this side ended for a fault, a write stall, a close refusing the client with 4000…4003) is a failure, and the backoff
///   grows (``SpoolBackoff``). A pause and a removal are neither.
/// - **Sends** are one in flight, the rest queued in the plane; ``queuedBytes`` counts both, and the heal holds its pushes
///   while it is at ``maxQueuedBytes``. Bytes queued with no send done for ``writeStallMilliseconds`` end the session.
internal struct SpoolLink: Sendable {
    /// How long a dial has to open.
    static let openMilliseconds: Int64 = 20_000
    /// How long a session lasts before it counts as reached.
    static let reachedMilliseconds: Int64 = 30_000
    /// How long queued bytes wait for a send to finish before the session ends as unresponsive.
    static let writeStallMilliseconds: Int64 = 30_000
    /// The most bytes queued to send before the heal holds its pushes.
    static let maxQueuedBytes = 1 << 20
    /// Close codes that refuse the client itself (malformed, auth, version, abuse): never a reached session.
    static let refusingCodes = SpoolCloseCode.malformed...SpoolCloseCode.abuse

    enum Phase: Sendable, Equatable {
        case idle
        case dialing(SpoolConnectionToken, openBy: Int64)
        case open(SpoolConnectionToken)
    }

    /// What it has done, for `status` and the log.
    struct Counts: Sendable, Equatable {
        var dials = 0
        var dialFailures = 0
        var dialTimeouts = 0
        var sessions = 0
        var reached = 0
        var unreached = 0
        var writeStalls = 0
        var sendFailures = 0
        var inboundDeferred = 0
        var textDropped = 0
        var stampsAnsweredOffline = 0
        var dropFaults = 0
    }

    var phase = Phase.idle
    var failures = 0
    /// When the next dial goes, while idle and not paused.
    var nextDialAt: Int64?
    var openedAt: Int64?
    /// The heal's compared rounds when the session opened.
    var roundsAtOpen = 0
    var queuedBytes = 0
    /// The size of the send in flight.
    var sending: Int?
    /// Since when bytes have waited with no send done.
    var stallFrom: Int64?
    var inbound = SpoolInboundBudget(now: 0)
    /// The records this connection dropped unread in the last minute.
    var drops = SpoolDropWindow()
    /// Whether the reader waits for the inbound budget.
    var readerParked = false
    var counts = Counts()

    /// The token of the dial or session in place.
    var token: SpoolConnectionToken? {
        switch phase {
        case .idle:
            nil
        case .dialing(let token, _), .open(let token):
            token
        }
    }

    /// The word `status` shows.
    var state: String {
        switch phase {
        case .idle:
            "idle"
        case .dialing:
            "dialing"
        case .open:
            "open"
        }
    }

    /// Whether a session that ended for `cause` at `now`, having compared `rounds` rounds in all, was reached.
    func reached(_ cause: SpoolSessionEnd, rounds: Int, now: Int64) -> Bool {
        switch cause {
        case .fault, .writeStall:
            return false
        case .socket(let end) where end.code.map(Self.refusingCodes.contains) == true:
            return false
        default:
            let lasted = openedAt.map { now >= SpoolSession.later($0, by: Self.reachedMilliseconds) } == true
            return lasted || rounds > roundsAtOpen
        }
    }

    /// The least wait before the next dial after a session that ends at `now` having lasted less than
    /// ``reachedMilliseconds``: the rest of those 30 s, whether or not the session was reached, so a relay is dialled at most
    /// once per 30 s while its sessions end early (this port's rule). `nil` once it lasted.
    func earlyEndFloor(now: Int64) -> Int64? {
        openedAt.flatMap { opened in
            let (lasted, overflow) = now.subtractingReportingOverflow(opened)
            return !overflow && lasted < Self.reachedMilliseconds ? Self.reachedMilliseconds - max(lasted, 0) : nil
        }
    }

    /// The deadline of the write stall, while bytes wait.
    var stallDeadline: Int64? {
        stallFrom.map { SpoolSession.later($0, by: Self.writeStallMilliseconds) }
    }
}

/// The records one connection dropped unread in the last minute (this port's rule, P4b1): more than ``maxRecords``, or more
/// than ``maxBytes`` of them, end the session as ``SpoolFault/dropped``, an unreached one, so the backoff grows. A record of
/// a type this build does not know is charged to the bytes alone, so a record type newer than this build never ends a
/// session by its count.
internal struct SpoolDropWindow: Sendable {
    /// The window.
    static let windowMilliseconds: Int64 = 60_000
    /// The most dropped records the window keeps a connection through: two whole pulls of the largest `maxPull` arriving
    /// late after a jump of the clock, each its blobs and its `ok`.
    static let maxRecords = latePulls * (SpoolLimits.maxPullCeiling + 1)
    /// How many whole late pulls the record bound leaves room for.
    static let latePulls = 2
    /// The most dropped bytes the window keeps a connection through.
    static let maxBytes = 4 << 20

    private struct Entry: Sendable {
        let at: Int64
        let bytes: Int
        let counted: Bool
    }

    private var entries: [Entry] = []
    private var bytes = 0
    private var records = 0

    /// Charges one dropped record of `count` bytes at `now`, to the record count too when `counted`. Answers whether the
    /// window is now past a bound.
    mutating func note(bytes count: Int, counted: Bool, now: Int64) -> Bool {
        while let first = entries.first, Self.hasLeft(first.at, now: now) {
            bytes -= first.bytes
            records -= first.counted ? 1 : 0
            entries.removeFirst()
        }
        entries.append(Entry(at: now, bytes: count, counted: counted))
        bytes += count
        records += counted ? 1 : 0
        return records > Self.maxRecords || bytes > Self.maxBytes
    }

    /// Whether a drop at `at` is out of the window at `now`: a minute old, or from a clock that has since gone back.
    private static func hasLeft(_ at: Int64, now: Int64) -> Bool {
        let (age, overflow) = now.subtractingReportingOverflow(at)
        return at > now || overflow || age >= windowMilliseconds
    }
}
