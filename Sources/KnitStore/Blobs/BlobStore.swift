import KnitSync
public import KnitWire

/// Content-addressed bytes: profile photos and photos in chats, our own and other people's (`BlobStore` and
/// `MeshBlobStore` in knit-next). Each blob is keyed by its ``BlobHash``, the SHA-256 of its bytes, which the caller
/// checks before it hands the bytes over (ADR 2026-10.nh55).
///
/// A blob carries no owner and no role. One hash can be our photo, a photo in a thread and a carried frame's photo at
/// once, so a blob lives while anything still names it, and the engine removes one that nothing does
/// (`BlobRepository.deleteIfUnreferenced` and `deleteOrphans`, `BlobRepository.kt:96-149`).
public protocol BlobStore: AnyObject, Sendable {
    /// Whether the bytes of `hash` are held.
    func contains(_ hash: BlobHash) -> Bool

    /// Which of `hashes` are held, in one read, for a screen that shows many faces at once.
    func held(among hashes: Set<BlobHash>) -> Set<BlobHash>

    /// The type the blob was stored with, or `nil` when it is not held.
    func mime(of hash: BlobHash) -> String?

    /// The blob's length in bytes, or `nil` when it is not held.
    func size(of hash: BlobHash) -> Int?

    /// At most `count` bytes of the blob from `offset`, fewer at its end, or `nil` when it is not held or cannot be
    /// read. A file streams in chunks read this way, so a queued file costs its hash, not its bytes.
    func read(_ hash: BlobHash, offset: Int, count: Int) -> [UInt8]?

    /// The whole blob, or `nil` when it is not held or cannot be read.
    func bytes(of hash: BlobHash) -> [UInt8]?

    /// Keeps `bytes` under `hash`, of type `mime`, stamped `storedAt` on the wall clock. A blob already held is left
    /// as it is (`BlobDao.insert`, `OnConflictStrategy.IGNORE`), and the answer says whether anything new was kept.
    @discardableResult
    func insert(_ bytes: [UInt8], hash: BlobHash, mime: String, storedAt: Int64) -> Bool

    /// Forgets the blob, if held. Inside a store unit the removal is undone with the unit, bytes and all, so the blob is
    /// held whole again if the unit abandons or fails (``StoreTransactor``).
    func remove(_ hash: BlobHash)

    /// Every held hash, in byte order, for the sweep that removes blobs nothing names.
    func allHashes() -> [BlobHash]

    /// The bytes held under `hashes`, counting only those held: what a budget over some blobs weighs.
    func totalBytes(among hashes: Set<BlobHash>) -> Int
}

/// A ``BlobStore`` in memory: for knit-peer, the tests and the demo.
public final class MemoryBlobStore: BlobStore {
    private struct Blob {
        var bytes: [UInt8]
        var mime: String
    }

    private let blobs = Lock<[BlobHash: Blob]>([:])

    /// An empty store.
    public init() {
        // Nothing held yet.
    }

    public func contains(_ hash: BlobHash) -> Bool {
        blobs.withLock { $0[hash] != nil }
    }

    public func held(among hashes: Set<BlobHash>) -> Set<BlobHash> {
        blobs.withLock { held in hashes.filter { held[$0] != nil } }
    }

    public func mime(of hash: BlobHash) -> String? {
        blobs.withLock { $0[hash]?.mime }
    }

    public func size(of hash: BlobHash) -> Int? {
        blobs.withLock { $0[hash]?.bytes.count }
    }

    public func read(_ hash: BlobHash, offset: Int, count: Int) -> [UInt8]? {
        blobs.withLock { held in
            guard let bytes = held[hash]?.bytes, offset >= 0, count >= 0, offset <= bytes.count else {
                return nil
            }
            return Array(bytes[offset..<(offset + min(count, bytes.count - offset))])
        }
    }

    public func bytes(of hash: BlobHash) -> [UInt8]? {
        blobs.withLock { $0[hash]?.bytes }
    }

    @discardableResult
    public func insert(_ bytes: [UInt8], hash: BlobHash, mime: String, storedAt _: Int64) -> Bool {
        blobs.withLock { held in
            guard held[hash] == nil else {
                return false
            }
            held[hash] = Blob(bytes: bytes, mime: mime)
            return true
        }
    }

    public func remove(_ hash: BlobHash) {
        blobs.withLock { $0[hash] = nil }
    }

    public func allHashes() -> [BlobHash] {
        blobs.withLock { $0.keys.sorted() }
    }

    public func totalBytes(among hashes: Set<BlobHash>) -> Int {
        blobs.withLock { held in hashes.reduce(0) { $0 + (held[$1]?.bytes.count ?? 0) } }
    }
}

extension MemoryBlobStore: Checkpointing {
    /// Every blob held, bytes and all. A unit's body leaves blobs to the work after its commit (``StoreTransactor``), but
    /// one written or removed inside a unit is undone here with the rest, as on the database: there the index row is
    /// undone, and the SQL store keeps a removed blob's file until the row's removal commits.
    public func checkpoint() -> StoreCheckpoint {
        let held = blobs.withLock { $0 }
        return StoreCheckpoint { [self] in blobs.withLock { $0 = held } }
    }
}
