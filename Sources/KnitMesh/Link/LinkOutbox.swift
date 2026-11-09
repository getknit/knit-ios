public import KnitCrypto
import KnitWire

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
///
/// **A sealed link seals here, at dequeue** (the `link-seal` contract, §5; knit-next #286). The `KEY_SHARE` goes in
/// through ``appendKeyShare(_:)``, which holds everything queued behind it until the link manager hands over the sending
/// half (``seal(with:)``): no byte after our `KEY_SHARE` ever leaves in the clear. From then on each frame is sealed at
/// the moment it leaves the queue, in ``next(atMost:)``, which is why that call mutates: the ciphertext is kept and
/// sliced to the radio's writes until all of it is out, so a would-block or a partial write never seals twice, and the
/// counter follows the order bytes reach the socket. The digest slot still works on plaintext: a digest none of whose
/// bytes are sealed can still be replaced, and the first frame sealed from one fixes it. Everything counted here, and
/// what ``wrote(_:)`` reports for the radio's ``OutboxLevels``, is plaintext; the ciphertext is the outbox's own business.
/// A seal that fails (``LinkSealer/seal(_:)`` answering `nil`) leaves the outbox failed (``sealFailed``): it writes
/// nothing more, never anything plain, and the radio closes the channel.
public struct LinkOutbox: Sendable {
    private enum Kind: Sendable {
        case bytes
        /// A digest none of whose bytes are written or sealed yet, so a newer one can still take its place.
        case digest
        /// A FILE record, whose last byte leaving the radio reports.
        case file
    }

    private struct Entry: Sendable {
        var kind: Kind
        var payload: [UInt8]
        /// Whether the entry leaves in `SEALED` frames: everything queued behind our `KEY_SHARE`.
        let sealed: Bool
    }

    /// Whether, and how, what is queued is sealed.
    private enum Sealing: Sendable {
        /// A link opened in the plain form, as every link was before the seal: bytes leave as they came.
        case plain
        /// Our `KEY_SHARE` is queued, and the sending half not handed over yet: nothing behind it leaves.
        case awaitingSealer
        /// Every entry queued behind the `KEY_SHARE` leaves sealed under this half.
        case sealing(LinkSealer)
        /// A seal failed, or the queue was dropped from a sealed link: nothing more leaves.
        case failed
    }

    /// One sealed frame on its way out: its ciphertext, how much of it is written, and how much of the head entry's
    /// plaintext it carries, counted once the frame is all out.
    private struct Frame: Sendable {
        let bytes: [UInt8]
        var written = 0
        let plaintext: Int
    }

    /// What one ``wrote(_:)`` moved.
    public struct Written: Sendable, Equatable {
        /// The plaintext bytes this write finished: the bytes counted out of ``queuedBytes``, which the radio reports to
        /// its ``OutboxLevels``. On a sealed link a frame's plaintext counts once its last byte is out, so a write inside a
        /// frame reports none.
        public var plaintextBytes: Int
        /// Whether it finished a FILE record, which the radio then reports (``RadioEvent/wroteFileRecord(_:)``).
        public var finishedFileRecord: Bool

        /// A report.
        public init(plaintextBytes: Int = 0, finishedFileRecord: Bool = false) {
            self.plaintextBytes = plaintextBytes
            self.finishedFileRecord = finishedFileRecord
        }
    }

    /// The most plaintext one sealed frame carries by default: what makes the frame 8 KiB, the most `L2CAPLink` writes at
    /// once, so a frame never costs the stream an extra small write. The link manager cuts a sealed link's records to
    /// this too (``LinkManager/Configuration/maxWriteBytes`` less ``LinkSealer/overheadBytes``).
    public static let sealedFrameBytes = 8192

    /// What waits, in order. At most one entry is a ``Kind/digest``: the first byte written or sealed from one turns it
    /// into ``Kind/bytes``, and ``offerDigest(_:)`` only adds one when none is left.
    private var entries: [Entry] = []
    /// How much of the first entry is already written; on a sealed entry, how much of it went out in whole frames.
    private var written = 0
    private var sealing = Sealing.plain
    /// The frame being written, sealed from the first entry.
    private var frame: Frame?
    /// The most plaintext each sealed frame takes (``seal(with:frameBytes:)``).
    private var framePlaintext = Self.sealedFrameBytes - LinkSealer.overheadBytes
    /// knit-peer's bit flip, armed (``corruptNextSealedFrame()``).
    private var corruptsNextFrame = false

