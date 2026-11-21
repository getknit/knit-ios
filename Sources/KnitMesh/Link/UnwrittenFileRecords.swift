/// The FILE records a feed handed a radio that reports writes (``Radio/reportsFileWrites``) and that have not yet left
/// the link, oldest first: what ``LinkManager/queuedFrameBytes(to:)`` takes out of a link's unwritten bytes, so a file
/// streaming to a peer counts as the file's, not as frames (the `custody-carry-policy` contract, §2's "Unwritten": a
/// file's own bytes aren't counted).
///
/// Two questions, kept apart. Whether the radio has **reported** a record out (``RadioEvent/wroteFileRecord(_:)``) gates
/// the feed: the next record waits until every one is reported (``allReported``), as it always has.
/// Whether a record is **sent** is what is subtracted: BlueZ reports a record once its socket takes the last byte, while
/// the socket still holds all of it (``OutboxLevel/belowBytes``), so a reported record stays here until what has left the
/// socket passes its end. Dropped at its report, its bytes in the socket would read as frames, a windowed feed's up to
/// 64 KiB, and hold custody's rounds off until the file ended (bluetooth-reviewer, contract revision 15). Where
/// ``OutboxLevel/belowBytes`` is always 0, as on CoreBluetooth, a record is sent once it is written, so a reported one
/// adds nothing and goes at the next prune.
///
/// Each record keeps where its last byte stands in the channel's byte order: the radio's ``OutboxLevel/writtenBytes``
/// plus its ``OutboxLevel/queuedBytes`` read just after the hand-off, since both radios count a write at their entry
/// points before it hops to their queue (``OutboxLevels``), and their ``LinkOutbox`` writes in order. Against a later
/// level that answers how much of the record is still unsent: past ``OutboxLevel/writtenBytes`` less what the socket
/// still holds, which goes out in the same order. So a chunk half out, or out and not yet reported, or in the socket,
/// leaves only its unsent bytes out of the count. Counting the whole record until its report would hide as many frame
/// bytes as the record had sent, up to a 16,384-byte chunk, one round: an answer would then go out over close to two
/// rounds of frames, where the contract's line allows under one.
///
/// What it errs by, each way toward holding the answer: a level read before the record counted (no radio does today)
/// places its end early, and a waiting digest that a larger one replaced ahead of it moves its end later than kept.
/// The one way it errs low is a digest ahead of it replaced by a smaller one, which hides that difference, a few ids'
/// bytes. A file's header goes as plain writes the radio does not report, so its couple of hundred bytes count as
/// frames.
///
/// Kept per link, past the stream that wrote them, so the last chunk and the END of a file the socket still holds stay
/// the file's after its stream ends; they go with the link (``LinkManager/retire(_:backingOff:now:)``, `stop`).
internal struct UnwrittenFileRecords: Equatable {
    /// One record handed over and not yet sent: its bytes, the channel position its last byte ends at, and whether the
    /// radio has reported it.
    struct Record: Equatable {
        let bytes: Int
        let end: Int64
        var reported = false
    }

    /// The most records kept. The feed's window bounds them (64 KiB at most, `FeedWindow.maxWindowBytes`, four chunks)
    /// beside what a socket holds, about 208 KiB at Linux's default buffer, so 32 chunks of 16 KiB is past both. The cap
    /// is there for a socket whose reading never drains, which must not grow this without end: past it the oldest
    /// reported record goes, and its bytes, if any are still in the socket, count as frames, which only holds a round.
    static let maximumKept = 32

    /// The records handed over and not yet sent, oldest first. The reported ones come first, since the radio reports in
    /// order, and a feed hands the next only once the last is reported, so at most one is unreported.
    private(set) var records: [Record] = []

    /// Whether none is out unreported, so the feed's next record may go.
    var allReported: Bool { records.allSatisfy(\.reported) }

    /// Nothing handed over.
    init() {
        // A feed starts with nothing out.
    }

    /// A record of `bytes` was handed to the radio, whose level reads `level` just after. Its end is at least `bytes` past
    /// what was written, so a level that has not counted it yet still places all of it unwritten. Prunes what `level`
    /// shows sent first.
    mutating func handed(_ bytes: Int, level: OutboxLevel) {
        prune(level)
        guard bytes > 0 else {
            return
        }
        records.append(Record(bytes: bytes, end: level.writtenBytes + Int64(max(level.queuedBytes, bytes))))
        while records.count > Self.maximumKept, let oldest = records.firstIndex(where: \.reported) {
            records.remove(at: oldest)
        }
    }

    /// The radio reported the oldest unreported record's last byte out, with its level reading `level`: the record is
    /// kept until `level` shows it sent. A report with nothing out changes nothing.
    mutating func reported(level: OutboxLevel) {
        if let oldest = records.firstIndex(where: { !$0.reported }) {
            records[oldest].reported = true
        }
        prune(level)
    }

    /// Drops every reported record `level` shows sent. An unreported one stays whatever the level says, so the feed's
    /// gate is the report alone.
    mutating func prune(_ level: OutboxLevel) {
        let sent = Self.sent(level)
        records.removeAll { $0.reported && $0.end <= sent }
    }

    /// Of `level`'s unwritten bytes (``OutboxLevel/unwrittenBytes``), those of the records here that are still unsent:
    /// each record's end less what has left the socket, from 0 to its bytes, and never more than `level` holds.
    func fileBytes(of level: OutboxLevel) -> Int {
        let sent = Self.sent(level)
        let unsent = records.reduce(0) { sum, record in
            sum + Int(min(Int64(record.bytes), max(0, record.end - sent)))
        }
        return min(unsent, level.unwrittenBytes)
    }

    /// `level`'s unwritten bytes less the records' unsent bytes: what waits that is not a file's. Never below zero.
    func frameBytes(of level: OutboxLevel) -> Int {
        max(0, level.unwrittenBytes - fileBytes(of: level))
    }

    /// The channel position everything before has left the link by: what was written, less what the socket still holds.
    private static func sent(_ level: OutboxLevel) -> Int64 {
        max(0, level.writtenBytes - Int64(max(0, level.belowBytes)))
    }
}
