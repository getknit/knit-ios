import KnitSync
public import KnitWire

/// A kept prefix opened for a resume (`PartialBlobs.Prefix`): exactly the bytes asked for, from the blob's first, and the
/// epoch a later ``PartialBlobStore/keep(_:bytes:basedOn:now:)`` of a stream spliced onto them must still match.
public struct KeptPrefix: Sendable, Equatable {
    /// The prefix's first bytes, as many as the resume's offset names.
    public var bytes: [UInt8]
    /// The lineage these bytes belong to (``PartialBlobBook``).
    public var epoch: Int

    /// A prefix of `bytes`, of lineage `epoch`.
    public init(bytes: [UInt8], epoch: Int) {
        self.bytes = bytes
        self.epoch = epoch
    }
}

/// The first bytes of attachments a link drop cut off, kept so the next ask resumes where the bytes stopped instead of at
/// byte 0 (`PartialBlobs.kt` in knit-next, ADR 2026-10.wtyc there, knit-ios #2). A link at the edge of range can drop every
/// few minutes, and a large photo that started over each time could fail forever while both phones paid for the airtime.
///
/// A link's ``FileIntake`` hands an attachment's bytes here when the link is cut mid-stream (``keep(_:bytes:basedOn:now:)``).
/// The engine asks with the kept length as the `blobreq` offset (``length(_:)``), a holder that reads it streams the tail,
/// and the next intake splices that tail onto a copy of the prefix (``open(_:offset:)``). A blob's bytes are the same at
/// every holder, so any holder can finish what another began, and the whole file is still checked against its hash before
/// it is stored: a bad splice costs one tail, never a wrong blob.
///
/// Session-scoped: ``purge()`` runs at every mesh start and stop. The link manager and the engine hold the one store, so a
/// reference type, as ``BlobStore`` is. The rules live in ``PartialBlobBook``, which both stores apply.
public protocol PartialBlobStore: AnyObject, Sendable {
    /// How many bytes of `hash` are kept: the offset to ask a holder for, or 0 with nothing to resume. Read from the book in
    /// memory, never from disk.
    func length(_ hash: BlobHash) -> Int

    /// Exactly the first `offset` bytes of `hash`'s kept prefix and its epoch, or `nil` when fewer are kept, `offset` is
    /// below 1, or the bytes will not read, which retires the prefix.
    func open(_ hash: BlobHash, offset: Int) -> KeptPrefix?

    /// A link was cut with `bytes` the first of `hash`'s: keeps them when they are the longest prefix held, and answers
    /// whether it did. `basedOn` is the epoch of the prefix a resumed stream was spliced onto, `nil` for a stream from byte
    /// 0: a prefix dropped since is never kept again. `now` is the monotonic clock, which the TTL runs on.
    @discardableResult
    func keep(_ hash: BlobHash, bytes: [UInt8], basedOn: Int?, now: Int64) -> Bool

    /// Drops `hash`'s prefix and retires its epoch, and answers whether a prefix went: the blob landed, or a spliced file
    /// failed its hash and the prefix may be what was wrong.
    @discardableResult
    func drop(_ hash: BlobHash) -> Bool

    /// Drops the prefixes kept longer than the TTL ago, then those whose blob `isHeld` says we hold now, and answers how
    /// many. `isHeld` runs outside the store's lock.
    @discardableResult
    func sweep(now: Int64, isHeld: (BlobHash) -> Bool) -> Int

    /// Deletes every prefix, a dead session's leftovers on disk included.
    func purge()
}

