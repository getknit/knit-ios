public import KnitMesh
public import KnitStore
import KnitSync
public import KnitWire

/// knit-peer's `--lying` blob store, a trial's switch: the peer's blobs, which can serve junk under a hash or keep a held
/// blob's bytes to themselves, as a holder that lies about a photo would. The trial (`door-cap-lying-peers`) watches the
/// far end's photo ceiling and its door cap take such a holder (ADR 2026-10.r88m).
///
/// - **Junk** (``setJunk(_:bytes:)``): the hash reads as held, `image/jpeg`, of the size set, whatever the store holds,
///   and its bytes are junk that depends only on the hash and the offset, so a resumed prefix splices onto the same junk.
///   The engine then answers a `blobhas` with that size and serves that many bytes under the hash.
/// - **Withheld** (``withhold(_:)``): a held blob's size, type and bytes read as gone, so the engine neither pushes nor
///   serves it and answers a query not held, while ``contains(_:)`` and ``held(among:)`` still say held, so it is never
///   wanted again. Junk set on the same hash wins.
///
/// With nothing set every read answers as the store it wraps. Writes and the enumerations the sweeps read always go to
/// that store, so no sweep sees a lie and the store unit that covers it still undoes a write made through here. The
/// switches sit outside every unit: a unit undone leaves them as they were.
public final class LyingBlobStore: BlobStore {
    /// The type junk is served as: the trial lies about a profile photo.
    public static let junkMime = "image/jpeg"

    /// A junk size outside `1...FileIntake.maxFileBytes`: none such could stream, so the switch refuses it.
    public struct JunkSizeRefused: Error, Equatable, CustomStringConvertible {
        /// The size asked for.
        public let bytes: Int

        /// The refusal of `bytes`.
        public init(bytes: Int) {
            self.bytes = bytes
        }

        public var description: String { "junk bytes must be in 1...\(FileIntake.maxFileBytes), not \(bytes)" }
    }

    private struct Switches {
        var junk: [BlobHash: Int] = [:]
        var withheld: Set<BlobHash> = []
        var junkBytesServed: Int64 = 0
    }

    /// What a read of one hash answers, decided under the lock and acted on after it.
    private enum Lie {
        case junk(Int)
        case withheld
        case honest
    }

    private let inner: any BlobStore
    private let switches = Lock(Switches())

    /// `inner`, honest until a switch is set.
    public init(wrapping inner: any BlobStore) {
        self.inner = inner
    }

    /// `base` with its blobs wrapped, every other store and the unit as they were. The unit was made over `base.blobs`,
    /// so it still undoes what is written through the wrapper.
    public static func stores(over base: MeshStores) -> (stores: MeshStores, blobs: LyingBlobStore) {
        let lying = LyingBlobStore(wrapping: base.blobs)
        let stores = MeshStores(
            custody: base.custody,
            peers: base.peers,
            messages: base.messages,
            conversations: base.conversations,
            blocks: base.blocks,
            groups: base.groups,
            ownProfile: base.ownProfile,
            blobs: lying,
            ratchet: base.ratchet,
            groupRatchet: base.groupRatchet,
            transactor: base.transactor
        )
        return (stores, lying)
    }

    // MARK: Switches

    /// The hashes served as junk, and each one's size.
    public var junk: [BlobHash: Int] { switches.withLock { $0.junk } }

    /// The hashes whose bytes are kept back.
    public var withheld: Set<BlobHash> { switches.withLock { $0.withheld } }

    /// Every junk byte read out so far, which is what a serve streams.
    public var junkBytesServed: Int64 { switches.withLock { $0.junkBytesServed } }

    /// Serves `bytes` of junk under `hash` from now on, in place of anything held or any size set before.
    public func setJunk(_ hash: BlobHash, bytes: Int) throws(JunkSizeRefused) {
        guard (1...FileIntake.maxFileBytes).contains(bytes) else {
            throw JunkSizeRefused(bytes: bytes)
        }
        switches.withLock { $0.junk[hash] = bytes }
    }

    /// Stops serving junk under `hash`.
    public func clearJunk(_ hash: BlobHash) {
        switches.withLock { $0.junk[hash] = nil }
    }

    /// Keeps `hash`'s bytes back from now on.
    public func withhold(_ hash: BlobHash) {
        switches.withLock { _ = $0.withheld.insert(hash) }
    }

    /// Reads `hash` as held again, if it is.
    public func release(_ hash: BlobHash) {
        switches.withLock { _ = $0.withheld.remove(hash) }
    }

    // MARK: BlobStore

    public func contains(_ hash: BlobHash) -> Bool {
        let isJunk = switches.withLock { $0.junk[hash] != nil }
        return isJunk || inner.contains(hash)
    }