    /// Every byte still waiting, the waiting digest's included: plaintext, on a sealed link too.
    public private(set) var queuedBytes = 0

    /// The most a link may hold waiting: past it, the peer has stopped reading, and its radio closes the channel rather
    /// than grow our memory until iOS ends Knit (ADR 2026-10.f5zs). Four MiB is several hundred frames, far more than a
    /// healthy link ever queues: a reply round is capped at 256 KiB, and a file holds one chunk here at a time. Both radios
    /// read it, BlueZ since it began and `L2CAPLink` since knit-ios #19.
    public static let maximumQueuedBytes = 4 << 20

    /// Whether more than ``maximumQueuedBytes`` wait, so the radio closes the channel.
    public var isOverfull: Bool { queuedBytes > Self.maximumQueuedBytes }

    /// Whether a seal failed, or the queue of a sealed link was dropped (``removeAll()``): nothing more leaves, and the
    /// radio closes the channel rather than write anything plain.
    public var sealFailed: Bool {
        if case .failed = sealing { true } else { false }
    }

    /// Whether what is queued is held for the sending half (``appendKeyShare(_:)``), so a radio need not wait on space.
    public var awaitsSealer: Bool {
        guard case .awaitingSealer = sealing, let head = entries.first else {
            return false
        }
        return head.sealed
    }

    /// An empty outbox.
    public init() {
        // Nothing waits yet.
    }

    /// Whether nothing waits.
    public var isEmpty: Bool { entries.isEmpty }

    /// Whether what is queued now leaves sealed.
    private var sealsNext: Bool {
        if case .plain = sealing { false } else { true }
    }