/// The rules of the kept prefixes, without their bytes (`PartialBlobs.kt:38-215`): which copy is kept, which is evicted,
/// and the epochs that keep a dropped prefix from coming back. ``MemoryPartialBlobStore`` and `FilePartialBlobStore` both
/// apply it, so a rule cannot land in one store only.
///
/// - **Keep-the-longer.** A copy is kept only when it is strictly longer than what is kept, so a holder that ignores the
///   offset and streams from 0, cut short, never costs a longer prefix someone else delivered.
/// - **Epochs.** A drop, a sweep or a failed open retires the hash's epoch, so a resumed copy still streaming when its
///   sibling failed the hash check cannot bring the bad prefix back when it is cut too. A copy from byte 0 owes no epoch.
///   An eviction is no verdict on the bytes, and retires nothing. Values come from one counter and are never reused, and at
///   most ``maxEpochs`` are remembered in access order, so a hash whose epoch was forgotten reads as having none and a copy
///   built on it is refused.
/// - **Bounded.** At most ``Limits/maxCount`` prefixes and ``Limits/maxBytes`` in all, the oldest kept evicted first, none
///   under ``Limits/minBytes``.
public struct PartialBlobBook: Sendable {
    /// The bounds (`PartialBlobs.kt:197-209`). Android's are the defaults; a test may tighten them.
    public struct Limits: Sendable, Equatable {
        /// The shortest prefix worth a file (`MIN_BYTES`): below it a restart costs little even at 1 KiB/s.
        public var minBytes: Int
        /// The most prefixes kept at once (`MAX_COUNT`): a few photos cut at once is the realistic worst case.
        public var maxCount: Int
        /// The most bytes kept in all (`MAX_BYTES`): four ceiling-sized attachments.
        public var maxBytes: Int
        /// How long a prefix is kept after it was last kept (`TTL_MS`), on the monotonic clock where Android reads the wall
        /// clock: the prefixes are purged at every start, so only time inside one process counts.
        public var ttlMilliseconds: Int64

        /// Bounds, Android's unless given.
        public init(
            minBytes: Int = PartialBlobBook.minBytes, maxCount: Int = PartialBlobBook.maxCount, maxBytes: Int = PartialBlobBook.maxBytes,
            ttlMilliseconds: Int64 = PartialBlobBook.ttlMilliseconds
        ) {
            self.minBytes = minBytes
            self.maxCount = maxCount
            self.maxBytes = maxBytes
            self.ttlMilliseconds = ttlMilliseconds
        }
    }

    /// Android's `MIN_BYTES`: 16 KiB.
    public static let minBytes = 16_384
    /// Android's `MAX_COUNT`.
    public static let maxCount = 8
    /// Android's `MAX_BYTES`: 32 MiB.
    public static let maxBytes = 33_554_432
    /// Android's `TTL_MS`: an hour.
    public static let ttlMilliseconds: Int64 = 3_600_000
    /// The most epochs remembered (`MAX_EPOCHS`): they need only outlive the copies in flight on them.
    public static let maxEpochs = 64
    /// How much of a hash the log shows (`LOG_HASH`).
    static let shownHashCharacters = 12

    private struct Entry: Sendable {
        var length: Int
        var keptAt: Int64
    }

    /// The bounds this book keeps to.
    public let limits: Limits
    private var entries: [BlobHash: Entry] = [:]
    /// The kept hashes in the order they were kept, a replacement moved to the back: the front is evicted first.
    private var keptOrder: [BlobHash] = []
    private var epochs: [BlobHash: Int] = [:]
    /// The hashes with an epoch, least recently used first (an access-ordered `LinkedHashMap` on Android).
    private var epochOrder: [BlobHash] = []
    private var nextEpoch = 0
    private var lines: [String] = []
    private var discarded: [BlobHash] = []

    /// An empty book with `limits`.
    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// How many bytes of `hash` are kept, or 0.
    public func length(_ hash: BlobHash) -> Int {
        entries[hash]?.length ?? 0
    }

    /// The hashes kept, oldest first.
    public var hashes: [BlobHash] { keptOrder }

    /// What the store owes since the last call: the log lines, in Android's words (`partial <h12> kept <n>B`, `dropped`,
    /// `evicted`, `stale, not kept`), and the prefixes whose bytes are to go, retired or evicted, in that order.
    public mutating func takeOwed() -> (lines: [String], discarded: [BlobHash]) {
        defer {
            lines.removeAll()
            discarded.removeAll()
        }
        return (lines, discarded)
    }