    public func held(among hashes: Set<BlobHash>) -> Set<BlobHash> {
        let junkHashes = switches.withLock { Set($0.junk.keys) }
        return inner.held(among: hashes).union(hashes.intersection(junkHashes))
    }

    public func mime(of hash: BlobHash) -> String? {
        switch lie(about: hash) {
        case .junk:
            Self.junkMime
        case .withheld:
            nil
        case .honest:
            inner.mime(of: hash)
        }
    }

    public func size(of hash: BlobHash) -> Int? {
        switch lie(about: hash) {
        case .junk(let bytes):
            bytes
        case .withheld:
            nil
        case .honest:
            inner.size(of: hash)
        }
    }

    /// Junk reads as the memory store reads a blob: `nil` for a negative offset or count or one past the end, and fewer
    /// bytes at the end.
    public func read(_ hash: BlobHash, offset: Int, count: Int) -> [UInt8]? {
        switch lie(about: hash) {
        case .junk(let bytes):
            guard offset >= 0, count >= 0, offset <= bytes else {
                return nil
            }
            let read = Self.junk(hash, offset: offset, count: min(count, bytes - offset))
            switches.withLock { $0.junkBytesServed += Int64(read.count) }
            return read
        case .withheld:
            return nil
        case .honest:
            return inner.read(hash, offset: offset, count: count)
        }
    }

    public func bytes(of hash: BlobHash) -> [UInt8]? {
        switch lie(about: hash) {
        case .junk(let bytes):
            Self.junk(hash, offset: 0, count: bytes)
        case .withheld:
            nil
        case .honest:
            inner.bytes(of: hash)
        }
    }

    @discardableResult
    public func insert(_ bytes: [UInt8], hash: BlobHash, mime: String, storedAt: Int64) -> Bool {
        inner.insert(bytes, hash: hash, mime: mime, storedAt: storedAt)
    }

    public func remove(_ hash: BlobHash) {
        inner.remove(hash)
    }

    public func allHashes() -> [BlobHash] {
        inner.allHashes()
    }

    public func hashes(storedBefore cutoff: Int64) -> [BlobHash] {
        inner.hashes(storedBefore: cutoff)
    }

    public func totalBytes(among hashes: Set<BlobHash>) -> Int {
        inner.totalBytes(among: hashes)
    }

    // MARK: Junk

    private func lie(about hash: BlobHash) -> Lie {
        switches.withLock { switches in
            if let bytes = switches.junk[hash] {
                return .junk(bytes)
            }
            return switches.withheld.contains(hash) ? .withheld : .honest
        }
    }

    /// FNV-1a's 64-bit offset basis and prime, which seed each hash's junk.
    private static let fnvBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    private static let fnvPrime: UInt64 = 0x100_0000_01B3
    /// SplitMix64's increment, multipliers and shifts.
    private static let splitMixGamma: UInt64 = 0x9E37_79B9_7F4A_7C15
    private static let splitMixFirst: UInt64 = 0xBF58_476D_1CE4_E5B9
    private static let splitMixSecond: UInt64 = 0x94D0_49BB_1331_11EB
    private static let splitMixShiftFirst: UInt64 = 30
    private static let splitMixShiftSecond: UInt64 = 27
    private static let splitMixShiftLast: UInt64 = 31
    /// Bytes in one mixed word, and the shift from a byte's offset to its word's index.
    private static let wordBytes = UInt64.bitWidth / UInt8.bitWidth
    private static let wordShift = wordBytes.trailingZeroBitCount

    /// `count` junk bytes of `hash` from `offset`: each 8-byte word a SplitMix64 step over the hash's FNV-1a and the word's
    /// index, so any byte is the same whichever read reaches it.
    private static func junk(_ hash: BlobHash, offset: Int, count: Int) -> [UInt8] {
        let seed = hash.string.utf8.reduce(fnvBasis) { ($0 ^ UInt64($1)) &* fnvPrime }
        return (offset..<(offset + count)).map { index in
            let word = mix(seed ^ UInt64(index >> wordShift))
            return UInt8(truncatingIfNeeded: word >> (UInt64(index % wordBytes) * UInt64(UInt8.bitWidth)))
        }
    }

    private static func mix(_ value: UInt64) -> UInt64 {
        var mixed = value &+ splitMixGamma
        mixed = (mixed ^ (mixed >> splitMixShiftFirst)) &* splitMixFirst
        mixed = (mixed ^ (mixed >> splitMixShiftSecond)) &* splitMixSecond
        return mixed ^ (mixed >> splitMixShiftLast)
    }
}
