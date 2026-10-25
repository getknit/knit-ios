/// The receiving end of one link's file stream: FILE_HEADER, FILE_CHUNK and FILE_END records in, whole files out
/// (`FramedLink.kt:402-520` in knit-next, with `rxKey`, `rxOut` and `rxAborted`, and `FileIntake.kt` since its ADR
/// 2026-10.wtyc). It applies Android's receiver rules:
///
/// - **A header** starts a file. One that arrives mid-file drops the partial file first (`closeRx`, `:405`), and one
///   that does not decode leaves the file's chunks unread (`:404-410`).
/// - **A chunk** joins the file being kept. One with no file is ignored (`:428`), and one that takes the file past
///   its limit drops it, so its later chunks are ignored and its END yields nothing (`abortRx`, `:430-433`).
/// - **An END** finishes the file being kept. One with no file does nothing (`:444-458`).
/// - **The key** must be 64 lowercase hex characters (`:488`). Android writes the chunks of a malformed key to disk
///   and rejects the file at its END. This intake refuses the file at its header instead, which ends the same way
///   without holding the bytes.
/// - **A cut** (``cut()``) hands an attachment's bytes to its owner, which keeps them as a prefix, and a header whose
///   `offset` names how many the asker kept splices the rest onto a copy of them (`FileIntake.kt:134-159`, `:232-243`,
///   knit-ios #2). An avatar is pushed, never asked for, so it is never kept or resumed. A key resumes at most once per
///   ``resumeWindowMilliseconds`` on one link, since each resume reads up to 8 MiB of kept prefix for a header of about
///   100 bytes (knit-next #161, `FileIntake.kt:120-123`, `:309-313`). The prefix is read into this intake's own buffer,
///   so it counts against the room every link's partial files share.
///
/// - **A skipped file** is still counted as it streams by, whenever its header decoded with a well-formed key, so its
///   sender hears how much of it crossed (``reading``). Android keeps every file whose header decodes and reports it
///   (`FileIntake.kt:124-131`, `RxReports.kt:48-70`); this intake keeps the choice not to hold an attachment nobody
///   wants, or one past its limit, but reads it as Android would. A file that passes Android's ceiling is aborted there,
///   and reports nothing after (`abort`, `:308-318`), so it is not counted past it here either. A resumed stream skipped
///   or refused is counted from its offset, as an Android sender's window reads a report (`FeedWindow.kt:210-215`), where
///   Android's own receiver reports nothing of it.
///
/// None of these drops the link. An unknown tag or an oversize record does, and that is ``LinkRecordReader``'s
/// error. Which files to keep, and how much of each, is the owner's call, made at each header, and so are the kept
/// prefixes, read through the header's `prefix`. The hash check over the bytes waits for the whole file and needs
/// SHA-256, so it is the owner's too.
public struct FileIntake: Sendable {
    /// Android's ceiling on one incoming file, `MAX_INCOMING_FILE_BYTES` (`FramedLink.kt:539`): 8 MiB and 64 KiB.
    public static let maxFileBytes = 8_454_144
    /// The shortest gap between two resumes of one key on one link (`RESUME_WINDOW_MS`, `FileIntake.kt:354`, knit-next
    /// #161): `BlobExchange.ROUND_MS`, the serve memo. An honest holder sends one at most once a round, a cut closes the
    /// link and the next has an intake of its own, and a failed splice is asked for again from byte 0, a whole file.
    public static let resumeWindowMilliseconds: Int64 = 45_000

    /// What a record did to the file stream.
    public enum Event: Sendable, Equatable {
        /// A header whose file is being kept, from its offset when it resumes one.
        case begun(FileHeader)
        /// A header whose file is not kept, because it did not decode, its key is malformed, or the owner refused it.
        /// Its chunks are dropped as they come.
        case skipped(FileHeader?)
        /// A header that resumes a cut transfer, refused before its prefix was read, and why. Its chunks are dropped.
        case refused(FileHeader, Refusal)
        /// A kept file dropped before its END, for passing its limit or being cut off by another header.
        case abandoned(FileHeader)
        /// A kept file, whole, and the byte its stream started at: 0, or the kept prefix it was spliced onto.
        case finished(FileHeader, BlobHash, [UInt8], resumedFrom: Int)
    }