    /// Opens `hash` at `offset` (`open`): `read` must answer exactly `offset` bytes from the first, or the prefix is retired
    /// and its bytes owed to go. Kotlin retires only when the file will not open; a short read here is the same loss, and
    /// a prefix that read short once would read short at every resume.
    public mutating func open(_ hash: BlobHash, offset: Int, read: (Int) -> [UInt8]?) -> KeptPrefix? {
        guard offset >= 1, let entry = entries[hash], entry.length >= offset else {
            return nil
        }
        guard let bytes = read(offset), bytes.count == offset else {
            _ = retire(hash)
            return nil
        }
        return KeptPrefix(bytes: bytes, epoch: epochOrMint(hash))
    }

    /// Keeps a cut copy of `hash` of `length` bytes if the rules allow (`keep`, then `install`), in Kotlin's order: a copy
    /// on a retired epoch, one under the floor and one no longer than what is kept go no further. `write` then puts its
    /// bytes in place of any kept before, and answers whether it did; nothing is installed when it does not. Answers
    /// whether it was kept. What it evicts is owed to go.
    public mutating func keep(_ hash: BlobHash, length: Int, basedOn: Int?, now: Int64, write: () -> Bool) -> Bool {
        if let basedOn, touchEpoch(hash) != basedOn {
            lines.append(Self.line(hash, "stale, not kept"))
            return false
        }
        guard length >= limits.minBytes, length > self.length(hash), write() else {
            return false
        }
        if entries.removeValue(forKey: hash) != nil {
            keptOrder.removeAll { $0 == hash }
        }
        entries[hash] = Entry(length: length, keptAt: now)
        keptOrder.append(hash)
        _ = epochOrMint(hash)
        lines.append(Self.line(hash, "kept \(length)B"))
        evict()
        return true
    }

    /// Drops `hash`'s prefix and retires its epoch (`drop`). Answers whether a prefix went.
    public mutating func drop(_ hash: BlobHash) -> Bool {
        let removed = retire(hash)
        if removed {
            lines.append(Self.line(hash, "dropped"))
        }
        return removed
    }

    /// Retires every prefix kept more than the TTL before `now` (`sweep`'s first half), and answers how many.
    public mutating func expire(now: Int64) -> Int {
        let stale = keptOrder.filter { hash in entries[hash].map { now - $0.keptAt > limits.ttlMilliseconds } == true }
        for hash in stale {
            _ = retire(hash)
        }
        return stale.count
    }

    /// Removes `hash`'s prefix, if any, owing its bytes, and gives its lineage a fresh epoch (`retire`). Answers whether a
    /// prefix went.
    public mutating func retire(_ hash: BlobHash) -> Bool {
        let removed = entries.removeValue(forKey: hash) != nil
        if removed {
            keptOrder.removeAll { $0 == hash }
            discarded.append(hash)
        }
        if removed || epochs[hash] != nil {
            putEpoch(hash, mint())
        }
        return removed
    }

    /// Forgets every prefix and epoch. The counter goes on, so an epoch from before is never current again.
    public mutating func purge() {
        entries.removeAll()
        keptOrder.removeAll()
        epochs.removeAll()
        epochOrder.removeAll()
        discarded.removeAll()
    }

    // MARK: Under the store's lock

    private var isOverBounds: Bool {
        keptOrder.count > limits.maxCount || entries.values.reduce(0) { $0 + $1.length } > limits.maxBytes
    }

    private mutating func evict() {
        while let eldest = keptOrder.first, isOverBounds {
            keptOrder.removeFirst()
            entries[eldest] = nil
            discarded.append(eldest)
            lines.append(Self.line(eldest, "evicted"))
        }
    }

    private mutating func mint() -> Int {
        defer { nextEpoch += 1 }
        return nextEpoch
    }

