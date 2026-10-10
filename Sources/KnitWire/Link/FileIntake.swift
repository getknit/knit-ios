/// The receiving end of one link's file stream: FILE_HEADER, FILE_CHUNK and FILE_END records in, whole files out
/// (`FramedLink.kt:402-520` in knit-next, with `rxKey`, `rxOut` and `rxAborted`). It applies Android's receiver rules:
///
/// - **A header** starts a file. One that arrives mid-file drops the partial file first (`closeRx`, `:405`), and one
///   that does not decode leaves the file's chunks unread (`:404-410`).
/// - **A chunk** joins the file being kept. One with no file is ignored (`:428`), and one that takes the file past
///   its limit drops it, so its later chunks are ignored and its END yields nothing (`abortRx`, `:430-433`).
/// - **An END** finishes the file being kept. One with no file does nothing (`:444-458`).
/// - **The key** must be 64 lowercase hex characters (`:488`). Android writes the chunks of a malformed key to disk
///   and rejects the file at its END. This intake refuses the file at its header instead, which ends the same way
///   without holding the bytes.
///
/// - **A skipped file** is still counted as it streams by, whenever its header decoded with a well-formed key, so its
///   sender hears how much of it crossed (``reading``). Android keeps every file whose header decodes and reports it
///   (`FileIntake.kt:124-131`, `RxReports.kt:48-70`); this intake keeps the choice not to hold an attachment nobody
///   wants, or one past its limit, but reads it as Android would. A file that passes Android's ceiling is aborted there,
///   and reports nothing after (`abort`, `:308-318`), so it is not counted past it here either.
///
/// None of these drops the link. An unknown tag or an oversize record does, and that is ``LinkRecordReader``'s
/// error. Which files to keep, and how much of each, is the owner's call, made at each header. The hash check
/// over the bytes waits for the whole file and needs SHA-256, so it is the owner's too.
public struct FileIntake: Sendable {
    /// Android's ceiling on one incoming file, `MAX_INCOMING_FILE_BYTES` (`FramedLink.kt:539`): 8 MiB and 64 KiB.
    public static let maxFileBytes = 8_454_144

    /// What a record did to the file stream.
    public enum Event: Sendable, Equatable {
        /// A header whose file is being kept.
        case begun(FileHeader)
        /// A header whose file is not kept, because it did not decode, its key is malformed, or the owner refused it.
        /// Its chunks are dropped as they come.
        case skipped(FileHeader?)
        /// A kept file dropped before its END, for passing its limit or being cut off by another header.
        case abandoned(FileHeader)
        /// A kept file, whole.
        case finished(FileHeader, BlobHash, [UInt8])
    }

    /// A file streaming in as its sender is told of it: its key, the bytes read so far, kept or skipped, and the size its
    /// header declared (`ArrivingFile`), `nil` when it declared none, or one past the ceiling.
    public struct Reading: Sendable, Equatable {
        /// The key its header named.
        public var key: BlobHash
        /// The bytes read so far.
        public var bytes: Int
        /// The size its header declared.
        public var total: Int?

        /// A reading.
        public init(key: BlobHash, bytes: Int, total: Int?) {
            self.key = key
            self.bytes = bytes
            self.total = total
        }
    }

    private enum State: Sendable {
        case idle
        case keeping(FileHeader, BlobHash, limit: Int, bytes: [UInt8])
        /// A file not kept: counted, unless its header did not decode, its key is malformed, or it passed the ceiling.
        case skipping(Reading?)
    }

    private var state = State.idle

    /// An intake with no file streaming.
    public init() {
        // Nothing streams yet.
    }

    /// The key of the file being kept, whose END has not arrived (`rxKey`, which `arrivingFiles()` reads).
    public var arriving: BlobHash? {
        if case .keeping(_, let key, _, _) = state { key } else { nil }
    }

    /// Whether a file is streaming in: its header is in and its END is not, whether its bytes are kept or skipped
    /// (`FramedLink.rxInProgress`, which `fileArrivingFrom` reads, knit-next ADR 2026-10.nxfb). Android keeps every file
    /// that decodes, so its own read is the kept file alone. This intake skips an attachment nobody asked for, and a
    /// skipped file holds the link just the same: whatever the peer sends next waits behind it.
    public var isStreaming: Bool {
        if case .idle = state { false } else { true }
    }

    /// The file streaming in, kept or skipped, as its sender is told of it (`FramedLink.rxFile`): `nil` with none, and
    /// for one whose header did not decode, whose key is malformed, or that passed ``maxFileBytes``.
    public var reading: Reading? {
        switch state {
        case .idle:
            nil
        case .keeping(let header, let key, _, let bytes):
            Reading(key: key, bytes: bytes.count, total: Self.declared(header))
        case .skipping(let counted):
            counted
        }
    }

    /// The size `header` declared, when it is one a file may have (`FileIntake.begin`): a size past the ceiling
    /// describes a stream that is aborted anyway, so it is no size at all.
    private static func declared(_ header: FileHeader) -> Int? {
        header.size.flatMap { (1...maxFileBytes).contains($0) ? $0 : nil }
    }

    /// The bytes of the file being kept, so far.
    public var bufferedBytes: Int {
        if case .keeping(_, _, _, let bytes) = state { bytes.count } else { 0 }
    }

    /// A FILE_HEADER. `limit` names the most bytes to keep of this file, or `nil` to drop it. It is asked only for a
    /// header that decodes with a well-formed key, and is held to ``maxFileBytes``.
    public mutating func header(_ payload: [UInt8], limit: (FileHeader, BlobHash) -> Int?) -> [Event] {
        var events: [Event] = []
        if case .keeping(let cut, _, _, _) = state {
            events.append(.abandoned(cut))
        }
        let decoded = LinkJSON.fileHeader(from: payload)
        guard let header = decoded, let key = BlobHash(header.key) else {
            state = .skipping(nil)
            return events + [.skipped(decoded)]
        }
        guard let most = limit(header, key) else {
            state = .skipping(Reading(key: key, bytes: 0, total: Self.declared(header)))
            return events + [.skipped(decoded)]
        }
        state = .keeping(header, key, limit: min(most, Self.maxFileBytes), bytes: [])
        return events + [.begun(header)]
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
        guard case .keeping(let header, let key, let limit, var bytes) = state else {
            return nil
        }
        let read = bytes.count + payload.count
        guard read <= min(limit, room) else {
            // Past the limit this port sets, the file is read on as a skipped one; past Android's ceiling, it is not.
            state = .skipping(read <= Self.maxFileBytes ? Reading(key: key, bytes: read, total: Self.declared(header)) : nil)
            return .abandoned(header)
        }
        // Released first so the append grows the one buffer in place, not a copy of it.
        state = .idle
        bytes += payload
        state = .keeping(header, key, limit: limit, bytes: bytes)
        return nil
    }

    /// A FILE_END.
    public mutating func end() -> Event? {
        defer { state = .idle }
        guard case .keeping(let header, let key, _, let bytes) = state else {
            return nil
        }
        return .finished(header, key, bytes)
    }

    /// Drops any partial file, as a closed link does (`FramedLink.kt:183-190`).
    public mutating func reset() {
        state = .idle
    }
}