    /// Why a resumed header was refused (`FileIntake.kt:144-151`).
    public enum Refusal: Sendable, Equatable {
        /// The key resumed on this link this long ago, inside ``resumeWindowMilliseconds``.
        case resumedRecently(milliseconds: Int64)
        /// Fewer bytes are kept than the offset names, or none can be: the header is no attachment's, or its offset is
        /// outside `1...maxFileBytes`.
        case notKept
        /// The kept prefix would not fit in the room the owner has for partial files now.
        case noRoom
    }

    /// A file streaming in as its sender is told of it: its key, the bytes read so far, kept or skipped, and the size its
    /// header declared (`ArrivingFile`), `nil` when it declared none, or one past the ceiling. A resumed stream counts its
    /// kept prefix in both (`FileIntake.kt:178-184`), and says where it started.
    public struct Reading: Sendable, Equatable {
        /// The key its header named.
        public var key: BlobHash
        /// The bytes read so far, from the blob's first: a resumed stream's offset, and the tail in since.
        public var bytes: Int
        /// The size its header declared: the offset and the tail for a resumed stream.
        public var total: Int?
        /// The byte the stream started at: 0, or a resumed stream's offset.
        public var from: Int

        /// A reading.
        public init(key: BlobHash, bytes: Int, total: Int?, from: Int = 0) {
            self.key = key
            self.bytes = bytes
            self.total = total
            self.from = from
        }
    }

    /// An attachment a cut link was keeping (``cut()``): its key, its bytes from the blob's first, and the epoch of the
    /// prefix it was spliced onto, `nil` for a stream from byte 0 (`PartialBlobs.keep`'s `basedOn`).
    public struct Cut: Sendable, Equatable {
        /// The key its header named.
        public var key: BlobHash
        /// The bytes in, a resumed stream's prefix included.
        public var bytes: [UInt8]
        /// The epoch of the prefix it was spliced onto.
        public var basedOn: Int?
    }

    /// A file being kept: its bytes from the blob's first, a resumed stream's prefix included, the byte the stream started
    /// at, and the epoch of the prefix it was spliced onto.
    private struct Kept: Sendable {
        var header: FileHeader
        var key: BlobHash
        var limit: Int
        var from: Int
        var basedOn: Int?
        var bytes: [UInt8]

        var reading: Reading {
            Reading(key: key, bytes: bytes.count, total: FileIntake.declared(header, from: from), from: from)
        }
    }

    private enum State: Sendable {
        case idle
        case keeping(Kept)
        /// A file not kept: counted, unless its header did not decode, its key is malformed, or it passed the ceiling.
        case skipping(Reading?)
    }

    private var state = State.idle
    /// Each key's last resume on this link, on the monotonic clock (`resumedAt`, #161). An entry goes in only when a
    /// prefix was read, at most one per kept prefix, and leaves once it ages out of the window.
    private var resumedAt: [BlobHash: Int64] = [:]

    /// An intake with no file streaming.
    public init() {
        // Nothing streams yet.
    }

    /// The key of the file being kept, whose END has not arrived (`rxKey`, which `arrivingFiles()` reads).
    public var arriving: BlobHash? {
        if case .keeping(let kept) = state { kept.key } else { nil }
    }

    /// Whether a file is streaming in: its header is in and its END is not, whether its bytes are kept or skipped
    /// (`FramedLink.rxInProgress`, which `fileArrivingFrom` reads, knit-next ADR 2026-10.nxfb). Android keeps every file
    /// that decodes, so its own read is the kept file alone. This intake skips an attachment nobody asked for, and a
    /// skipped file holds the link just the same: whatever the peer sends next waits behind it.
    public var isStreaming: Bool {
        if case .idle = state { false } else { true }
    }

