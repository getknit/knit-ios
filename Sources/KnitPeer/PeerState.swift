import Foundation
public import KnitCrypto
public import KnitStore
import KnitSync
public import KnitWire

/// A peer's state directory: its identity and its ratchet prekeys in `identity` (mode 0600, in a 0700 directory) and
/// its own profile in `profile.json`, including the version and publish stamp. Keeping those two across restarts
/// matters: Android keeps the newest version it saw, so a peer that forgot its version would publish edits nobody took.
///
/// Everything else, custody, peers and messages, lives in memory and starts empty.
public struct PeerState: Sendable {
    /// The directory.
    public let directory: String

    /// The state in `directory`.
    public init(directory: String) {
        self.directory = directory
    }

    /// Where the private keys live.
    public var identity: FileSecretStore {
        FileSecretStore(path: directory + "/identity")
    }

    /// The stored identity, made and kept first if there is none.
    public func loadIdentity() throws(SecretStoreError) -> IdentityKeys.Loaded {
        try IdentityKeys.load(from: identity)
    }

    /// The ratchet prekeys `keys` keeps beside it in `identity`, read without writing anything: load the identity first
    /// (ADR 2026-10.5sk9).
    public func loadPrekeys(for keys: IdentityKeys) throws(SecretStoreError) -> PrekeyRing {
        try PrekeyRing.load(for: keys, from: identity)
    }

    /// Keeps `keys` as this peer's identity, and forgets the old identity's profile clocks with it. The name and the
    /// photo stay, the photo still kept in `avatar.jpg`.
    public func replaceIdentity(with keys: IdentityKeys) throws(SecretStoreError) {
        try identity.write(keys.storedForm)
        let profile = profileStore()
        let old = profile.load()
        profile.save(OwnProfile(name: old.name, avatarHash: old.avatarHash))
    }

    /// The own profile, kept in `profile.json`, and the frame it was last published as in `profile-frame`.
    public func profileStore() -> FileOwnProfileStore {
        FileOwnProfileStore(path: directory + "/profile.json", framePath: directory + "/profile-frame")
    }

    /// Our own photo, kept in `avatar.jpg` beside the profile that names it, since the peer's blobs live in memory and
    /// it must still serve the hash `profile.json` advertises after a restart (ADR 2026-10.nh55).
    public var avatarPath: String { directory + "/avatar.jpg" }
}

/// An ``OwnProfileStore`` in one JSON file, rewritten atomically on every save. A file that is missing or does not
/// parse reads as a fresh profile.
///
/// The kept frame (ADR 2026-11.xfcq) lives in a second file, as the wire's own envelope around its signature and signed
/// bytes (``WireEnvelope``), so the bytes are read back as they were written, never through a JSON coder. A file that is
/// missing or does not decode reads as none kept, and one that cannot be read as ``KeptProfileFrame/unreadable``. knit-peer
/// keeps custody in memory, so every start after the first finds the kept frame and no custody row.
public final class FileOwnProfileStore: OwnProfileStore {
    private struct Stored: Codable {
        var name: String
        var status: String
        var openToChat: Bool
        var version: Int64
        var publishedAt: Int64
        /// Absent in a file from before photos, which reads as none.
        var avatarHash: String?
        /// The ratchet prekey the publish carries; absent in a file from before prekeys, or when it carries none.
        var prekeyId: Int?
        /// The capabilities the publish carries; absent in a file from before they were recorded, which a start reads as a
        /// change and publishes again as an edit.
        var capabilities: Int64?
    }

    private static let fileMode = 0o600

    /// The file's path.
    public let path: String
    /// The kept frame's file, or `nil` for a store that keeps none on disk and holds it in memory alone.
    public let framePath: String?
    private let cached: Lock<OwnProfile>
    private let frame: Lock<KeptProfileFrame>
    /// Why the last save failed, if it did; the peer logs it.
    public var lastError: String? { failure.withLock { $0 } }
    private let failure = Lock<String?>(nil)

