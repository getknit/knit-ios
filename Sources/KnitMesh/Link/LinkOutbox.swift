/// What waits to be written on one link, in order, holding at most one custody digest not yet written (knit-next ADR
/// 2026-09.tjfb, `FramedLink.kt:76` and `:148`). Both radios keep one per channel, so the rule lives here once and
/// not in each adapter (ADR 2026-09.6es2).
///
/// A digest is a snapshot of custody's live ids, so a newer one says everything an older one would. While one waits,
/// ``offerDigest(_:)`` swaps the newer record in where the older one stands, and a link busy with a back-fill writes
/// one current digest when it gets there, not one stale digest per 60 s tick ahead of every frame queued after. An
/// idle link writes each digest as it comes, so there the cadence and the bytes are what they were.
///
/// The slot only reaches as far as this queue: bytes already handed to the socket or the stream are the operating
/// system's, and go out as they were (`.agents/context/custody.md`).
///
/// A FILE record is marked too, so the radio can say when its last byte has left (``wrote(_:)``). The link manager
/// feeds a file one chunk at a time on that signal, and frames queued meanwhile go out between the chunks, as
/// Android's writer interleaves them (`FramedLink.drainFramesInto`, ADR 2026-10.nh55).
public struct LinkOutbox: Sendable {
    private enum Entry: Sendable {
        case bytes([UInt8])
        /// A digest none of whose bytes are written yet, so a newer one can still take its place.
        case digest([UInt8])
        /// A FILE record, whose last byte leaving the radio reports.
        case file([UInt8])

        var payload: [UInt8] {
            switch self {
            case .bytes(let bytes), .digest(let bytes), .file(let bytes):
                bytes
            }
        }

        var isDigest: Bool {
            if case .digest = self { true } else { false }
        }

        var isFile: Bool {
            if case .file = self { true } else { false }
        }
    }

    /// What waits, in order. At most one entry is a ``Entry/digest(_:)``: the first byte written from one turns it
    /// into ``Entry/bytes(_:)``, and ``offerDigest(_:)`` only adds one when none is left.
    private var entries: [Entry] = []
    /// How much of the first entry is already written.
    private var written = 0

    /// Every byte still waiting, the waiting digest's included.
    public private(set) var queuedBytes = 0

    /// An empty outbox.
    public init() {
        // Nothing waits yet.
    }

    /// Whether nothing waits.
    public var isEmpty: Bool { entries.isEmpty }

    /// Queues `bytes` behind everything queued before.
    public mutating func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else {
            return
        }
        entries.append(.bytes(bytes))
        queuedBytes += bytes.count
    }

    /// Queues a whole encoded FILE record behind everything queued before; ``wrote(_:)`` says when its last byte is
    /// out.
    public mutating func appendFileRecord(_ record: [UInt8]) {
        guard !record.isEmpty else {
            return
        }
        entries.append(.file(record))
        queuedBytes += record.count
    }

    /// Queues a whole encoded DIGEST record, or puts it in the place of the one still waiting. Answers whether it
    /// replaced one.
    ///
    /// A digest counts as waiting until its first byte is written: from then on its bytes are going out as they
    /// were, and a newer one queues behind it as a fresh record (`FramedLink.kt:365`).
    @discardableResult
    public mutating func offerDigest(_ record: [UInt8]) -> Bool {
        guard !record.isEmpty else {
            return false
        }
        queuedBytes += record.count
        // Once a minute per link, over a queue a back-fill leaves at most a few thousand entries long.
        guard let waiting = entries.lastIndex(where: \.isDigest) else {
            entries.append(.digest(record))
            return false
        }
        queuedBytes -= entries[waiting].payload.count
        entries[waiting] = .digest(record)
        return true
    }

    /// The next bytes to write, at most `limit` of them, all from one record or one ``append(_:)``: the rest of the
    /// first entry. Nil when nothing waits.
    public func next(atMost limit: Int) -> ArraySlice<UInt8>? {
        guard let head = entries.first?.payload else {
            return nil
        }
        return head[written..<min(head.count, written + max(1, limit))]
    }

    /// Records that the first `count` bytes ``next(atMost:)`` answered were written, and answers whether they finished
    /// a FILE record, which the radio then reports. The first byte written from a waiting digest fixes it, so a
    /// digest offered after that queues behind it.
    @discardableResult
    public mutating func wrote(_ count: Int) -> Bool {
        guard count > 0, let head = entries.first else {
            return false
        }
        let payload = head.payload
        if head.isDigest {
            entries[0] = .bytes(payload)
        }
        let taken = min(count, payload.count - written)
        written += taken
        queuedBytes -= taken
        guard written == payload.count else {
            return false
        }
        entries.removeFirst()
        written = 0
        return head.isFile
    }

    /// Drops everything waiting.
    public mutating func removeAll() {
        self = Self()
    }
}