    /// The file streaming in, kept or skipped, as its sender is told of it (`FramedLink.rxFile`): `nil` with none, and
    /// for one whose header did not decode, whose key is malformed, that resumes from an offset outside
    /// `1...maxFileBytes`, or that passed ``maxFileBytes``.
    public var reading: Reading? {
        switch state {
        case .idle:
            nil
        case .keeping(let kept):
            kept.reading
        case .skipping(let counted):
            counted
        }
    }

    /// The whole blob's size `header` declared, when it is one a file may have (`FileIntake.begin` and `install`): the
    /// size alone from byte 0, and the offset and the tail's size for a resumed stream. A size past the ceiling describes
    /// a stream that is aborted anyway, so it is no size at all. Each part is bounded before the sum, so no claim traps.
    private static func declared(_ header: FileHeader, from: Int) -> Int? {
        guard let size = header.size else {
            return nil
        }
        guard from > 0 else {
            return (1...maxFileBytes).contains(size) ? size : nil
        }
        guard (0...maxFileBytes).contains(size), (1...maxFileBytes).contains(from) else {
            return nil
        }
        return (1...maxFileBytes).contains(from + size) ? from + size : nil
    }

    /// The bytes of the file being kept, so far, a resumed stream's prefix included.
    public var bufferedBytes: Int {
        if case .keeping(let kept) = state { kept.bytes.count } else { 0 }
    }

    /// A FILE_HEADER, at `now` on the monotonic clock. `limit` names the most bytes to keep of this file, the whole blob's,
    /// or `nil` to drop it. It is asked only for a header that decodes with a well-formed key, and is held to
    /// ``maxFileBytes``. A header that resumes a cut transfer from an offset is refused in Kotlin's order
    /// (`FileIntake.kt:134-159`), each step before the next: an ATTACHMENT's, with an offset in `1...maxFileBytes`; not
    /// resumed on this link inside ``resumeWindowMilliseconds``; wanted, by `limit`; with `room`, the owner's room for
    /// partial files now, for the prefix; and only then read, through `prefix`, which answers exactly the offset's bytes
    /// and the epoch they belong to, or `nil`. A whole file, and an explicit offset 0, is never gated.
    public mutating func header(
        _ payload: [UInt8],
        room: Int = .max,
        limit: (FileHeader, BlobHash) -> Int?,
        prefix: (BlobHash, Int) -> (bytes: [UInt8], basedOn: Int)?,
        now: Int64
    ) -> [Event] {
        var events: [Event] = []
        if case .keeping(let cut) = state {
            events.append(.abandoned(cut.header))
        }
        // Released before a prefix is read, so the file it interrupts never shares the room with it.
        state = .idle
        let decoded = LinkJSON.fileHeader(from: payload)
        guard let header = decoded, let key = BlobHash(header.key) else {
            state = .skipping(nil)
            return events + [.skipped(decoded)]
        }
        // No offset is a whole file, and so is an explicit 0: a stream from the first byte splices onto nothing
        // (`FileIntake.kt:137-143`).
        let offset = header.offset ?? 0
        if offset != 0, let why = refusal(header, key, offset: offset, now: now) {
            state = .skipping(Self.skipped(header, key, from: offset))
            return events + [.refused(header, why)]
        }
        guard let most = limit(header, key) else {
            state = .skipping(Self.skipped(header, key, from: offset))
            return events + [.skipped(decoded)]
        }
        let cap = min(most, Self.maxFileBytes)
        guard offset != 0 else {
            state = .keeping(Kept(header: header, key: key, limit: cap, from: 0, basedOn: nil, bytes: []))
            return events + [.begun(header)]
        }
        // Read only now, and only when the room holds it (#161: a read is the cost the window bounds).
        let why: Refusal = offset <= min(cap, room) ? .notKept : .noRoom
        guard why == .notKept, let kept = prefix(key, offset), kept.bytes.count == offset else {
            state = .skipping(Self.skipped(header, key, from: offset))
            return events + [.refused(header, why)]
        }
        resumedAt[key] = now
        state = .keeping(Kept(header: header, key: key, limit: cap, from: offset, basedOn: kept.basedOn, bytes: kept.bytes))
        return events + [.begun(header)]
    }