    /// `hash`'s epoch, counted as a use (an access-ordered map's `get`).
    private mutating func touchEpoch(_ hash: BlobHash) -> Int? {
        guard let epoch = epochs[hash] else {
            return nil
        }
        epochOrder.removeAll { $0 == hash }
        epochOrder.append(hash)
        return epoch
    }

    /// `hash`'s epoch, or a fresh one (`getOrPut`).
    private mutating func epochOrMint(_ hash: BlobHash) -> Int {
        if let epoch = touchEpoch(hash) {
            return epoch
        }
        let epoch = mint()
        putEpoch(hash, epoch)
        return epoch
    }

    /// Sets `hash`'s epoch as a use, the least recently used forgotten past ``maxEpochs`` (`removeEldestEntry`).
    private mutating func putEpoch(_ hash: BlobHash, _ epoch: Int) {
        epochs[hash] = epoch
        epochOrder.removeAll { $0 == hash }
        epochOrder.append(hash)
        while epochOrder.count > Self.maxEpochs {
            epochs[epochOrder.removeFirst()] = nil
        }
    }

    static func line(_ hash: BlobHash, _ what: String) -> String {
        "partial \(hash.string.prefix(shownHashCharacters)) \(what)"
    }
}

/// A ``PartialBlobStore`` in memory: for knit-peer, whose blobs live in memory too, the demo and the tests.
public final class MemoryPartialBlobStore: PartialBlobStore {
    private struct State {
        var book: PartialBlobBook
        var bytes: [BlobHash: [UInt8]] = [:]

        /// Drops the bytes the book let go, and answers its lines.
        mutating func settle() -> [String] {
            let owed = book.takeOwed()
            for hash in owed.discarded {
                bytes[hash] = nil
            }
            return owed.lines
        }
    }

    private let state: Lock<State>
    private let log: (@Sendable (String) -> Void)?

    /// An empty store within `limits`, which hands its lines to `log`.
    @preconcurrency
    public init(limits: PartialBlobBook.Limits = PartialBlobBook.Limits(), log: (@Sendable (String) -> Void)? = nil) {
        state = Lock(State(book: PartialBlobBook(limits: limits)))
        self.log = log
    }

    public func length(_ hash: BlobHash) -> Int {
        state.withLock { $0.book.length(hash) }
    }

    public func open(_ hash: BlobHash, offset: Int) -> KeptPrefix? {
        let (prefix, lines) = state.withLock { state in
            let held = state.bytes[hash]
            let prefix = state.book.open(hash, offset: offset) { count in held.map { Array($0.prefix(count)) } }
            return (prefix, state.settle())
        }
        emit(lines)
        return prefix
    }

    @discardableResult
    public func keep(_ hash: BlobHash, bytes: [UInt8], basedOn: Int?, now: Int64) -> Bool {
        let (kept, lines) = state.withLock { state in
            let kept = state.book.keep(hash, length: bytes.count, basedOn: basedOn, now: now) { true }
            if kept {
                state.bytes[hash] = bytes
            }
            // After the copy goes in, so an eviction of the copy itself takes it out again.
            return (kept, state.settle())
        }
        emit(lines)
        return kept
    }

    @discardableResult
    public func drop(_ hash: BlobHash) -> Bool {
        let (removed, lines) = state.withLock { state in
            (state.book.drop(hash), state.settle())
        }
        emit(lines)
        return removed
    }

    @discardableResult
    public func sweep(now: Int64, isHeld: (BlobHash) -> Bool) -> Int {
        let (expired, kept) = state.withLock { state in
            let expired = state.book.expire(now: now)
            _ = state.settle()
            return (expired, state.book.hashes)
        }
        let held = kept.filter(isHeld)
        state.withLock { state in
            for hash in held {
                _ = state.book.retire(hash)
            }
            _ = state.settle()
        }
        return expired + held.count
    }

    public func purge() {
        state.withLock { state in
            state.book.purge()
            state.bytes.removeAll()
        }
    }

    private func emit(_ lines: [String]) {
        guard let log else {
            return
        }
        lines.forEach(log)
    }
}