    /// The store at `path`, with its kept frame at `framePath`, both read once now.
    public init(path: String, framePath: String? = nil) {
        self.path = path
        self.framePath = framePath
        frame = Lock(.absent)
        let stored = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        let profile = stored.map { saved in
            OwnProfile(
                name: saved.name,
                status: saved.status,
                openToChat: saved.openToChat,
                version: saved.version,
                publishedAt: saved.publishedAt,
                avatarHash: saved.avatarHash.flatMap(BlobHash.init),
                prekeyId: saved.prekeyId,
                capabilities: saved.capabilities.map(Capabilities.init(rawValue:))
            )
        }
        cached = Lock(profile ?? OwnProfile())
        if let framePath {
            let read = readFrame(at: framePath)
            frame.withLock { $0 = read }
        }
    }

    public func load() -> OwnProfile {
        cached.withLock { $0 }
    }

    /// Always the profile held: the file was read once, when the store was made, and one that did not parse is a fresh
    /// profile by design.
    public func loadIfReadable() -> OwnProfile? {
        load()
    }

    public func save(_ profile: OwnProfile) {
        cached.withLock { $0 = profile }
        let stored = Stored(
            name: profile.name,
            status: profile.status,
            openToChat: profile.openToChat,
            version: profile.version,
            publishedAt: profile.publishedAt,
            avatarHash: profile.avatarHash?.string,
            prekeyId: profile.prekeyId,
            capabilities: profile.capabilities?.rawValue
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(stored).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: Self.fileMode], ofItemAtPath: path)
            failure.withLock { $0 = nil }
        } catch {
            failure.withLock { $0 = "cannot write \(path): \(error)" }
        }
    }

    /// The kept frame as last read or kept. A file that could not be read is read again at each call until it reads, so a
    /// passing fault does not leave the peer without its frame for the rest of the run.
    public func keptFrame() -> KeptProfileFrame {
        guard let framePath, frame.withLock({ $0 }) == .unreadable else {
            return frame.withLock { $0 }
        }
        let reread = readFrame(at: framePath)
        frame.withLock { $0 = reread }
        return reread
    }

    /// Writes the frame's file atomically, mode 0600, or removes it for `nil`, and only then holds the answer in memory: a
    /// write that failed keeps what the file still holds.
    @discardableResult
    public func keep(_ frame: WireEnvelope?) -> Bool {
        let kept = frame.map { KeptProfileFrame.kept(WireEnvelope(sig: $0.sig, signed: $0.signed)) } ?? .absent
        guard let framePath else {
            self.frame.withLock { $0 = kept }
            return true
        }
        do {
            let url = URL(fileURLWithPath: framePath)
            if case .kept(let wire) = kept {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(wire.encoded).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: Self.fileMode], ofItemAtPath: framePath)
            } else if FileManager.default.fileExists(atPath: framePath) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            failure.withLock { $0 = "cannot write \(framePath): \(error)" }
            return false
        }
        self.frame.withLock { $0 = kept }
        return true
    }

    /// The frame in the file at `path`: none when there is no file or it does not decode as one envelope. A file that
    /// cannot be read is noted in ``lastError`` by its path alone, never its bytes.
    private func readFrame(at path: String) -> KeptProfileFrame {
        guard FileManager.default.fileExists(atPath: path) else {
            return .absent
        }
        guard let bytes = FileManager.default.contents(atPath: path) else {
            failure.withLock { $0 = "cannot read \(path)" }
            return .unreadable
        }
        return (try? WireEnvelope(decoding: [UInt8](bytes))).map { .kept(WireEnvelope(sig: $0.sig, signed: $0.signed)) } ?? .absent
    }
}

extension FileOwnProfileStore: Checkpointing {
    /// The profile held. Putting it back rewrites the file, and only when a unit changed the profile, so a unit that is
    /// undone leaves the file as it found it. A peer stopped between a unit's save and its undoing keeps the unit's
    /// profile in the file, as it keeps any save.
    public func checkpoint() -> StoreCheckpoint {
        let held = load()
        let kept = keptFrame()
        return StoreCheckpoint { [self] in
            if load() != held {
                save(held)
            }
            if keptFrame() != kept {
                switch kept {
                case .kept(let wire):
                    keep(wire)
                case .absent:
                    keep(nil)
                case .unreadable:
                    break
                }
            }
        }
    }
}