    /// Why a resumed header is refused before the owner is asked: one no attachment's, or with an offset outside
    /// `1...maxFileBytes`, has nothing kept, and one inside the window is gated (#161).
    private mutating func refusal(_ header: FileHeader, _ key: BlobHash, offset: Int, now: Int64) -> Refusal? {
        guard header.kind == .attachment, (1...Self.maxFileBytes).contains(offset) else {
            return .notKept
        }
        return resumedRecently(key, now: now).map { .resumedRecently(milliseconds: $0) }
    }

    /// A file not kept, read from the byte it starts at, so an Android sender's window, which takes a resumed stream's
    /// offset off a report, hears of the tail; none for an offset no file may have.
    private static func skipped(_ header: FileHeader, _ key: BlobHash, from: Int) -> Reading? {
        (0...maxFileBytes).contains(from) ? Reading(key: key, bytes: from, total: declared(header, from: from), from: from) : nil
    }

    /// How long ago `key` resumed on this link, when inside ``resumeWindowMilliseconds``, after the entries past it are
    /// pruned (`resumedRecently`, `FileIntake.kt:309-313`).
    private mutating func resumedRecently(_ key: BlobHash, now: Int64) -> Int64? {
        resumedAt = resumedAt.filter { now - $0.value < Self.resumeWindowMilliseconds }
        return resumedAt[key].map { now - $0 }
    }

    /// A FILE_CHUNK. `room` is how many bytes the file may hold in all right now, which the owner may lower below the
    /// limit it gave at the header, to keep partial files on every link within one budget.
    /// A chunk of a file skipped is counted, and the count stops at ``maxFileBytes``, where Android aborts the file.
    public mutating func chunk(_ payload: [UInt8], room: Int = .max) -> Event? {
        if case .skipping(var counted?) = state {
            counted.bytes += payload.count
            state = .skipping(counted.bytes <= Self.maxFileBytes ? counted : nil)
            return nil
        }
        guard case .keeping(var kept) = state else {
            return nil
        }
        let read = kept.bytes.count + payload.count
        guard read <= min(kept.limit, room) else {
            // Past the limit this port sets, the file is read on as a skipped one; past Android's ceiling, it is not.
            var counted = kept.reading
            counted.bytes = read
            state = .skipping(read <= Self.maxFileBytes ? counted : nil)
            return .abandoned(kept.header)
        }
        // Released first so the append grows the one buffer in place, not a copy of it.
        state = .idle
        kept.bytes += payload
        state = .keeping(kept)
        return nil
    }

    /// A FILE_END.
    public mutating func end() -> Event? {
        defer { state = .idle }
        guard case .keeping(let kept) = state else {
            return nil
        }
        return .finished(kept.header, kept.key, kept.bytes, resumedFrom: kept.from)
    }

    /// The link was cut mid-file (`FileIntake.cut`, `FileIntake.kt:232-243`): an attachment being kept is handed over, its
    /// bytes from the blob's first and the epoch of the prefix it was spliced onto, `nil` for a stream from byte 0, for the
    /// owner to keep as a prefix. An avatar, a skipped file or one aborted at its limit gives `nil`. Either way the intake
    /// is idle after. The buffer leaves the intake before it is handed on, so it moves rather than copies, as ``chunk(_:room:)``
    /// grows it (ADR 2026-10.eyad's trap).
    public mutating func cut() -> Cut? {
        guard case .keeping(let kept) = state else {
            state = .idle
            return nil
        }
        state = .idle
        return kept.header.kind == .attachment ? Cut(key: kept.key, bytes: kept.bytes, basedOn: kept.basedOn) : nil
    }

    /// Drops any partial file, keeping nothing (`FramedLink.kt:183-190`).
    public mutating func reset() {
        state = .idle
    }
}