    /// Queues `bytes` behind everything queued before.
    public mutating func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else {
            return
        }
        entries.append(Entry(kind: .bytes, payload: bytes, sealed: sealsNext))
        queuedBytes += bytes.count
    }

    /// Queues our whole `KEY_SHARE` record, which leaves in the clear, and holds everything queued behind it until
    /// ``seal(with:frameBytes:)`` hands over the half that seals it (the `link-seal` contract, §4). A second `KEY_SHARE` on
    /// one link is no exchange the contract has, so it fails the outbox.
    public mutating func appendKeyShare(_ record: [UInt8]) {
        guard case .plain = sealing, !record.isEmpty else {
            sealing = .failed
            return
        }
        entries.append(Entry(kind: .bytes, payload: record, sealed: false))
        queuedBytes += record.count
        sealing = .awaitingSealer
    }

    /// From here every entry queued behind the `KEY_SHARE` leaves in `SEALED` frames under `sealer`, each frame carrying
    /// at most `frameBytes` less ``LinkSealer/overheadBytes`` of plaintext, so a frame is at most `frameBytes` long and its
    /// plaintext never depends on how much one write takes. A second sealer is no exchange the contract has, so it fails
    /// the outbox.
    public mutating func seal(with sealer: LinkSealer, frameBytes: Int = Self.sealedFrameBytes) {
        switch sealing {
        case .plain, .awaitingSealer:
            sealing = .sealing(sealer)
            framePlaintext = min(LinkSealer.maxPlaintextBytes, max(1, frameBytes - LinkSealer.overheadBytes))
        case .sealing, .failed:
            sealing = .failed
        }
    }

    /// knit-peer's `--flip-sealed-bit`, a trial's switch: flips one bit of the next sealed frame, past its header, so the
    /// far end still reads a frame and fails to open it (the `link-seal` contract's T6). Nothing else calls it.
    package mutating func corruptNextSealedFrame() {
        corruptsNextFrame = true
    }

    /// Queues a whole encoded FILE record behind everything queued before; ``wrote(_:)`` says when its last byte is
    /// out.
    public mutating func appendFileRecord(_ record: [UInt8]) {
        guard !record.isEmpty else {
            return
        }
        entries.append(Entry(kind: .file, payload: record, sealed: sealsNext))
        queuedBytes += record.count
    }

    /// Queues a whole encoded DIGEST record, or puts it in the place of the one still waiting. Answers whether it
    /// replaced one.
    ///
    /// A digest counts as waiting until its first byte is written, or on a sealed link sealed: from then on its bytes are
    /// going out as they were, and a newer one queues behind it as a fresh record (`FramedLink.kt:365`).
    @discardableResult
    public mutating func offerDigest(_ record: [UInt8]) -> Bool {
        guard !record.isEmpty else {
            return false
        }
        queuedBytes += record.count
        // Once a minute per link, over a queue a back-fill leaves at most a few thousand entries long.
        guard let waiting = entries.lastIndex(where: { $0.kind == .digest }) else {
            entries.append(Entry(kind: .digest, payload: record, sealed: sealsNext))
            return false
        }
        queuedBytes -= entries[waiting].payload.count
        entries[waiting].payload = record
        return true
    }

    /// The next bytes to write, at most `limit` of them, all from one record or one ``append(_:)``, or on a sealed link
    /// from one frame: the rest of the first entry, or of the frame being written. Nil when nothing waits, while the
    /// queue is held for the sealer, and once a seal failed (``sealFailed``).
    ///
    /// Mutating, since on a sealed link this is where a frame is sealed, once: until ``wrote(_:)`` has taken all of it,
    /// every call answers the rest of the same frame, so a write the socket refused is offered again as it was. Its
    /// plaintext is as much of the first entry as ``seal(with:frameBytes:)`` allows, whatever `limit` says.
    public mutating func next(atMost limit: Int) -> ArraySlice<UInt8>? {
        // First, so a failed outbox never lets a byte go, a plain head's included.
        guard !sealFailed else {
            return nil
        }
        if let frame {
            return frame.bytes[frame.written..<min(frame.bytes.count, frame.written + max(1, limit))]
        }
        guard let head = entries.first else {
            return nil
        }
        guard head.sealed else {
            return head.payload[written..<min(head.payload.count, written + max(1, limit))]
        }
        guard case .sealing(let sealer) = sealing else {
            return nil
        }
        let taken = min(head.payload.count - written, framePlaintext)
        guard var bytes = sealer.seal(head.payload[written..<(written + taken)]) else {
            sealing = .failed
            return nil
        }
        if corruptsNextFrame {
            corruptsNextFrame = false
            bytes[LinkRecord.headerBytes] ^= 1
        }
        // Sealed now: a newer digest queues behind this one.
        entries[0].kind = head.kind == .digest ? .bytes : head.kind
        let sealed = Frame(bytes: bytes, plaintext: taken)
        frame = sealed
        return sealed.bytes[0..<min(sealed.bytes.count, max(1, limit))]
    }

    /// Records that the first `count` bytes ``next(atMost:)`` answered were written, and answers what that moved: the
    /// plaintext it finished and whether it finished a FILE record, which the radio then reports. The first byte written
    /// from a waiting digest fixes it, so a digest offered after that queues behind it.
    @discardableResult
    public mutating func wrote(_ count: Int) -> Written {
        guard count > 0, let head = entries.first else {
            return Written()
        }
        let taken: Int
        if var current = frame {
            current.written = min(current.bytes.count, current.written + count)
            guard current.written == current.bytes.count else {
                frame = current
                return Written()
            }
            frame = nil
            taken = current.plaintext
        } else {
            if head.kind == .digest {
                entries[0].kind = .bytes
            }
            taken = min(count, head.payload.count - written)
        }
        written += taken
        queuedBytes -= taken
        guard written == head.payload.count else {
            return Written(plaintextBytes: taken)
        }
        entries.removeFirst()
        written = 0
        return Written(plaintextBytes: taken, finishedFileRecord: head.kind == .file)
    }

    /// Everything that may leave now, as one write taken whole, and the plaintext it carried: what a radio whose writes the
    /// far end always takes at once sends (the tests' radios). Sealed as ``next(atMost:)`` seals, frame by frame, so such a
    /// radio runs the same sealing code as the real ones.
    public mutating func drain() -> (bytes: [UInt8], written: Written) {
        var bytes: [UInt8] = []
        var total = Written()
        while let chunk = next(atMost: Self.maximumQueuedBytes) {
            bytes += chunk
            let report = wrote(chunk.count)
            total.plaintextBytes += report.plaintextBytes
            total.finishedFileRecord = total.finishedFileRecord || report.finishedFileRecord
        }
        return (bytes, total)
    }

    /// Drops everything waiting. A sealed link's outbox stays sealed, failed: the channel is closing, and nothing queued
    /// after this may ever leave in the clear.
    public mutating func removeAll() {
        entries.removeAll()
        written = 0
        frame = nil
        queuedBytes = 0
        if case .plain = sealing {
            return
        }
        sealing = .failed
    }
}
